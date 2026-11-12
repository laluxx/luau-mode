;;; luau-mode.el --- Standalone major mode for Luau and Rojo -*- lexical-binding: t -*-

;; Copyright (C) 2025-2026 Free Software Foundation, Inc.
;; Luau adaptations and Bloblox/Rojo integration Copyright (C) 2026 laluxx.

;; Author: laluxx
;; Based on GNU Emacs lua-mode.el, originally authored by:
;;         2011-2013 immerrr <immerrr+lua@gmail.com>
;;         2010-2011 Reuben Thomas <rrt@sc3d.org>
;;         2006 Juergen Hoetzel <juergen@hoetzel.info>
;;         2004 various (support for Lua 5 and byte compilation)
;;         2001 Christian Vogler <cvogler@gradient.cis.upenn.edu>
;;         1997 Bret Mogilefsky <mogul-lua@gelatinous.com>
;;              Gregor Schmid <schmid@fb3-s7.math.tu-berlin.de>
;; Bret Mogilefsky started from tcl-mode by Gregor Schmid with tons of
;; assistance from Paul Du Bois <pld-lua@gelatinous.com>
;; and Aaron Smith <aaron-lua@gelatinous.com>.
;; Original Lua mode maintainer: emacs-devel@gnu.org
;; Package-Requires: ((emacs "31.1"))
;; Version: 0.9.1
;; Keywords: languages, tools
;; URL: https://luau.org

;; Portions of this file are derived from GNU Emacs lua-mode.el.
;; This independent Luau package is distributed under the same GPL license.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; luau-mode provides independent support for Lua and Luau, including automatic
;; indentation, syntactical font-locking, running interactive shell,
;; Flymake checks with luacheck, interacting with `hs-minor-mode' and
;; online documentation lookup.
;;
;; The following variables are available for customization (see more via
;; `M-x customize-group luau`):
;;
;; - Var `luau-indent-level':
;;   indentation offset in spaces
;; - Var `luau-indent-string-contents':
;;   set to `t` if you like to have contents of multiline strings to be
;;   indented like comments
;; - Var `luau-indent-nested-block-content-align':
;;   set to `nil' to stop aligning the content of nested blocks with the
;;   open parenthesis
;; - Var `luau-indent-close-paren-align':
;;   set to `t' to align close parenthesis with the open parenthesis,
;;   rather than with the beginning of the line
;; - Var `luau-mode-hook':
;;   list of functions to execute when luau-mode is initialized
;; - Var `luau-documentation-url':
;;   base URL for documentation lookup
;; - Var `luau-documentation-function': function used to
;;   show documentation (`eww` is a viable alternative for Emacs 25)
;;
;; These are variables/commands that operate on the Lua process:
;;
;; - Var `luau-default-application':
;;   command to start the Lua process (REPL)
;; - Var `luau-default-command-switches':
;;   arguments to pass to the Lua process on startup (make sure `-i` is
;;   there if you expect working with Lua shell interactively)
;; - Cmd `luau-start-process': start new REPL process, usually happens
;;   automatically
;; - Cmd `luau-kill-process': kill current REPL process
;;
;; These are variables/commands for interaction with the Lua process:
;;
;; - Cmd `luau-show-process-buffer': switch to REPL buffer
;; - Cmd `luau-hide-process-buffer': hide window showing REPL buffer
;; - Var `luau-always-show': show REPL buffer after sending something
;; - Cmd `luau-send-buffer': send whole buffer
;; - Cmd `luau-send-current-line': send current line
;; - Cmd `luau-send-defun': send current top-level function
;; - Cmd `luau-send-region': send active region
;; - Cmd `luau-restart-with-whole-file': restart REPL and send whole buffer
;;
;; To enable on-the-fly linting, make sure you have the luacheck program
;; installed (available from luarocks) and activate `flymake-mode'.
;;
;; See "M-x apropos-command ^luau-" for a list of commands.
;; See "M-x customize-group luau" for a list of customizable variables.

;;; Code:

(require 'comint)
(require 'newcomment)
(require 'rx)
(require 'luau-interface)
(require 'luau-browser)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'project)
(require 'url-util)
(require 'compile)
(require 'luau-lsp)

;; Keep strict compilation independent of when optional Eglot is loaded.
(declare-function eglot-managed-p "eglot" ())
(declare-function eglot-current-server "eglot" ())
(declare-function jsonrpc-request "jsonrpc" (connection method &optional params))
(declare-function luau-lsp--select-workspace-variable "luau-lsp" (symbols))
(declare-function luau-lsp--register-lsp-mode "luau-lsp" ())
(declare-function luau-roblox-api-status "luau-roblox" ())
(declare-function luau-roblox-doc-at-point "luau-roblox" ())

(eval-when-compile
  (require 'cl-lib)
  (require 'compile))

;; rx-wrappers for Lua

(eval-and-compile
  (defvar luau--rx-bindings
    '((symbol (&rest x) (seq symbol-start (or x) symbol-end))
      (ws (* (any " \t")))
      (ws+ (+ (any " \t")))

      (luau-name (symbol (seq (+ (any alpha "_")) (* (any alnum "_")))))
      (luau-funcname (seq luau-name (* ws "." ws luau-name)
                         (opt ws ":" ws luau-name)))
      (luau-funcheader
       ;; Outer (seq ...) is here to shy-group the definition
       (seq (or (seq (symbol "function") ws (group-n 1 luau-funcname))
                (seq (group-n 1 luau-funcname) ws "=" ws
                     (symbol "function")))))
      (luau-number
       (seq (or (seq (+ digit) (opt ".") (* digit))
                (seq (* digit) (opt ".") (+ digit)))
            (opt (regexp "[eE][+-]?[0-9]+"))))
      (luau-assignment-op (seq "=" (or buffer-end (not (any "=")))))
      (luau-operator (or "+" "-" "*" "/" "%" "^" "#" "==" "~=" "<=" ">=" "<"
                        ">" "=" ";" ":" "," "." ".." "..."))
      (luau-keyword-operator (symbol "and" "not" "or"))
      (luau-keyword
       (symbol "break" "do" "else" "elseif" "end"  "for" "function"
               "goto" "if" "in" "local" "repeat" "return"
               "then" "until" "while"))
      (luau-up-to-9-variables
       (seq (group-n 1 luau-name) ws
            (? "," ws (group-n 2 luau-name) ws
               (? "," ws (group-n 3 luau-name) ws
                  (? "," ws (group-n 4 luau-name) ws
                     (? "," ws (group-n 5 luau-name) ws
                        (? "," ws (group-n 6 luau-name) ws
                           (? "," ws (group-n 7 luau-name) ws
                              (? "," ws (group-n 8 luau-name) ws
                                 (? "," ws (group-n 9 luau-name) ws))))))))))))

  (defmacro luau-rx (&rest regexps)
    (eval `(rx-let ,luau--rx-bindings
             (rx ,@regexps))))

  (defun luau-rx-to-string (form &optional no-group)
    (rx-let-eval luau--rx-bindings
      (rx-to-string form no-group))))

;; Local variables

(defgroup luau nil
  "Major mode for editing Luau code without requiring `lua-mode`."
  :prefix "luau-"
  :group 'languages)

(defcustom luau-enable-legacy-luacheck nil
  "Enable the inherited `luau-flymake' backend based on luacheck.
Luacheck is a Lua linter and does not understand all typed Luau syntax.
Prefer luau-lsp Flymake diagnostics instead."
  :type 'boolean :group 'luau)



(defcustom luau-process-init-code nil
  "Optional REPL bootstrap Lua code for `luau-start-process'.
When non-nil, a compatible interactive runtime must support loadstring.
A standard Luau CLI need not support this interface."
  :type '(choice (const :tag "None" nil) string) :group 'luau-tools)


(defcustom luau-indent-level 4
  "Amount by which Lua subexpressions are indented."
  :type 'natnum
  :safe #'natnump
  :version "31.1")

(defcustom luau-comment-start "-- "
  "Default value of `comment-start'."
  :type 'string
  :version "31.1")

(defcustom luau-comment-start-skip "---*[ \t]*"
  "Default value of `comment-start-skip'."
  :type 'string
  :version "31.1")

(defcustom luau-default-application "luau"
  "Default application to run in Lua process.

Can be a string, where it denotes a command to be executed to start Lua
process, or a (HOST . PORT) cons, that can be used to connect to Lua
process running remotely."
  :type '(choice (string)
                 (cons string integer))
  :version "31.1")

(defcustom luau-default-command-switches nil
  "Command switches for `luau-default-application'.
Should be a list of strings."
  :type '(repeat string)
  :version "31.1")

(defcustom luau-always-show t
  "Non-nil means display `luau-process-buffer' after sending a command."
  :type 'boolean
  :version "31.1")

(defcustom luau-documentation-function 'browse-url
  "Function used to fetch the Lua reference manual."
  :type `(radio (function-item browse-url)
                ,@(when (fboundp 'eww) '((function-item eww)))
                ,@(when (fboundp 'w3m-browse-url)
                    '((function-item w3m-browse-url)))
                (function :tag "Other function"))
  :version "31.1")

(defcustom luau-documentation-url
  (or (and (file-readable-p "/usr/share/doc/lua/manual.html")
           "file:///usr/share/doc/lua/manual.html")
      "https://luau.org/syntax/")
  "URL pointing to the Lua reference manual."
  :type 'string
  :version "31.1")

(defvar luau-process nil
  "The active Lua process.")

(defvar luau-process-buffer nil
  "Buffer used for communication with the Lua process.")

(defcustom luau-prefix-key "\C-c"
  "Prefix for all `luau-mode' commands."
  :type 'key-sequence
  :initialize #'custom-initialize-default
  :set #'luau--customize-set-prefix-key
  :get (lambda (sym)
         (let ((prefix-key (symbol-value sym)))
           (if (eq 'ignore prefix-key) "" prefix-key)))
  :version "31.1")

(defvar-keymap luau-prefix-mode-map
  :doc "Keymap that is used to define keys accessible by `luau-prefix-key'.
If the latter is nil, the keymap translates into `luau-mode-map' verbatim."
  "C-l" #'luau-send-buffer
  "C-f" #'luau-search-documentation)

(defvar luau--electric-indent-chars
  (mapcar #'string-to-char '("}" "]" ")")))

(defvar luau-mode-map
  (let ((result-map (make-sparse-keymap)))
    (unless (boundp 'electric-indent-chars)
      (mapc (lambda (electric-char)
              (define-key result-map
                (read-kbd-macro
                 (char-to-string electric-char))
                #'luau-electric-match))
            luau--electric-indent-chars))
    (define-key result-map [remap backward-up-list] 'luau-backward-up-list)

    ;; Handle prefix-keyed bindings:
    ;; * if no prefix, set prefix-map as parent, i.e.  if key is not
    ;;   defined look it up in prefix-map
    ;; * if prefix is set, bind the prefix-map to that key
    (if luau-prefix-key
        (define-key result-map luau-prefix-key luau-prefix-mode-map)
      (set-keymap-parent result-map luau-prefix-mode-map))
    result-map)
  "Keymap used in `luau-mode' buffers.")

(defun luau--customize-set-prefix-key (prefix-key-sym prefix-key-val)
  "Set PREFIX-KEY-SYM to PREFIX-KEY-VAL."
  (unless (eq prefix-key-sym 'luau-prefix-key)
    (error "Prefix doesn't match luau-prefix-key"))
  (define-key luau-mode-map luau-prefix-key nil)
  ;; `luau-set-prefix-key' uses an empty string to remove the prefix.
  (when (and (equal 'string (type-of prefix-key-val))
             (string-blank-p prefix-key-val))
    (setq prefix-key-val (vector #'ignore)))
  (if (eq 'ignore (elt prefix-key-val 0))
      (set-keymap-parent luau-mode-map luau-prefix-mode-map)
    (define-key luau-mode-map prefix-key-val luau-prefix-mode-map))
  (set-default prefix-key-sym prefix-key-val)
  (when (fboundp 'luau-prefix-key-update-bindings)
    (luau-prefix-key-update-bindings)))

(defvar-local luau-electric-flag t
  "Non-nil means electric actions are enabled.")

(defcustom luau-prompt-regexp "[^\n]*\\(>[\t ]+\\)+$"
  "Regexp which matches the Lua program's prompt."
  :type  'regexp
  :version "31.1")

(defcustom luau-indent-string-contents nil
  "If non-nil, contents of multiline string will be indented.
Otherwise leading amount of whitespace on each line is preserved."
  :type 'boolean
  :safe #'booleanp
  :version "31.1")

(defcustom luau-indent-nested-block-content-align t
  "Controls how the content of nested blocks are indented.
If non-nil, the contents of nested blocks are indented to align with the
column of the opening parenthesis, rather than just forward by
`luau-indent-level'."
  :type 'boolean
  :safe #'booleanp
  :version "31.1")

(defcustom luau-indent-close-paren-align t
  "Controls how closing parenthesis is aligned.
If non-nil, close parenthesis are aligned with their open parenthesis.
If nil, close parenthesis are aligned to the beginning of the line."
  :type 'boolean
  :safe #'booleanp
  :version "31.1")

(defcustom luau-jump-on-traceback t
  "Jump to innermost traceback location in *lua* buffer.
When this variable is non-nil and a traceback occurs when running Lua
code in a process, jump immediately to the source code of the innermost
traceback location."
  :type 'boolean
  :version "31.1")

(defcustom luau-mode-hook nil
  "Hooks called when Lua mode fires up."
  :type 'hook
  :options '(eglot-ensure
             flymake-mode
             hs-minor-mode
             outline-minor-mode)
  :version "31.1")

(defvar luau-region-start (make-marker)
  "Start of special region for Lua communication.")

(defvar luau-region-end (make-marker)
  "End of special region for Lua communication.")

;; The whole defconst is inside eval-when-compile, because it's later
;; referenced inside another eval-and-compile block.
(eval-and-compile
  (defconst luau--builtins
    (let* ((modules
            '("_G" "_VERSION" "assert" "collectgarbage" "dofile" "error" "getfenv"
              "getmetatable" "ipairs" "load" "loadfile" "loadstring" "module"
              "next" "pairs" "pcall" "print" "rawequal" "rawget" "rawlen" "rawset"
              "require" "select" "setfenv" "setmetatable" "tonumber" "tostring"
              "type" "unpack" "xpcall" "self" "warn"
              ("bit32" . ("arshift" "band" "bnot" "bor" "btest" "bxor" "extract"
                          "lrotate" "lshift" "replace" "rrotate" "rshift"))
              ("coroutine" . ("create" "isyieldable" "resume" "running" "status"
                              "wrap" "yield"))
              ("debug" . ("debug" "getfenv" "gethook" "getinfo" "getlocal"
                          "getmetatable" "getregistry" "getupvalue" "getuservalue"
                          "setfenv" "sethook" "setlocal" "setmetatable"
                          "setupvalue" "setuservalue" "traceback" "upvalueid"
                          "upvaluejoin"))
              ("io" . ("close" "flush" "input" "lines" "open" "output" "popen"
                       "read" "stderr" "stdin" "stdout" "tmpfile" "type" "write"))
              ("math" . ("abs" "acos" "asin" "atan" "atan2" "ceil" "cos" "cosh"
                         "deg" "exp" "floor" "fmod" "frexp" "huge" "ldexp" "log"
                         "log10" "max" "maxinteger" "min" "mininteger" "modf" "pi"
                         "pow" "rad" "random" "randomseed" "sin" "sinh" "sqrt"
                         "tan" "tanh" "tointeger" "type" "ult"))
              ("os" . ("clock" "date" "difftime" "execute" "exit" "getenv"
                       "remove"  "rename" "setlocale" "time" "tmpname"))
              ("package" . ("config" "cpath" "loaded" "loaders" "loadlib" "path"
                            "preload" "searchers" "searchpath" "seeall"))
              ("string" . ("byte" "char" "dump" "find" "format" "gmatch" "gsub"
                           "len" "lower" "match" "pack" "packsize" "rep" "reverse"
                           "sub" "unpack" "upper"))
              ("table" . ("concat" "create" "insert" "maxn" "move" "pack" "remove"
                          "sort" "unpack"))
              ("utf8" . ("char" "charpattern" "codepoint" "codes" "len"
                         "offset")))))

      (cl-labels
          ((module-name-re (x)
             (concat "\\(?1:\\_<"
                     (if (listp x) (car x) x)
                     "\\_>\\)"))
           (module-members-re (x)
             (if (listp x)
                 (concat "\\(?:[ \t]*\\.[ \t]*"
                         "\\_<\\(?2:"
                         (regexp-opt (cdr x))
                         "\\)\\_>\\)?")
               "")))

        (concat
         ;; Common prefix:
         ;; - beginning-of-line
         ;; - or neither of [ '.', ':' ] to exclude "foo.string.rep"
         ;; - or concatenation operator ".."
         "\\(?:^\\|[^:. \t]\\|[.][.]\\)"
         ;; Optional whitespace
         "[ \t]*"
         "\\(?:"
         ;; Any of modules/functions
         (mapconcat (lambda (x)
                      (concat (module-name-re x) (module-members-re x)))
                    modules
                    "\\|")
         "\\)")))
    "A regexp that matches Lua builtin functions & variables.

This is a compilation of 5.1-5.4 builtins taken from the index of
respective Lua reference manuals."))

(defvar luau-font-lock-keywords
  `(;; Highlight the hash-bang line "#!/foo/bar/lua" as comment
    ("^#!.*$" . 'luau-comment-face)

    ;; Builtin constants
    (,(luau-rx (symbol "true" "false" "nil"))
     . 'luau-constant-face)

    ;; Keywords
    (,(luau-rx (or luau-keyword luau-keyword-operator))
     . 'luau-keyword-face)

    ;; Labels used by the "goto" statement
    ;; Highlights the following syntax: ::label::
    (,(luau-rx "::" ws luau-name ws "::")
     . 'luau-constant-face)

    ;; Highlights the name of the label in the "goto" statement like
    ;; "goto label"
    (,(luau-rx (symbol (seq "goto" ws+ (group-n 1 luau-name))))
     (1 'luau-constant-face))

    ;; Highlight Lua builtin functions and variables
    (,luau--builtins
     (1 'luau-builtin-face) (2 'luau-builtin-face nil noerror))

    (,(luau-rx (symbol "for") ws+ luau-up-to-9-variables)
     (1 'luau-variable-face)
     (2 'luau-variable-face nil noerror)
     (3 'luau-variable-face nil noerror)
     (4 'luau-variable-face nil noerror)
     (5 'luau-variable-face nil noerror)
     (6 'luau-variable-face nil noerror)
     (7 'luau-variable-face nil noerror)
     (8 'luau-variable-face nil noerror)
     (9 'luau-variable-face nil noerror))

    (,(luau-rx (symbol "function") (? ws+ luau-funcname)
              ws "(" ws luau-up-to-9-variables)
     (1 'luau-variable-face)
     (2 'luau-variable-face nil noerror)
     (3 'luau-variable-face nil noerror)
     (4 'luau-variable-face nil noerror)
     (5 'luau-variable-face nil noerror)
     (6 'luau-variable-face nil noerror)
     (7 'luau-variable-face nil noerror)
     (8 'luau-variable-face nil noerror)
     (9 'luau-variable-face nil noerror))

    (,(luau-rx luau-funcheader)
     (1 'luau-function-face))

    ;; local x, y, z
    ;; local x = .....
    ;;
    ;; NOTE: this is intentionally below funcheader matcher, so that in
    ;;
    ;; local foo = function() ...
    ;;
    ;; "foo" is fontified as function-name-face, and variable-name-face
    ;; is not applied.
    (,(luau-rx (symbol "local") ws+ luau-up-to-9-variables)
     (1 'luau-variable-face)
     (2 'luau-variable-face nil noerror)
     (3 'luau-variable-face nil noerror)
     (4 'luau-variable-face nil noerror)
     (5 'luau-variable-face nil noerror)
     (6 'luau-variable-face nil noerror)
     (7 'luau-variable-face nil noerror)
     (8 'luau-variable-face nil noerror)
     (9 'luau-variable-face nil noerror))

    (,(luau-rx (or (group-n 1
                           "@" (symbol "author" "copyright" "field" "release"
                                       "return" "see" "usage" "description"))
                  (seq (group-n 1 "@" (symbol "param" "class" "name")) ws+
                       (group-n 2 luau-name))))
     (1 'luau-keyword-face t)
     (2 'luau-variable-face t noerror)))
  "Default expressions to highlight in Lua mode.")

(defvar luau-imenu-generic-expression
  `(("Requires" ,(luau-rx (or bol ";") ws (opt (seq (symbol "local") ws))
                         (group-n 1 luau-name) ws "=" ws (symbol "require"))
     1)
    (nil ,(luau-rx (or bol ";") ws (opt (seq (symbol "local") ws))
                  luau-funcheader)
         1))
  "Imenu generic expression for `luau-mode'.
See `imenu-generic-expression'.")

(defvar luau-sexp-alist '(("then" . "end")
                         ("function" . "end")
                         ("do" . "end")
                         ("repeat" . "until")))

(defvar luau-mode-abbrev-table nil
  "Abbreviation table used in `luau-mode' buffers.")

(define-abbrev-table 'luau-mode-abbrev-table
  '(("end"    "end"    luau-indent-line :system t)
    ("else"   "else"   luau-indent-line :system t)
    ("elseif" "elseif" luau-indent-line :system t)))

(defvar luau-mode-syntax-table
  (with-syntax-table (copy-syntax-table)
    ;; Main comment syntax: begins with "--", ends with "\n"
    (modify-syntax-entry ?- ". 12")
    (modify-syntax-entry ?\n ">")

    ;; Main string syntax: bounded by ' or "
    (modify-syntax-entry ?\' "\"")
    (modify-syntax-entry ?\" "\"")
    (modify-syntax-entry ?` "\"")

    ;; Single-character binary operators: punctuation
    (modify-syntax-entry ?+ ".")
    (modify-syntax-entry ?* ".")
    (modify-syntax-entry ?/ ".")
    (modify-syntax-entry ?^ ".")
    (modify-syntax-entry ?% ".")
    (modify-syntax-entry ?> ".")
    (modify-syntax-entry ?< ".")
    (modify-syntax-entry ?= ".")
    (modify-syntax-entry ?~ ".")

    (syntax-table))
  "`luau-mode' syntax table.")

;;;###autoload
(define-derived-mode luau-mode prog-mode "Luau"
  "Major mode for editing Luau code without requiring `lua-mode`."
  :abbrev-table luau-mode-abbrev-table
  :syntax-table luau-mode-syntax-table
  (setq-local font-lock-defaults '(luau-font-lock-keywords ; keywords
                                   nil                    ; keywords-only
                                   nil                    ; case-fold
                                   nil                    ; syntax-alist
                                   nil))                  ; syntax-begin

  (setq-local syntax-propertize-function
              'luau--propertize-multiline-bounds)

  (setq-local parse-sexp-lookup-properties t)
  (setq-local indent-line-function 'luau-indent-line)
  (setq-local beginning-of-defun-function 'luau-beginning-of-proc)
  (setq-local end-of-defun-function 'luau-end-of-proc)
  (setq-local comment-start luau-comment-start)
  (setq-local comment-start-skip luau-comment-start-skip)
  (setq-local comment-use-syntax t)
  (setq-local fill-paragraph-function #'luau--fill-paragraph)
  (with-no-warnings
    (setq-local comment-use-global-state t))
  (setq-local imenu-generic-expression luau-imenu-generic-expression)
  (luau-interface-setup)
  (luau-browser-setup)
  (when (boundp 'electric-indent-chars)
    ;; If electric-indent-chars is not defined, electric indentation is
    ;; done via `luau-mode-map'.
    (setq-local electric-indent-chars
                (append electric-indent-chars luau--electric-indent-chars)))
  (when luau-enable-legacy-luacheck
    (add-hook 'flymake-diagnostic-functions #'luau-flymake nil t))

  ;; Hide-show setup
  (setq-local hs-block-start-regexp (regexp-opt (mapcar 'car luau-sexp-alist) 'words))
  (setq-local hs-block-end-regexp (regexp-opt (mapcar 'cdr luau-sexp-alist) 'words))
  (setq-local hs-forward-sexp-function #'luau-forward-sexp))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.luau\\'" . luau-mode))

;;;###autoload
(add-to-list 'interpreter-mode-alist '("luau" . luau-mode))

(defun luau-electric-match (arg)
  "Insert character ARG and adjust indentation."
  (interactive "P")
  (let (blink-paren-function)
    (self-insert-command (prefix-numeric-value arg)))
  (when luau-electric-flag
    (luau-indent-line))
  (blink-matching-open))

;; Private functions

(defun luau--fill-paragraph (&optional justify region)
  "Implementation of `forward-paragraph' for filling.

This function works around a corner case in the following situations:

    <>
    -- some very long comment ....
    some_code_right_after_the_comment

If point is at the beginning of the comment line, fill paragraph code
would have gone for comment-based filling and done the right thing, but
it does not find a comment at the beginning of the empty line before the
comment and falls back to text-based filling ignoring `comment-start'
and spilling the comment into the code.

The arguments JUSTIFY and REGION control `fill-paragraph' (which see)."
  (save-excursion
    (while (and (not (eobp))
                (progn (move-to-left-margin)
                       (looking-at paragraph-separate)))
      (forward-line 1))
    (let ((fill-paragraph-handle-comment t))
      (fill-paragraph justify region))))

(defun luau-prefix-key-update-bindings ()
  "Update prefix key bindings."
  (if (eq luau-prefix-mode-map (keymap-parent luau-mode-map))
      ;; If prefix-map is a parent, delete the parent
      (set-keymap-parent luau-mode-map nil)
    ;; Otherwise, look for it among children
    (when-let* ((old-cons (rassoc luau-prefix-mode-map luau-mode-map)))
      (delq old-cons luau-mode-map)))
  (if (eq 'ignore (elt luau-prefix-key 0))
      (set-keymap-parent luau-mode-map luau-prefix-mode-map)
    (define-key luau-mode-map luau-prefix-key luau-prefix-mode-map)))

(defun luau-set-prefix-key (new-key-str)
  "Change `luau-prefix-key' to NEW-KEY-STR and update keymaps.

This function replaces previous prefix-key binding with a new one."
  (interactive "sNew prefix key (empty string means no key): ")
  (luau--customize-set-prefix-key 'luau-prefix-key (kbd new-key-str))
  (message "Prefix key set to %S" luau-prefix-key))

(defun luau-string-p (&optional pos)
  "Return non-nil if point or POS is in a string."
  (save-excursion (elt (syntax-ppss pos) 3)))

(defun luau--containing-double-hyphen-start-pos ()
  "Return position of the beginning comment delimiter (--).

Emacs syntax framework does not consider comment delimiters as
part of the comment itself, but for this package it is useful to
consider point as inside comment when it is between the two hyphens"
  (and (eql (char-before) ?-)
       (eql (char-after) ?-)
       (1- (point))))

(defun luau-comment-start-pos (&optional parsing-state)
  "Return position of comment containing current point.

If point is not inside a comment, return nil.

The argument PARSING-STATE is a `syntax-ppss' state."
  (if-let* ((parsing-state (or parsing-state (syntax-ppss)))
            ((not (nth 3 parsing-state))) ; Not a string.
            ((nth 4 parsing-state)))      ; Syntax-based comment.
      (nth 8 parsing-state)
    (luau--containing-double-hyphen-start-pos)))

(defun luau-comment-or-string-p (&optional pos)
  "Return non-nil if point or POS is in a comment or string."
  (save-excursion
    (let ((parse-result (syntax-ppss pos)))
      (or (elt parse-result 3) (luau-comment-start-pos parse-result)))))

(defun luau-comment-or-string-start-pos (&optional pos)
  "Return start position of string or comment containing point or POS.

If point is not inside string or comment, return nil."
  (save-excursion
    (when pos (goto-char pos))
    (or (elt (syntax-ppss pos) 8)
        (luau--containing-double-hyphen-start-pos))))

;; They're propertized as follows:
;; 1. generic-comment
;; 2. generic-string
;; 3. equals signs
(defconst luau-ml-begin-regexp
  "\\(?:\\(?1:-\\)-\\[\\|\\(?2:\\[\\)\\)\\(?3:=*\\)\\[")

(defun luau-try-match-multiline-end (end)
  "Try to match close-bracket for multiline literal around point.

Basically, detect form of close bracket from syntactic information
provided at point and `re-search-forward' to it.

The argument END is a buffer position that bounds the search."
  (let ((comment-or-string-start-pos (luau-comment-or-string-start-pos)))
    ;; Is there a literal around point?
    (and comment-or-string-start-pos
         ;; It is, check if the literal is a multiline open-bracket
         (save-excursion
           (goto-char comment-or-string-start-pos)
           (looking-at luau-ml-begin-regexp))

         ;; Yes it is, look for it matching close-bracket.  Close
         ;; bracket's match group is determined by match-group of
         ;; open-bracket.
         (re-search-forward
          (format "]%s\\(?%s:]\\)"
                  (match-string-no-properties 3)
                  (if (match-beginning 1) 1 2))
          end 'noerror))))

(defun luau-try-match-multiline-begin (limit)
  "Try to match multiline open-brackets.

Find next opening long bracket outside of any string/comment.  If none
can be found before reaching LIMIT, return nil."
  (let (last-search-matched)
    (while
        ;; This loop will iterate skipping all multiline-begin tokens
        ;; that are inside strings or comments ending either at EOL or
        ;; at valid token.
        (and (setq last-search-matched
                   (re-search-forward luau-ml-begin-regexp limit 'noerror))
             ;; Ensure --[[ is not inside a comment or string.
             ;;
             ;; This includes "---[[" sequence, in which "--" at the
             ;; beginning creates a single-line comment, and thus "-[["
             ;; is no longer a multi-line opener.
             ;;
             ;; XXX: need to ensure syntax-ppss beyond (match-beginning
             ;; 0) is not calculated, or otherwise we'll need to flush
             ;; the cache.
             (luau-comment-or-string-start-pos (match-beginning 0))))

    last-search-matched))

(defun luau-match-multiline-literal-bounds (limit)
  "Move point to multi-line literal bound.
The argument LIMIT is a buffer position that bounds the search."
  ;; First, close any multiline literal spanning from previous block.
  ;; This will move the point accordingly so as to avoid double
  ;; traversal.
  (or (luau-try-match-multiline-end limit)
      (luau-try-match-multiline-begin limit)))

(defun luau--propertize-multiline-bounds (start end)
  "Put text properties on multiline literal bounds within START and END.

Intended to be used as a `syntax-propertize-function'."
  (save-excursion
    (goto-char start)
    (while (luau-match-multiline-literal-bounds end)
      (when (match-beginning 1)
        (put-text-property (match-beginning 1) (match-end 1)
                           'syntax-table (string-to-syntax "!")))
      (when (match-beginning 2)
        (put-text-property (match-beginning 2) (match-end 2)
                           'syntax-table (string-to-syntax "|"))))))

(defun luau-indent-line ()
  "Indent current line for Lua mode.
Return the amount the indentation changed by."
  (let (indent
        (case-fold-search nil)
        ;; Save point as a distance to eob - it's invariant w.r.t
        ;; indentation.
        (pos (- (point-max) (point))))
    (back-to-indentation)
    (setq indent (if (luau-comment-or-string-p)
                     ;; Just restore point position.
                     (luau-calculate-string-or-comment-indentation)
                   (max 0 (luau-calculate-indentation))))

    (unless (equal indent (current-column))
      (delete-region (line-beginning-position) (point))
      (indent-to indent))

    ;; If initial point was within line's indentation, position after
    ;; the indentation.  Else stay at same point in text.
    (when (> (- (point-max) pos) (point))
      (goto-char (- (point-max) pos)))

    indent))

(defun luau-calculate-string-or-comment-indentation ()
  "This should be run when point at `current-indentation' is in a string."
  (if (and (luau-string-p)
           (not luau-indent-string-contents))
      ;; If inside string and strings aren't to be indented, return
      ;; current indentation.
      (current-indentation)

    ;; At this point, we know that we're inside comment, so make sure
    ;; close-bracket is unindented like a block that starts after
    ;; left-shifter.
    (let ((left-shifter-p (looking-at "\\s *\\(?:--\\)?\\]\\(?1:=*\\)\\]")))
      (save-excursion
        (goto-char (luau-comment-or-string-start-pos))
        (+ (current-indentation)
           (if (and left-shifter-p
                    (looking-at (format "--\\[%s\\["
                                        (match-string-no-properties 1))))
               0
             luau-indent-level))))))

(defun luau--signum (x)
  "Return 1 if X is positive, -1 if negative, 0 if zero."
  (cond ((> x 0) 1) ((< x 0) -1) (t 0)))

(defun luau--ensure-point-within-limit (limit backward)
  "Return non-nil if point is within LIMIT going forward.

With BACKWARD non-nil, return non-nil if point is within LIMIT going
backward.

If point is beyond limit, move it onto limit."
  (if (= (luau--signum (- (point) limit))
         (if backward 1 -1))
      t
    (goto-char limit)
    nil))

(defun luau--escape-from-string (&optional backward)
  "Move point outside of string if it is inside one.

By default, point is placed after the string, with BACKWARD it is placed
before the string."
  (interactive)
  (let ((parse-state (syntax-ppss)))
    (when (nth 3 parse-state)
      (if backward
          (goto-char (nth 8 parse-state))
        (parse-partial-sexp
         (point) (line-end-position) nil nil (syntax-ppss) 'syntax-table))
      t)))

(defun luau-find-regexp (direction regexp &optional limit)
  "Search for a regular expression in the direction specified.

DIRECTION is one of \\='forward and \\='backward.

Matches in comments and strings are ignored.  If the REGEXP is found,
returns point position, nil otherwise.

The argument LIMIT is a buffer position that bounds the search."
  (let ((search-func (if (eq direction 'forward)
                         're-search-forward 're-search-backward))
        (case-fold-search nil))
    (cl-loop
     always (or (null limit)
                (luau--ensure-point-within-limit
                 limit (not (eq direction 'forward))))
     always (funcall search-func regexp limit 'noerror)
     for match-beg = (match-beginning 0)
     for match-end = (match-end 0)
     while (or (luau-comment-or-string-p match-beg)
               (luau-comment-or-string-p match-end))
     do (let ((parse-state (syntax-ppss)))
          (cond
           ;; Inside a string
           ((nth 3 parse-state)
            (luau--escape-from-string (not (eq direction 'forward))))
           ;; Inside a comment
           ((nth 4 parse-state)
            (goto-char (nth 8 parse-state))
            (when (eq direction 'forward)
              (forward-comment 1)))))
     finally return (point))))

(defconst luau-block-regexp
  (eval-when-compile
    (rx (or (group symbol-start
                   (group (or "do" "function" "repeat" "then"
                              "else" "elseif" "end" "until"))
                   symbol-end)
            (group (any "()[]{}"))))))

(defconst luau-block-token-alist
  '(("do" "\\_<end\\_>" "\\_<for\\|while\\_>" middle-or-open)
    ("function" "\\_<end\\_>" nil open)
    ("repeat" "\\_<until\\_>" nil open)
    ("then"
     "\\_<\\(e\\(lse\\(if\\)?\\|nd\\)\\)\\_>" "\\_<\\(else\\)?if\\_>" middle)
    ("{" "}" nil open)
    ("[" "]" nil open)
    ("(" ")" nil open)
    ("if" "\\_<then\\_>" nil open)
    ("for" "\\_<do\\_>" nil open)
    ("while" "\\_<do\\_>" nil open)
    ("else" "\\_<end\\_>" "\\_<then\\_>" middle)
    ("elseif" "\\_<then\\_>" "\\_<then\\_>" middle)
    ("end" nil "\\_<\\(do\\|function\\|then\\|else\\)\\_>" close)
    ("until" nil "\\_<repeat\\_>" close)
    ("}" nil "{" close)
    ("]" nil "\\[" close)
    (")" nil "(" close))
  "This is a list of block token information blocks.

Each token information entry is of the form:
  KEYWORD FORWARD-MATCH-REGEXP BACKWARDS-MATCH-REGEXP TOKEN-TYPE

KEYWORD is the token.

FORWARD-MATCH-REGEXP is a regexp that matches all possible tokens when
going forward.

BACKWARDS-MATCH-REGEXP is a regexp that matches all possible tokens when
going backwards.

TOKEN-TYPE determines where the token occurs on a statement.  Open
indicates that the token appears at start, close indicates that it
appears at end, middle indicates that it is a middle type token, and
middle-or-open indicates that it can appear both as a middle or an open
type.")

(defconst luau-indentation-modifier-regexp
  ;; The absence of else is deliberate, since it does not modify the
  ;; indentation level per se.  It only may cause the line, in which the
  ;; else is, to be shifted to the left.
  (rx (or (group (or (seq symbol-start
                          (group (or "do" "function" "repeat" "then" "if"
                                     "else" "elseif" "for" "while"))
                          symbol-end)
                     (any "([{")))
          (group (or (seq symbol-start
                          (group (or "end" "until"))
                          symbol-end)
                     (any ")]}"))))))

(defun luau-get-block-token-info (token)
  "Return the block token info entry for TOKEN from `luau-block-token-alist'."
  (assoc token luau-block-token-alist))

(defun luau-get-token-match-re (token-info direction)
  "Return the relevant match regexp from TOKEN-INFO.

The argument DIRECTION controls if the search goes forward or backward."
  (cond
   ((eq direction 'forward) (cadr token-info))
   ((eq direction 'backward) (nth 2 token-info))
   (t nil)))

(defun luau-get-token-type (token-info)
  "Return the relevant match regexp from TOKEN-INFO."
  (nth 3 token-info))

(defun luau-backwards-to-block-begin-or-end ()
  "Move backwards to nearest block begin or end.
Return nil if unsuccessful."
  (interactive)
  (luau-find-regexp 'backward luau-block-regexp))

(defun luau-find-matching-token-word (token &optional direction)
  "Find matching open- or close-token for TOKEN in DIRECTION.
Point has to be exactly at the beginning of TOKEN, e.g. with | being
point

  {{ }|}  -- (luau-find-matching-token-word \"}\" \\='backward) will return
          -- the first {
  {{ |}}  -- (luau-find-matching-token-word \"}\" \\='backward) will find
          -- the second {.

DIRECTION has to be either \\='forward or \\='backward."
  (let* ((token-info (luau-get-block-token-info token))
         (match-type (luau-get-token-type token-info))
         ;; If we are on a middle token, go backwards.  If it is a
         ;; middle or open, go forwards
         (search-direction (or direction
                               (if (or (eq match-type 'open)
                                       (eq match-type 'middle-or-open))
                                   'forward
                                 'backward)
                               'backward))
         (match (luau-get-token-match-re token-info search-direction))
         maybe-found-pos)
    ;; If we are searching forward from the token at the current point
    ;; (i.e. for a closing token), need to step one character forward
    ;; first, or the regexp will match the opening token.
    (when (eq search-direction 'forward) (forward-char 1))
    (catch 'found
      ;; If we are attempting to find a matching token for a terminating
      ;; token (i.e. a token that starts a statement when searching
      ;; back, or a token that ends a statement when searching forward),
      ;; then we don't need to look any further.
      (when (or (and (eq search-direction 'forward)
                     (eq match-type 'close))
                (and (eq search-direction 'backward)
                     (eq match-type 'open)))
        (throw 'found nil))
      (while (luau-find-regexp search-direction luau-indentation-modifier-regexp)
        ;; Have we found a valid matching token?
        (let* ((found-token (match-string 0))
               (found-pos (match-beginning 0))
               (found-type (luau-get-token-type
                            (luau-get-block-token-info found-token))))
          (if (not (and match (string-match match found-token)))
              ;; No - then there is a nested block. If we were looking
              ;; for a block begin token, found-token must be a block
              ;; end token; likewise, if we were looking for a block end
              ;; token, found-token must be a block begin token,
              ;; otherwise there is a grammatical error in the code.
              (unless (and (or (eq match-type 'middle)
                               (eq found-type 'middle)
                               (eq match-type 'middle-or-open)
                               (eq found-type 'middle-or-open)
                               (eq match-type found-type))
                           (progn
                             (goto-char found-pos)
                             (luau-find-matching-token-word
                              found-token search-direction)))
                (when maybe-found-pos
                  (goto-char maybe-found-pos)
                  (throw 'found maybe-found-pos)))
            ;; Yes.
            ;; If it is a not a middle kind, report the location
            (unless (or (eq found-type 'middle)
                        (eq found-type 'middle-or-open))
              (throw 'found found-pos))
            ;; If it is a middle-or-open type, record location, but keep
            ;; searching.  If we fail to complete the search, we'll
            ;; report the location
            (when (eq found-type 'middle-or-open)
              (setq maybe-found-pos found-pos))
            ;; Cannot use tail recursion.  Too much nesting on long
            ;; chains of if/elseif. Will reset variables instead.
            (setq token found-token)
            (setq token-info (luau-get-block-token-info token))
            (setq match (luau-get-token-match-re token-info search-direction))
            (setq match-type (luau-get-token-type token-info)))))
      maybe-found-pos)))

(defun luau-goto-matching-block-token (&optional parse-start direction)
  "Find block begin/end token matching the one at the point.
This function moves the point to the token that matches the one at the
current point.  Returns the point position of the first character of the
matching token if successful, nil otherwise.

Optional PARSE-START is a position to which the point should be moved
first.

DIRECTION has to be \\='forward or \\='backward (\\='forward by default)."
  (when parse-start (goto-char parse-start))
  (let ((case-fold-search nil))
    (when-let* (((looking-at luau-indentation-modifier-regexp))
                (position (luau-find-matching-token-word
                           (match-string 0) direction)))
      (goto-char position))))

(defun luau-goto-matching-block (&optional noreport)
  "Go to the keyword balancing the one under the point.
If the point is on a keyword/brace that starts a block, go to the
matching keyword that ends the block, and vice versa.

If optional NOREPORT is non-nil, it won't flag an error if there is no
block open/close open."
  (interactive)
  ;; Search backward to the beginning of the keyword if necessary
  (when (and (eq (char-syntax (following-char)) ?w)
             (not (looking-at "\\_<")))
    (re-search-backward "\\_<" nil t))
  (if-let* ((position (luau-goto-matching-block-token)))
      position
    (unless noreport (error "Not on a block control keyword or brace"))))

(defun luau-skip-ws-and-comments-backward (&optional limit)
  "Move point back skipping all whitespace and comments.

If LIMIT is given, stop at it or before.

Return non-nil if moved point."
  (interactive)
  (unless (luau-string-p)
    (let ((start-pos (point))
          (comment-start-pos (luau-comment-start-pos))
          (limit (min (point) (or limit (point-min)))))
      (when comment-start-pos (goto-char (max limit comment-start-pos)))
      (when (< limit (point)) (forward-comment (- limit (point))))
      (when (< (point) limit) (goto-char limit))
      (when (/= start-pos (point)) (point)))))

(defun luau-skip-ws-and-comments-forward (&optional limit)
  "Move point forward skipping all whitespace and comments.

If LIMIT is given, stop at it or before.

Return non-nil if moved point."
  (interactive)
  (unless (luau-string-p)
    (let ((start-pos (point))
          (comment-start-pos (luau-comment-start-pos))
          (limit (max (point) (or limit (point-max)))))
      ;; Escape from current comment.  It is necessary to use "while"
      ;; because luadoc parameters have non-comment face, and
      ;; parse-partial-sexp with 'syntax-table flag will stop on them.
      (when comment-start-pos
        (goto-char comment-start-pos)
        (forward-comment 1))
      (when (< (point) limit) (forward-comment (- limit (point))))
      (when (< limit (point)) (goto-char limit))
      (when (/= start-pos (point)) (point)))))

(defun luau-forward-line-skip-blanks (&optional back)
  "Move 1 line forward/backward and skip insignificant ws/comment lines.

Moves point 1 line forward (or backward) skipping lines that contain no
Lua code besides comments.  The point is put to the beginning of the
line.

Returns final value of point as integer or nil if operation failed.

Non-nil argument BACK changes the direction to backwards."
  (let ((start-pos (point)))
    (if back
        (progn
          (beginning-of-line)
          (luau-skip-ws-and-comments-backward))
      (forward-line)
      (luau-skip-ws-and-comments-forward))
    (beginning-of-line)
    (when (> (count-lines start-pos (point)) 0)
      (point))))

(eval-when-compile
  (defconst luau-operator-class
    "-+*/^.=<>~:&|"))

(defconst luau-cont-eol-regexp
  (eval-when-compile
    (rx-to-string
     `(seq (or (group-n 1
                 symbol-start
                 (group (or "and" "or" "not" "in" "for" "while" "local"
                            "function" "if" "until" "elseif" "return"))
                 symbol-end)
               (seq (or bol (not (any ,luau-operator-class)))
                    (group-n 2
                      (group (or "%" "&" "*" "+" "," "-" "." ".." "/" ":"
                                 "<" "<<" "<=" "=" "==" ">" ">=" ">>" "^"
                                 "|" "~" "~=")))))
           (zero-or-more (syntax whitespace))
           point)))
  "Regexp that matches the ending of a line that needs continuation.

This regexp starts from eol and looks for a binary operator or an
unclosed block intro (i.e. `for' without `do' or `if' without `then')
followed by an optional whitespace till the end of the line.")

(defconst luau-cont-bol-regexp
  (eval-when-compile
    (rx-to-string
     `(seq point (zero-or-more (syntax whitespace))
           (or (group-n 1
                 symbol-start
                 (group (or "and" "in" "not" "or"))
                 symbol-end)
               (seq (group-n 2
                      (group (or "%" "&" "*" "+" "," "-" "." ".." "/" ":"
                                 "<" "<<" "<=" "=" "==" ">" ">=" ">>" "^"
                                 "|" "~" "~=")))
                    (or eol (not (any ,luau-operator-class))))))))
  "Regexp that matches a line that continues previous one.

This regexp means, starting from point there is an optional whitespace
followed by Lua binary operator.  Lua is very liberal when it comes to
continuation line, so we're safe to assume that every line that starts
with a binop continues previous one even though it looked like an
end-of-statement.")

(defun luau-last-token-continues-p ()
  "Return non-nil if the last token on this line is a continuation token."
  (let ((line-begin (line-beginning-position))
        return-value)
    (save-excursion
      (end-of-line)
      (luau-skip-ws-and-comments-backward line-begin)
      (setq return-value (and (re-search-backward luau-cont-eol-regexp line-begin t)
                              (or (match-beginning 1)
                                  (match-beginning 2))))
      (when (and return-value
                 (string-equal (match-string-no-properties 0) "return"))
        ;; "return" keyword is ambiguous and depends on next token
        (unless (save-excursion
                  (goto-char (match-end 0))
                  (forward-comment (point-max))
                  (and
                   ;; Not continuing: at end of file
                   (not (eobp))
                   (or
                    ;; "function" keyword: it is a continuation, e.g.
                    ;;
                    ;;    return
                    ;;       function() return 123 end
                    ;;
                    (looking-at (luau-rx (symbol "function")))
                    ;; Looking at semicolon or any other keyword: not
                    ;; continuation
                    (not (looking-at (luau-rx (or ";" luau-keyword)))))))
          (setq return-value nil)))
      return-value)))

(defun luau-first-token-continues-p ()
  "Return non-nil if the first token on this line is a continuation token."
  (let ((line-end (line-end-position)))
    (save-excursion
      (beginning-of-line)
      (luau-skip-ws-and-comments-forward line-end)
      ;; If first character of the line is inside string, it's a
      ;; continuation if strings aren't supposed to be indented,
      ;; `luau-calculate-indentation' won't even let the control inside
      ;; this function
      (and
       (re-search-forward luau-cont-bol-regexp line-end t)
       (or (match-beginning 1)
           (match-beginning 2))))))

(defun luau--backward-up-list-noerror ()
  "Safe version of `luau-backward-up-list' that does not signal an error."
  (condition-case nil
      (luau-backward-up-list)
    (scan-error nil)))

(defun luau-backward-up-list ()
  "Goto starter/opener of the block containing point."
  (interactive)
  (let ((start-pos (point))
        end-pos)
    (or
     ;; Return parent block opener token if it exists.
     (cl-loop
      ;; Search indentation modifier backward, return nil on failure.
      always (luau-find-regexp 'backward luau-indentation-modifier-regexp)
      ;; Fetch info about the found token
      for token = (match-string-no-properties 0)
      for token-info = (luau-get-block-token-info token)
      for token-type = (luau-get-token-type token-info)
      ;; If the token is a close token, continue to skip its opener. If not
      ;; close, stop and return found token.
      while (eq token-type 'close)
      ;; Find matching opener to skip it and continue from beginning.
      ;;
      ;; Return nil on failure.
      always (let ((position (luau-find-matching-token-word token 'backward)))
               (and position (goto-char position)))
      finally return token-info)
     (progn
       (setq end-pos (point))
       (goto-char start-pos)
       (signal 'scan-error
               (list "Block open token not found"
                     ;; If start-pos == end-pos, the "obstacle" is current
                     (if (eql start-pos end-pos) start-pos (match-beginning 0))
                     (if (eql start-pos end-pos) start-pos (match-end 0))))))))

(defun luau--continuation-breaking-line-p ()
  "Return non-nil if looking at token(-s) that forbid continued line."
  (save-excursion
    (luau-skip-ws-and-comments-forward (line-end-position))
    (looking-at (luau-rx (or (symbol "do" "while" "repeat" "until"
                                    "if" "then" "elseif" "else"
                                    "for" "local")
                            luau-funcheader)))))

(defun luau-is-continuing-statement-p-1 ()
  "Return non-nil if current line continues a statement.

More specifically, return the point in the line that is continued.
The criteria for a continuing statement are:

* The last token of the previous line is a continuing op,
  OR the first token of the current line is a continuing op.

* The expression is not enclosed by a parentheses/braces/brackets."
  (let (prev-line continuation-pos parent-block-opener)
    (save-excursion (setq prev-line (luau-forward-line-skip-blanks 'back)))
    (and prev-line
         (not (luau--continuation-breaking-line-p))
         (save-excursion
           ;; Binary operator or keyword that implies continuation.
           (and (setq continuation-pos
                      (or (luau-first-token-continues-p)
                          (save-excursion
                            (goto-char prev-line)
                            ;; Check last token of previous nonblank line
                            (luau-last-token-continues-p))))
                (not
                 ;; Operators/keywords does not create continuation
                 ;; inside some blocks:
                 (and (setq parent-block-opener
                            (car-safe (luau--backward-up-list-noerror)))
                      (or
                       ;; Inside parens/brackets
                       (member parent-block-opener '("(" "["))
                       ;; Inside braces if it is a comma
                       (and (eq (char-after continuation-pos) ?,)
                            (equal parent-block-opener "{")))))
                continuation-pos)))))

(defun luau-is-continuing-statement-p (&optional parse-start)
  "Return non-nil if PARSE-START should be indented as continuation line.

This true is when the line:

* Is continuing a statement itself

* Starts with a 1+ block-closer tokens, an top-most block opener is on a
  continuation line."
  (save-excursion
    (when parse-start (goto-char parse-start))

    ;; If line starts with a series of closer tokens, whether or not the
    ;; line is a continuation line is decided by the opener line, e.g.
    ;;
    ;; x = foo +
    ;;    long_function_name(
    ;;       long_parameter_1,
    ;;       long_parameter_2,
    ;;       long_parameter_3,
    ;;    ) + long_function_name2({
    ;;       long_parameter_1,
    ;;       long_parameter_2,
    ;;       long_parameter_3,
    ;;    })
    ;;
    ;; Final line, "})" is a continuation line, but it is decided by the
    ;; opener line, ") + long_function_name2({", which in its turn is
    ;; decided by the "long_function_name(" line, which is a
    ;; continuation line because the line before it ends with a binary
    ;; operator.
    (cl-loop
     ;; Go to opener line
     while (and (luau--goto-line-beginning-rightmost-closer)
                (luau--backward-up-list-noerror))
     ;; If opener line is continuing, repeat.  If opener line is not
     ;; Continuing, return nil.
     always (luau-is-continuing-statement-p-1)
     ;; We get here if there was no opener to go to: check current line.
     finally return (luau-is-continuing-statement-p-1))))

(defun luau-make-indentation-info-pair (found-token found-pos)
  "Create a pair from FOUND-TOKEN and FOUND-POS for indentation calculation.

This is a helper function to `luau-calculate-indentation-info'.
Don't use standalone."
  (cond
   ;; Functions are a bit tricky to indent right.  They can appear in a
   ;; lot ot different contexts.  Until I find a shortcut, I'll leave it
   ;; with a simple relative indentation.
   ;; The special cases are for indenting according to the location of
   ;; the function. i.e.:
   ;;     (cons 'absolute (+ (current-column) luau-indent-level))
   ;; TODO: Fix this.  It causes really ugly indentations for in-line
   ;; functions.
   ((string-equal found-token "function")
    (cons 'relative luau-indent-level))

   ;; Block openers
   ((and luau-indent-nested-block-content-align
         (member found-token (list "{" "(" "[")))
    (save-excursion
      (let ((found-bol (line-beginning-position)))
        (forward-comment (point-max))
        ;; If the next token is on this line and it's not a block
        ;; opener, the next line should align to that token.
        (if (and (zerop (count-lines found-bol (line-beginning-position)))
                 (not (looking-at luau-indentation-modifier-regexp)))
            (cons 'absolute (current-column))
          (cons 'relative luau-indent-level)))))

   ;; These are not really block starters.  They should not add to
   ;; indentation.  The corresponding "then" and "do" handle the
   ;; indentation.
   ((member found-token (list "if" "for" "while"))
    (cons 'relative 0))
   ;; closing tokens follow: These are usually taken care of by
   ;; luau-calculate-indentation-override.
   ;; elseif is a bit of a hack. It is not handled separately, but it
   ;; needs to nullify a previous then if on the same line.
   ((member found-token (list "until" "elseif"))
    (save-excursion
      (let* ((line-beginning (line-beginning-position))
             (same-line (and (luau-goto-matching-block-token found-pos 'backward)
                             (<= line-beginning (point)))))
        (if same-line
            (cons 'remove-matching 0)
          (cons 'relative 0)))))

   ;; else is a special case; if its matching block token is on the same
   ;; line, instead of removing the matching token, it has to replace
   ;; it, so that either the next line will be indented correctly, or
   ;; the end on the same line will remove the effect of the else.
   ((string-equal found-token "else")
    (save-excursion
      (let* ((line-beginning (line-beginning-position))
             (same-line (and (luau-goto-matching-block-token found-pos 'backward)
                             (<= line-beginning (point)))))
        (if same-line
            (cons 'replace-matching (cons 'relative luau-indent-level))
          (cons 'relative luau-indent-level)))))

   ;; Block closers.  If they are on the same line as their openers,
   ;; they simply eat up the matching indentation modifier.  Otherwise,
   ;; they pull indentation back to the matching block opener.
   ((member found-token (list ")" "}" "]" "end"))
    (save-excursion
      (let* ((line-beginning (line-beginning-position))
             (same-line (and (luau-goto-matching-block-token found-pos 'backward)
                             (<= line-beginning (point))))
             (opener-pos (point))
             opener-continuation-offset)
        (if same-line
            (cons 'remove-matching 0)
          (back-to-indentation)
          (setq opener-continuation-offset
                (if (luau-is-continuing-statement-p-1) luau-indent-level 0))

          ;; Accumulate indentation up to opener, including indentation.
          ;; If there were no other indentation modifiers until said
          ;; opener, ensure there is no continuation after the closer.
          `(multiple . ((absolute . ,(- (current-indentation)
                                        opener-continuation-offset))
                        ,@(when (/= opener-continuation-offset 0)
                            (list (cons 'continued-line
                                        opener-continuation-offset)))
                        ,@(delete nil (list (luau-calculate-indentation-info-1
                                             nil opener-pos)))
                        (cancel-continued-line . nil)))))))

   ((member found-token '("do" "then"))
    `(multiple . ((cancel-continued-line . nil) (relative . ,luau-indent-level))))

   ;; Everything else.  This is from the original code: If opening a
   ;; block (match-data 1 exists), then push indentation one level up,
   ;; if it is closing a block, pull it one level down.
   ('other-indentation-modifier
    (cons 'relative (if (nth 2 (match-data))
                        ;; Beginning of a block matched
                        luau-indent-level
                      ;; End of a block matched
                      (- luau-indent-level))))))

(defun  luau-add-indentation-info-pair (pair info-list)
  "Add the indentation info PAIR to the list of indentation INFO-LIST.
This function has special case handling for two tokens: remove-matching,
and replace-matching.  These two tokens are cleanup tokens that remove
or alter the effect of a previously recorded indentation info.

When a remove-matching token is encountered, the last recorded info,
i.e. the car of the list is removed.  This is used to roll-back an
indentation of a block opening statement when it is closed.

When a replace-matching token is seen, the last recorded info is
removed, and the cdr of the replace-matching info is added in its place.
This is used when a middle-of the block (the only case is `else') is
seen on the same line the block is opened."
  (cond
   ((eq 'multiple (car pair))
     (let ((info-pair-elts (cdr pair)))
       (while info-pair-elts
         (setq info-list (luau-add-indentation-info-pair
                          (car info-pair-elts) info-list)
               info-pair-elts (cdr info-pair-elts)))
       info-list))
   ((eq 'cancel-continued-line (car pair))
     (if (eq (caar info-list) 'continued-line)
         (cdr info-list)
       info-list))
   ((eq 'remove-matching (car pair))
     ;; Remove head of list
     (cdr info-list))
   ((eq 'replace-matching (car pair))
     ;; Remove head of list, and add the cdr of pair instead
     (cons (cdr pair) (cdr info-list)))
   ((listp (cdr-safe pair))
     (nconc pair info-list))
   (t
     ;; Just add the pair
     (cons pair info-list))))

(defun luau-calculate-indentation-info-1 (indentation-info bound)
  "Helper function for `luau-calculate-indentation-info'.

Return list of indentation modifiers from point to BOUND.

The argument INDENTATION-INFO is an indentation INFO-LIST."
  (while (luau-find-regexp 'forward luau-indentation-modifier-regexp
                          bound)
    (let ((found-token (match-string 0))
          (found-pos (match-beginning 0)))
      (setq indentation-info
            (luau-add-indentation-info-pair
             (luau-make-indentation-info-pair found-token found-pos)
             indentation-info))))
  indentation-info)

(defun luau-calculate-indentation-info (&optional parse-end)
  "Compute how each block token on the line affects indentation.
The effect of each token can be either a shift relative to the current
indentation level, or indentation to some absolute column.  This
information is collected in a list of indentation info pairs, which
denote absolute and relative each, and the shift/column to indent to.

The argument PARSE-END is a buffer position that bounds the calculation."
  (let (indentation-info cont-stmt-pos)
    (while (setq cont-stmt-pos (luau-is-continuing-statement-p))
      (luau-forward-line-skip-blanks 'back)
      (when (< cont-stmt-pos (point))
        (goto-char cont-stmt-pos)))

    ;; Calculate indentation modifiers for the line itself
    (setq indentation-info (list (cons 'absolute (current-indentation))))

    (back-to-indentation)
    (setq indentation-info
          (luau-calculate-indentation-info-1
           indentation-info (min parse-end (line-end-position))))

    ;; And do the following for each continuation line before PARSE-END
    (while (and (eql (forward-line 1) 0)
                (<= (point) parse-end))

      ;; Handle continuation lines:
      (if (luau-is-continuing-statement-p)
          ;; If it's the first continuation line, add one level
          (unless (eq (car (car indentation-info)) 'continued-line)
            (push (cons 'continued-line luau-indent-level) indentation-info))

        ;; If it's the first non-continued line, subtract one level
        (when (eq (car (car indentation-info)) 'continued-line)
          (push (cons 'stop-continued-line (- luau-indent-level)) indentation-info)))

      ;; Add modifiers found in this continuation line
      (setq indentation-info
            (luau-calculate-indentation-info-1
             indentation-info (min parse-end (line-end-position)))))

    indentation-info))

(defun luau-accumulate-indentation-info (reversed-indentation-info)
  "Accumulate indent information from `luau-calculate-indentation-info'.
Returns either the relative indentation shift, or the absolute column to
indent to.

The argument REVERSED-INDENTATION-INFO is an indentation INFO-LIST."
  (let (indentation-info
        (type 'relative)
        (accu 0))
    ;; Aggregate all neighboring relative offsets, reversing the INFO list.
    (dolist (elt reversed-indentation-info)
      (if (and (eq (car elt) 'relative)
               (eq (caar indentation-info) 'relative))
          (setcdr (car indentation-info) (+ (cdar indentation-info) (cdr elt)))
        (push elt indentation-info)))

    ;; Aggregate indentation info, taking 'absolute modifiers into account.
    (mapc (lambda (x)
            (if-let* ((new-val (cdr x))
                      ((eq 'absolute (car x))))
                (setq type 'absolute
                      accu new-val)
                (setq accu (+ accu new-val))))
          indentation-info)

    (cons type accu)))

(defun luau-calculate-indentation-block-modifier (&optional parse-end)
  "Return amount by which this line modifies the indentation.
Beginnings of blocks add `luau-indent-level' once each, and endings of
blocks subtract `luau-indent-level' once each.  This function is used to
determine how the indentation of the following line relates to this one.

The argument PARSE-END is a buffer position that bounds the calculation."
  (let (indentation-info)
    (save-excursion
      ;; First go back to the line that starts it all
      ;; luau-calculate-indentation-info will scan through the whole thing
      (let ((case-fold-search nil))
        (setq indentation-info
              (luau-accumulate-indentation-info
               (luau-calculate-indentation-info parse-end)))))

    (if (eq (car indentation-info) 'absolute)
        (- (cdr indentation-info) (current-indentation))
      (cdr indentation-info))))

(eval-when-compile
  (defconst luau--function-name-rx
    '(seq symbol-start
          (+ (any alnum "_"))
          (* "." (+ (any alnum "_")))
          (? ":" (+ (any alnum "_")))
          symbol-end)
    "Lua function name regexp in `rx'-SEXP format."))

(defconst luau--left-shifter-regexp
  (eval-when-compile
    (rx
     ;; This regexp should answer the following questions:
     ;; 1. Is there a left shifter regexp on that line?
     ;; 2. Where does block-open token of that left shifter reside?
     (or (seq (group-n 1 symbol-start "local" (+ blank)) "function" symbol-end)
         (seq (group-n 1 (eval luau--function-name-rx) (* blank)) (any "{("))
         (seq (group-n 1 (or
                          ;; Assignment statement prefix
                          (seq (* nonl) (not (any "<=>~")) "=" (* blank))
                          ;; Return statement prefix
                          (seq word-start "return" word-end (* blank))))
              ;; Right hand side
              (or "{"
                  "function"
                  "("
                  (seq (group-n 1 (eval luau--function-name-rx) (* blank))
                       (any "({")))))))

  "Regular expression that matches left-shifter expression.

Left-shifter expression is defined as follows.  If a block follows a
left-shifter expression, its contents & block-close token should be
indented relative to left-shifter expression indentation rather then to
block-open token.

For example:
   -- `local a = ' is a left-shifter expression
   -- `function' is a block-open token
   local a = function()
      -- block contents is indented relative to left-shifter
      foobarbaz()
   -- block-end token is unindented to left-shifter indentation
   end

The following left-shifter expressions are currently handled:
1. local function definition with function block, begin-end
2. function call with arguments block, () or {}
3. assignment/return statement with
   - table constructor block, {}
   - function call arguments block, () or {} block
   - function expression a.k.a. lambda, begin-end block.")

(defun luau-point-is-after-left-shifter-p ()
  "Check if point is right after a left-shifter expression.

See `luau--left-shifter-regexp' for description & example of left-shifter
expression."
  (save-excursion
    (let ((old-point (point)))
      (back-to-indentation)
      (and
       (/= (point) old-point)
       (looking-at luau--left-shifter-regexp)
       (= old-point (match-end 1))))))

(defun luau--goto-line-beginning-rightmost-closer (&optional parse-start)
  "Move point to the opening of the rightmost closing bracket at point.
The argument PARSE-START is a buffer position to start from."
  (let (case-fold-search pos line-end-pos return-val)
    (save-excursion
      (when parse-start (goto-char parse-start))
      (setq line-end-pos (line-end-position))
      (back-to-indentation)
      (unless (luau-comment-or-string-p)
        (cl-loop while (and (<= (point) line-end-pos)
                            (looking-at luau-indentation-modifier-regexp))
                 for token-info = (luau-get-block-token-info (match-string 0))
                 for token-type = (luau-get-token-type token-info)
                 while (not (eq token-type 'open))
                 do (progn
                      (setq pos (match-beginning 0)
                            return-val token-info)
                      (goto-char (match-end 0))
                      (forward-comment (line-end-position))))))
    (when pos
      (goto-char pos)
      return-val)))

(defun luau-calculate-indentation-override (&optional parse-start)
  "Return overriding indentation amount for special cases.

If there's a sequence of block-close tokens starting at the beginning of
the line, calculate indentation according to the line containing
block-open token for the last block-close token in the sequence.

If not, return nil.

Optional PARSE-START is a position to which the point should be moved
first."
  (let (case-fold-search rightmost-closer-info opener-info opener-pos)
    (save-excursion
      (when (and (setq rightmost-closer-info (luau--goto-line-beginning-rightmost-closer parse-start))
                 (setq opener-info (luau--backward-up-list-noerror))
                 ;; Ensure opener matches closer.
                 (string-match (luau-get-token-match-re rightmost-closer-info 'backward)
                               (car opener-info)))

        ;; Special case: "middle" tokens like for/do, while/do, if/then,
        ;; elseif/then: corresponding "end" or corresponding "else" must
        ;; be unindented to the beginning of the statement, which is not
        ;; necessarily the same as beginning of string that contains
        ;; "do", e.g.
        ;;
        ;; while (
        ;;    foo and
        ;;    bar) do
        ;;    hello_world()
        ;; end
        (setq opener-pos (point))
        (when (/= (- opener-pos (line-beginning-position)) (current-indentation))
          (unless (or
                   (and (string-equal (car opener-info) "do")
                        (member (car (luau--backward-up-list-noerror))
                                '("while" "for")))
                   (and (string-equal (car opener-info) "then")
                        (member (car (luau--backward-up-list-noerror))
                                '("if" "elseif"))))
            (goto-char opener-pos)))

        ;; (let (cont-stmt-pos)
        ;;   (while (setq cont-stmt-pos (luau-is-continuing-statement-p))
        ;;     (goto-char cont-stmt-pos)))
        ;; Exception cases: when the start of the line is an assignment,
        ;; go to the start of the assignment instead of the matching
        ;; item
        (if (and luau-indent-close-paren-align
                 (member (car opener-info) '("{" "(" "["))
                 (not (luau-point-is-after-left-shifter-p)))
            (current-column)
          (current-indentation))))))

(defun luau-calculate-indentation ()
  "Return appropriate indentation for current line as Lua code."
  (save-excursion
    (let ((cur-line-begin-pos (line-beginning-position)))
      (or
       ;; When calculating indentation, do the following:
       ;; 1. check, if the line starts with indentation-modifier
       ;;    (open/close brace) and if it should be indented/unindented
       ;;    in special way
       (luau-calculate-indentation-override)

       (when (luau-forward-line-skip-blanks 'back)
         ;; The order of function calls here is important. block
         ;; modifier call may change the point to another line
         (let* ((modifier
                 (luau-calculate-indentation-block-modifier cur-line-begin-pos)))
           (+ (current-indentation) modifier)))

       ;; 4. if there's no previous line, indentation is 0
       0))))

(defvar luau--beginning-of-defun-re
  (luau-rx-to-string '(: bol (? (symbol "local") ws+) luau-funcheader))
  "Luau function definition regexp for fallback navigation.")

(defun luau-beginning-of-proc (&optional arg)
  "Move backward to the beginning of a Lua proc (or similar).

With argument ARG, do it that many times.  Negative ARG -N means move
forward to Nth following beginning of proc.

Returns t unless search stops due to beginning or end of buffer."
  (interactive "P")
  (or arg (setq arg 1))

  (while (and (> arg 0)
              (re-search-backward luau--beginning-of-defun-re nil t))
    (setq arg (1- arg)))

  (while (and (< arg 0)
              (re-search-forward luau--beginning-of-defun-re nil t))
    (beginning-of-line)
    (setq arg (1+ arg)))

  (zerop arg))

(defun luau-end-of-proc (&optional arg)
  "Move forward to next end of Lua proc (or similar).

With argument ARG, do it that many times.  Negative ARG -N means move
back to Nth preceding end of proc.

This function just searches for a `end' at the beginning of a line."
  (interactive "P")
  (or arg
      (setq arg 1))
  (let ((found nil)
        (ret t))
    (if (and (< arg 0)
             (not (bolp))
             (save-excursion
               (beginning-of-line)
               (eq (following-char) ?})))
        (forward-char -1))
    (while (> arg 0)
      (if (re-search-forward "^end" nil t)
          (setq arg (1- arg)
                found t)
        (setq ret nil
              arg 0)))
    (while (< arg 0)
      (if (re-search-backward "^end" nil t)
          (setq arg (1+ arg)
                found t)
        (setq ret nil
              arg 0)))
    (if found
        (progn
          (beginning-of-line)
          (forward-line)))
    ret))

(defvar luau--legacy-process-init-code
  (mapconcat
   'identity
   '("local loadstring = loadstring or load"
     "function luaumode_loadstring(str, displayname, lineoffset)"
     "  if lineoffset > 1 then"
     "    str = string.rep('\\n', lineoffset - 1) .. str"
     "  end"
     ""
     "  local x, e = loadstring(str, '@'..displayname)"
     "  if e then"
     "    error(e)"
     "  end"
     "  return x()"
     "end"
     "\n")
   " "))

(defun luau-make-luau-string (str)
  "Convert STR to Lua literal."
  (concat "'"
          (replace-regexp-in-string
           (rx (or ?\" ?' ?\t ?\n ?\\))
           (lambda (s)
             (cdr (assq (aref s 0) '((?\" . "\\\"")
                                     (?\\ . "\\\\")
                                     (?\n . "\\n")
                                     (?\t . "\\t")
                                     (?'  . "\\'")))))
           str t t)
          "'"))

(defcustom luau-process-buffer-name nil
  "Name of the inferior Lua buffer.
The value nil means use the same name as `luau-default-application'."
  :type '(choice (const :tag "Default" nil) string)
  :safe 'string-or-null-p
  :version "31.1")

(defcustom luau-process-history-file nil
  "File used to save command history of the inferior Lua process.
The value nil means that no command history is saved."
  :type '(choice (const :tag "None" nil) file)
  :safe 'string-or-null-p
  :version "31.1")

(defcustom luau-process-startfile nil
  "Start file to load into the inferior Lua process at startup."
  :type '(choice (const :tag "None" nil) (file :must-match t))
  :version "31.1")

;;;###autoload
(defalias 'luau-run #'luau-start-process)

;;;###autoload
(defun luau-start-process (&optional name program startfile &rest switches)
  "Start a Lua process named NAME, running PROGRAM.
When called interactively, switch to the process buffer.

NAME is the name of the created process; default is
`luau-process-buffer-name' or `luau-default-application'.

PROGRAM is the executable to run; default is `luau-default-application'.

STARTFILE is a file, whose contents are sent to the process as initial
input; default is `luau-process-startfile'.

SWITCHES is a list of strings passed as arguments to PROGRAM; default is
`luau-default-command-switches'."
  (interactive)
  (if (not luau-default-application)
      (user-error "You must set `luau-default-application' to use this command")
    (let* ((name (or name
                     luau-process-buffer-name
                     (if (consp luau-default-application)
                         (car luau-default-application)
                       luau-default-application)))
           (program (or program luau-default-application)))
      ;; Don't re-initialize if there already is a Lua process.
      (unless (comint-check-proc (format "*%s*" name))
        (setq luau-process-buffer
              (apply #'make-comint name program
                     (or startfile luau-process-startfile)
                     (or (flatten-tree switches)
                         luau-default-command-switches)))
        (setq luau-process (get-buffer-process luau-process-buffer))
        (set-process-query-on-exit-flag luau-process nil)
        (with-current-buffer luau-process-buffer
          (setq-local comint-prompt-regexp luau-prompt-regexp)
          (setq-local comint-input-ring-file-name luau-process-history-file)
          (comint-read-input-ring t)
          (compilation-shell-minor-mode)
          (add-hook 'kill-buffer-hook #'comint-write-input-ring nil t)
          ;; The standalone Luau CLI may not provide a Lua-style prompt.
          ;; Never block mode initialization waiting for one.
          (when (and (stringp luau-process-init-code)
                     (not (string-empty-p luau-process-init-code)))
            (process-send-string luau-process luau-process-init-code))))
      ;; When called interactively, switch to process buffer
      (when (called-interactively-p 'any)
        (pop-to-buffer luau-process-buffer
                       '((display-buffer-pop-up-window
                          display-buffer-reuse-window)
                         (reusable-frames . t)))))))

(defun luau-get-create-process ()
  "Return active Lua process creating one if necessary."
  (luau-start-process)
  luau-process)

(defun luau-kill-process ()
  "Kill Lua process and its buffer."
  (interactive)
  (when (buffer-live-p luau-process-buffer)
    (kill-buffer luau-process-buffer)
    (setq luau-process-buffer nil)))

(defun luau-set-luau-region-start (&optional arg)
  "Set start of region for `luau-send-luau-region' to point or ARG."
  (interactive)
  (set-marker luau-region-start (or arg (point))))

(defun luau-set-luau-region-end (&optional arg)
  "Set end of region for `luau-send-luau-region' to point or ARG."
  (interactive)
  (set-marker luau-region-end (or arg (point))))

(defun luau-send-string (str)
  "Send STR plus a newline to the Luau process.

If `luau-process' is nil or dead, start a new process first."
  (unless (string-suffix-p "\n" str)
    (setq str (concat str "\n")))
  (process-send-string (luau-get-create-process) str))

(defun luau-send-current-line ()
  "Send current line to the Lua process, found in `luau-process'.
If `luau-process' is nil or dead, start a new process first."
  (interactive)
  (luau-send-region (line-beginning-position) (line-end-position)))

(defun luau-send-defun (pos)
  "Send the function definition around POS to the Lua process."
  (interactive "d")
  (save-excursion
    (let ((start (if (save-match-data (looking-at "^function[ \t]"))
                     ;; point already at the start of "function".  We
                     ;; need to handle this case explicitly since
                     ;; luau-beginning-of-proc will move to the beginning
                     ;; of the _previous_ function.
                     (point)
                   ;; point is not at the beginning of function, move
                   ;; there and bind start to that position
                   (luau-beginning-of-proc)
                   (point)))
          (end (progn (luau-end-of-proc) (point))))

      ;; Make sure point is in a function definition before sending to
      ;; the process
      (if (and (>= pos start) (< pos end))
          (luau-send-region start end)
        (error "Not on a function definition")))))

(defun luau-maybe-skip-shebang-line (start)
  "Skip interpreter line at beginning of buffer.

Return a position that is after Lua-recognized shebang line (1st
character in file must be #) if START is at its beginning.  Otherwise,
return START."
  (save-restriction
    (widen)
    (if (and (eq start (point-min))
             (eq (char-after start) ?#))
        (save-excursion
          (goto-char start)
          (forward-line)
          (point))
      start)))

(defun luau-send-region (start end)
  "Send region between START and END to the inferior Lua process."
  (interactive "r")
  (setq start (luau-maybe-skip-shebang-line start))
  (let* ((lineno (line-number-at-pos start))
         (luau-file (or (buffer-file-name) (buffer-name)))
         (region-str (buffer-substring-no-properties start end))
         (command
          ;; Print empty line before executing the code so that the
          ;; first line of output doesn't end up on the same line as
          ;; current prompt.
          (format "print(''); luaumode_loadstring(%s, %s, %s);\n"
                  (luau-make-luau-string region-str)
                  (luau-make-luau-string luau-file)
                  lineno)))
    ;; A vanilla Luau CLI may accept statements but not Lua loadstring.
    (luau-send-string (if luau-process-init-code command region-str))
    (when luau-always-show (luau-show-process-buffer))))

(defun luau-prompt-line ()
  "Return non-nil if the inferior Lua process prompt is available."
  (save-excursion
    (save-match-data
      (forward-line 0)
      (when (looking-at comint-prompt-regexp)
        (match-end 0)))))

(defun luau-send-luau-region ()
  "Send preset Lua region to Lua process."
  (interactive)
  (unless (and luau-region-start luau-region-end)
    (error "Region not set"))
  (luau-send-region luau-region-start luau-region-end))

(defalias 'luau-send-proc 'luau-send-defun)

(defun luau-send-buffer ()
  "Send whole buffer to Lua process."
  (interactive)
  (luau-send-region (point-min) (point-max)))

(defun luau-restart-with-whole-file ()
  "Restart Lua process and send whole file as input."
  (interactive)
  (luau-kill-process)
  (luau-send-buffer))

(defun luau-send-file (file)
  "Send contents of FILE to Lua process."
  (interactive "f")
  (with-temp-buffer
    (insert-file-contents-literally file)
    (luau-send-buffer)))

(defun luau-show-process-buffer ()
  "Make sure `luau-process-buffer' is being displayed.
Create a Lua process if one doesn't already exist."
  (interactive)
  (display-buffer (process-buffer (luau-get-create-process))))

(defun luau-hide-process-buffer ()
  "Delete all windows that display `luau-process-buffer'."
  (interactive)
  (when (buffer-live-p luau-process-buffer)
    (delete-windows-on luau-process-buffer)))

(defun luau--funcname-char-p (c)
  "Check if character C is part of a function name.
Return nil if C is nil.  See `luau-funcname-at-point'."
  (and c (string-match-p "\\`[A-Za-z_.]\\'" (string c))))

(defun luau-funcname-at-point ()
  "Get current Name { '.' Name } sequence."
  (when (or (luau--funcname-char-p (char-before))
            (luau--funcname-char-p (char-after)))
    (save-excursion
      (save-match-data
        (re-search-backward "\\`\\|[^A-Za-z_.]")
        ;; NOTE: `point' will be either at the start of the buffer or on
        ;; a non-symbol character.
        (re-search-forward "\\([A-Za-z_]+\\(?:\\.[A-Za-z_]+\\)*\\)")
        (match-string-no-properties 1)))))

(defun luau-search-documentation ()
  "Open the Luau documentation configured for this major mode."
  (interactive)
  (funcall luau-documentation-function luau-documentation-url))

(defun luau-toggle-electric-state (&optional arg)
  "Toggle the electric indentation feature.
Optional numeric ARG, if supplied, turns on electric indentation when
positive, turns it off when negative, and just toggles it when zero or
left out."
  (interactive "P")
  (let ((num_arg (prefix-numeric-value arg)))
    (setq luau-electric-flag (cond ((or (null arg)
                                       (zerop num_arg))
                                   (not luau-electric-flag))
                                  ((< num_arg 0) nil)
                                  ((> num_arg 0) t))))
  (message "%S" luau-electric-flag))

(defun luau-forward-sexp (&optional count)
  "Forward to block end.
A positive integer argument COUNT means to forward that many times."
  (interactive "p")
  (unless (or (not count) (>= count 0))
    (error "Negative offsets not supported"))
  (save-match-data
    (let ((count (or count 1))
          (block-start (mapcar 'car luau-sexp-alist)))
      (while (> count 0)
        ;; Skip whitespace
        (skip-chars-forward " \t\n")
        (if (looking-at (regexp-opt block-start 'words))
            (let ((keyword (match-string 1)))
              (luau-find-matching-token-word keyword 'forward))
          ;; If the current keyword is not a "begin" keyword, then just
          ;; perform the normal forward-sexp.
          (forward-sexp 1))
        (setq count (1- count))))))

;; Flymake integration

(defcustom luau-luacheck-program "luacheck"
  "Name of the legacy luacheck executable (opt-in, not Luau-aware)."
  :type 'string
  :version "31.1")

(defvar-local luau--flymake-process nil)

(defun luau-flymake (report-fn &rest _args)
  "Flymake backend using the luacheck program.
Takes a Flymake callback REPORT-FN as argument, as expected of a
member of `flymake-diagnostic-functions'."
  (when (process-live-p luau--flymake-process)
    (kill-process luau--flymake-process))
  (let ((source (current-buffer)))
    (save-restriction
      (widen)
      (setq luau--flymake-process
            (make-process
             :name "luacheck" :noquery t :connection-type 'pipe
             :buffer (generate-new-buffer " *flymake-luacheck*")
             :command `(,luau-luacheck-program
                        "--codes" "--ranges" "--formatter" "plain" "-")
             :sentinel
             (lambda (proc _event)
               (when (eq 'exit (process-status proc))
                 (unwind-protect
                     (if (with-current-buffer source
                           (eq proc luau--flymake-process))
                         (with-current-buffer (process-buffer proc)
                           (goto-char (point-min))
                           (cl-loop
                            while (search-forward-regexp
                                   "^\\([^:]*\\):\\([0-9]+\\):\\([0-9]+\\)-\\([0-9]+\\): \\(.*\\)$"
                                   nil t)
                            for line = (string-to-number (match-string 2))
                            for col1 = (string-to-number (match-string 3))
                            for col2 = (1+ (string-to-number (match-string 4)))
                            for msg = (match-string 5)
                            for type = (if (string-match-p "\\`(E" msg) :error :warning)
                            collect (flymake-make-diagnostic source
                                                             (cons line col1)
                                                             (cons line col2)
                                                             type
                                                             msg)
                            into diags
                            finally (funcall report-fn diags)))
                       (flymake-log :warning "Canceling obsolete check %s" proc))
                   (kill-buffer (process-buffer proc)))))))
      (process-send-region luau--flymake-process (point-min) (point-max))
      (process-send-eof luau--flymake-process))))

;; Menu bar

(easy-menu-define luau-mode-menu luau-mode-map
  "Menu bar entry for `luau-mode'."
  `("Luau"
    ["Search Documentation" luau-search-documentation]
    ["Send Buffer" luau-send-buffer]
    ["Send Proc" luau-send-proc]
    ["Send Region" luau-send-region]
    ["Send Current Line" luau-send-current-line]
    ["Set Lua-Region Start" luau-set-luau-region-start]
    ["Set Lua-Region End" luau-set-luau-region-end]
    ["Send Lua-Region" luau-send-luau-region]
    ["Beginning Of Proc" luau-beginning-of-proc]
    ["End Of Proc" luau-end-of-proc]
    ["Show Process Buffer" luau-show-process-buffer]
    ["Hide Process Buffer" luau-hide-process-buffer]
    ["Kill Process" luau-kill-process]
    ["Restart With Whole File" luau-restart-with-whole-file]))


;;; Luau-specific customization

(defgroup luau-font-lock nil
  "Luau syntax highlighting, including typed Luau and Roblox APIs."
  :group 'luau
  :prefix "luau-")

(defgroup luau-tools nil
  "Luau CLI, formatting, checking, and optional language services."
  :group 'luau
  :prefix "luau-")

(defgroup luau-rojo nil
  "Rojo project integration originally developed for Bloblox."
  :group 'luau
  :prefix "luau-rojo-")

(defface luau-keyword-face '((t :inherit font-lock-keyword-face))
  "Face for control-flow keywords." :group 'luau-font-lock)
(defface luau-type-keyword-face '((t :inherit font-lock-keyword-face :weight bold))
  "Face for type and export declarations." :group 'luau-font-lock)
(defface luau-type-name-face '((t :inherit font-lock-type-face))
  "Face for named types." :group 'luau-font-lock)
(defface luau-builtin-type-face '((t :inherit font-lock-type-face :weight bold))
  "Face for builtin Luau types." :group 'luau-font-lock)
(defface luau-type-parameter-face '((t :inherit font-lock-type-face :slant italic))
  "Face for generic type parameters." :group 'luau-font-lock)
(defface luau-function-face '((t :inherit font-lock-function-name-face))
  "Face for function definitions." :group 'luau-font-lock)
(defface luau-method-face '((t :inherit font-lock-function-call-face))
  "Face for method calls." :group 'luau-font-lock)
(defface luau-property-face '((t :inherit font-lock-property-name-face))
  "Face for property access." :group 'luau-font-lock)
(defface luau-variable-face '((t :inherit font-lock-variable-name-face))
  "Face for local variables and function parameters." :group 'luau-font-lock)
(defface luau-constant-face '((t :inherit font-lock-constant-face))
  "Face for constants." :group 'luau-font-lock)
(defface luau-builtin-face '((t :inherit font-lock-builtin-face))
  "Face for Lua and Luau builtins." :group 'luau-font-lock)
(defface luau-roblox-global-face '((t :inherit font-lock-builtin-face :weight bold))
  "Face for Roblox global bindings." :group 'luau-font-lock)
(defface luau-roblox-class-face '((t :inherit font-lock-type-face))
  "Face for Roblox datatypes and constructors." :group 'luau-font-lock)
(defface luau-roblox-enum-face '((t :inherit font-lock-constant-face))
  "Face for Enum references." :group 'luau-font-lock)
(defface luau-number-face '((t :inherit font-lock-number-face))
  "Face for Luau decimal, hexadecimal and binary literals." :group 'luau-font-lock)
(defface luau-operator-face '((t :inherit font-lock-operator-face))
  "Face for Luau compound assignment and type operators." :group 'luau-font-lock)
(defface luau-directive-face '((t :inherit font-lock-preprocessor-face :weight bold))
  "Face for Luau --!strict-style directives." :group 'luau-font-lock)
(defface luau-interpolation-face '((t :inherit font-lock-variable-name-face :weight bold))
  "Face for expressions inside backtick interpolation strings." :group 'luau-font-lock)
(defface luau-attribute-face '((t :inherit font-lock-preprocessor-face))
  "Face for Luau @attributes." :group 'luau-font-lock)
(defface luau-comment-face '((t :inherit font-lock-comment-face))
  "Face used for comments in Luau buffers." :group 'luau-font-lock)
(defface luau-string-face '((t :inherit font-lock-string-face))
  "Face used for strings in Luau buffers." :group 'luau-font-lock)


;; Semantic categories use theme-aware inheritance; no hard-coded colors.
(defface luau-control-flow-face
  '((t :inherit font-lock-keyword-face))
  "Face for flow control constructs."
  :group 'luau-font-lock)

(defface luau-conditional-face
  '((t :inherit font-lock-keyword-face))
  "Face for conditional expression keywords."
  :group 'luau-font-lock)

(defface luau-loop-face
  '((t :inherit font-lock-keyword-face))
  "Face for iteration constructs."
  :group 'luau-font-lock)

(defface luau-type-operator-face
  '((t :inherit font-lock-keyword-face))
  "Face for union and intersection type operators."
  :group 'luau-font-lock)

(defface luau-type-annotation-face
  '((t :inherit font-lock-type-face))
  "Face for type annotations following colons."
  :group 'luau-font-lock)

(defface luau-type-alias-face
  '((t :inherit font-lock-type-face))
  "Face for names of exported and local type aliases."
  :group 'luau-font-lock)

(defface luau-generic-face
  '((t :inherit font-lock-type-face))
  "Face for generic type parameters and bounds."
  :group 'luau-font-lock)

(defface luau-variadic-type-face
  '((t :inherit font-lock-type-face))
  "Face for variadic type argument tokens."
  :group 'luau-font-lock)

(defface luau-optional-type-face
  '((t :inherit font-lock-type-face))
  "Face for optional type suffixes."
  :group 'luau-font-lock)

(defface luau-boolean-face
  '((t :inherit font-lock-constant-face))
  "Face for boolean literals."
  :group 'luau-font-lock)

(defface luau-nil-face
  '((t :inherit font-lock-constant-face))
  "Face for nil literal."
  :group 'luau-font-lock)

(defface luau-number-hex-face
  '((t :inherit font-lock-constant-face))
  "Face for hexadecimal numeric literals."
  :group 'luau-font-lock)

(defface luau-number-binary-face
  '((t :inherit font-lock-constant-face))
  "Face for binary numeric literals."
  :group 'luau-font-lock)

(defface luau-table-key-face
  '((t :inherit font-lock-variable-name-face))
  "Face for table literal field keys."
  :group 'luau-font-lock)

(defface luau-parameter-face
  '((t :inherit font-lock-variable-name-face))
  "Face for function argument names."
  :group 'luau-font-lock)

(defface luau-self-face
  '((t :inherit font-lock-variable-name-face))
  "Face for implicit self argument."
  :group 'luau-font-lock)

(defface luau-namespace-face
  '((t :inherit font-lock-builtin-face))
  "Face for imported namespace references."
  :group 'luau-font-lock)

(defface luau-module-path-face
  '((t :inherit font-lock-string-face))
  "Face for paths in string-based module imports."
  :group 'luau-font-lock)

(defface luau-string-escape-face
  '((t :inherit font-lock-string-face))
  "Face for string escape sequences."
  :group 'luau-font-lock)

(defface luau-interpolation-delimiter-face
  '((t :inherit font-lock-string-face))
  "Face for interpolation braces in backtick strings."
  :group 'luau-font-lock)

(defface luau-doc-tag-face
  '((t :inherit font-lock-doc-face))
  "Face for structured documentation tags."
  :group 'luau-font-lock)

(defface luau-doc-parameter-face
  '((t :inherit font-lock-variable-name-face))
  "Face for structured documentation parameter names."
  :group 'luau-font-lock)

(defface luau-comment-marker-face
  '((t :inherit font-lock-comment-face))
  "Face for comment markers."
  :group 'luau-font-lock)

(defface luau-todo-face
  '((t :inherit warning))
  "Face for TODO notices in comments."
  :group 'luau-font-lock)

(defface luau-fixme-face
  '((t :inherit error))
  "Face for FIXME notices in comments."
  :group 'luau-font-lock)

(defface luau-note-face
  '((t :inherit success))
  "Face for NOTE notices in comments."
  :group 'luau-font-lock)

(defface luau-error-face
  '((t :inherit error))
  "Face for error states in Luau-related tools."
  :group 'luau-font-lock)

(defface luau-warning-face
  '((t :inherit warning))
  "Face for warning states in Luau-related tools."
  :group 'luau-font-lock)

(defface luau-success-face
  '((t :inherit success))
  "Face for successful states in Luau-related tools."
  :group 'luau-font-lock)

(defface luau-deprecated-face
  '((t :inherit shadow))
  "Face for deprecated API references."
  :group 'luau-font-lock)

(defface luau-rojo-service-face
  '((t :inherit font-lock-builtin-face))
  "Face for rojo and Roblox services."
  :group 'luau-font-lock)

(defface luau-rojo-instance-face
  '((t :inherit font-lock-type-face))
  "Face for roblox instance constructors."
  :group 'luau-font-lock)

(defface luau-rojo-event-face
  '((t :inherit font-lock-function-name-face))
  "Face for roblox event members."
  :group 'luau-font-lock)

(defface luau-directive-strict-face
  '((t :inherit font-lock-preprocessor-face))
  "Face for strict type-checker directive."
  :group 'luau-font-lock)

(defface luau-directive-nonstrict-face
  '((t :inherit font-lock-preprocessor-face))
  "Face for nonstrict type-checker directive."
  :group 'luau-font-lock)

(defface luau-directive-nocheck-face
  '((t :inherit warning))
  "Face for disabling type-checker directive."
  :group 'luau-font-lock)

(defface luau-punctuation-face
  '((t :inherit font-lock-keyword-face))
  "Face for syntactic punctuation."
  :group 'luau-font-lock)

(defface luau-assignment-face
  '((t :inherit font-lock-keyword-face))
  "Face for assignment operators."
  :group 'luau-font-lock)

(defface luau-function-argument-face
  '((t :inherit font-lock-variable-name-face))
  "Face for arguments passed to a function."
  :group 'luau-font-lock)

(defface luau-type-cast-face
  '((t :inherit font-lock-type-face))
  "Face for explicit type cast operators."
  :group 'luau-font-lock)

(defface luau-string-template-face
  '((t :inherit font-lock-string-face))
  "Face for template literals delimited by backticks."
  :group 'luau-font-lock)

(defcustom luau-use-tabs t
  "Whether to indent Luau files using tabs."
  :type 'boolean :safe #'booleanp :group 'luau)

(defcustom luau-tab-width 4
  "Displayed width of a tab in Luau buffers."
  :type 'natnum :safe #'natnump :group 'luau)

(defcustom luau-associate-lua-files nil
  "Whether loading this package makes `.lua' files use `luau-mode'.
This is suitable for Roblox repositories; set nil before loading if you
want another editor mode for ordinary Lua files."
  :type 'boolean :group 'luau)

(defcustom luau-font-lock-roblox-globals t
  "Whether to highlight Roblox engine globals."
  :type 'boolean :group 'luau-font-lock)

(defcustom luau-font-lock-roblox-types t
  "Whether to highlight Roblox engine datatypes and constructors."
  :type 'boolean :group 'luau-font-lock)

(defcustom luau-font-lock-interpolations t
  "Whether to highlight simple expressions inside backtick strings."
  :type 'boolean :group 'luau-font-lock)

(defcustom luau-font-lock-directives t
  "Whether to highlight --!strict, --!nonstrict and --!nocheck."
  :type 'boolean :group 'luau-font-lock)


;; Each semantic category is independently configurable.
(defcustom luau-font-lock-extended t
  "Enable additional highlighting for typed expressions, literals, and comments."
  :type 'boolean :group 'luau-font-lock)

(defcustom luau-font-lock-comment-markers t
  "Highlight TODO, FIXME and NOTE markers in comments."
  :type 'boolean :group 'luau-font-lock)

(defcustom luau-font-lock-keyword-roles t
  "Use distinct faces for control flow and conditional keywords."
  :type 'boolean :group 'luau-font-lock)

(defcustom luau-font-lock-string-imports t
  "Highlight string paths passed to require."
  :type 'boolean :group 'luau-font-lock)

(defcustom luau-font-lock-numeric-radixes t
  "Differentiate hexadecimal and binary integer literals."
  :type 'boolean :group 'luau-font-lock)

(defcustom luau-font-lock-function-parameters t
  "Highlight function parameters separately where supported."
  :type 'boolean :group 'luau-font-lock)

(defcustom luau-font-lock-table-keys t
  "Highlight static record keys in table literals."
  :type 'boolean :group 'luau-font-lock)

(defcustom luau-font-lock-optional-types t
  "Emphasize optional type suffixes."
  :type 'boolean :group 'luau-font-lock)

(defcustom luau-font-lock-boolean-literals t
  "Highlight boolean and nil literals with distinct faces."
  :type 'boolean :group 'luau-font-lock)

(defcustom luau-font-lock-self t
  "Distinguish the implicit self argument."
  :type 'boolean :group 'luau-font-lock)

(defcustom luau-font-lock-roblox-services t
  "Highlight Roblox GetService calls."
  :type 'boolean :group 'luau-font-lock)

(defcustom luau-font-lock-module-paths t
  "Highlight require paths in string literals."
  :type 'boolean :group 'luau-font-lock)

(defcustom luau-font-lock-doc-tags t
  "Highlight documentation tags in comments."
  :type 'boolean :group 'luau-font-lock)

(defcustom luau-font-lock-type-operators t
  "Highlight the union and intersection type operators."
  :type 'boolean :group 'luau-font-lock)

(defcustom luau-font-lock-directive-severity t
  "Give each Luau strictness directive a separate face."
  :type 'boolean :group 'luau-font-lock)

(defcustom luau-font-lock-annotations t
  "Highlight basic colon-prefixed builtin type annotations."
  :type 'boolean :group 'luau-font-lock)

(defcustom luau-font-lock-typed-functions t
  "Highlight return type names in function signatures."
  :type 'boolean :group 'luau-font-lock)

(defcustom luau-font-lock-export-types t
  "Highlight exported type declarations."
  :type 'boolean :group 'luau-font-lock)

(defcustom luau-font-lock-rojo-events t
  "Highlight common Roblox event identifiers."
  :type 'boolean :group 'luau-font-lock)

(defcustom luau-font-lock-no-custom-colors t
  "Inherit colors from standard font-lock, warning and error faces."
  :type 'boolean :group 'luau-font-lock)

(defcustom luau-roblox-globals
  '("game" "workspace" "script" "plugin" "shared" "_G" "Enum" "Instance"
    "task" "UserSettings" "settings" "tick" "time" "elapsedTime" "warn"
    "print" "typeof")
  "Roblox-specific global names highlighted when requested."
  :type '(repeat string) :group 'luau-font-lock)

(defcustom luau-roblox-types
  '("Vector2" "Vector3" "CFrame" "Color3" "ColorSequence" "NumberSequence"
    "UDim" "UDim2" "Rect" "Ray" "Region3" "PhysicalProperties" "BrickColor"
    "TweenInfo" "Random" "DateTime" "Axes" "Faces" "RaycastParams"
    "OverlapParams" "Font" "CatalogSearchParams" "EnumItem")
  "Roblox datatype and constructor names to highlight."
  :type '(repeat string) :group 'luau-font-lock)

(defcustom luau-builtin-types
  '("any" "unknown" "never" "nil" "boolean" "number" "string" "thread"
    "buffer" "vector")
  "Builtin type names used for type annotation highlighting."
  :type '(repeat string) :group 'luau-font-lock)



(defcustom luau-formatter-command '("stylua")
  "Formatter executable and initial arguments for Luau code."
  :type '(repeat string) :group 'luau-tools)

(defcustom luau-format-on-save nil
  "Whether to run `luau-format-buffer' before saving."
  :type 'boolean :group 'luau-tools)

(defcustom luau-analyzer-command '("luau-analyze")
  "Analyzer executable and initial arguments for saved Luau files."
  :type '(repeat string) :group 'luau-tools)

(defcustom luau-rojo-project-file "default.project.json"
  "File that identifies a Rojo project root."
  :type 'string :group 'luau-rojo)

(defcustom luau-rojo-enable-project-discovery t
  "Whether Luau advertises Rojo roots to Emacs project.el."
  :type 'boolean :group 'luau-rojo)

(defcustom luau-rojo-serve-command '("make" "serve")
  "Command and arguments to start Rojo from the project root."
  :type '(repeat string) :group 'luau-rojo)

(defcustom luau-rojo-camera-command '("make" "inspect-camera")
  "Command and arguments to inspect the saved camera."
  :type '(repeat string) :group 'luau-rojo)

(defcustom luau-rojo-types-file "build/roblox-global-types.d.luau"
  "Relative path of generated Roblox API definitions in a source checkout."
  :type 'string :group 'luau-rojo)

(defcustom luau-rojo-automatic-lsp t
  "Whether to start the selected Luau LSP client in Rojo buffers."
  :type 'boolean :group 'luau-rojo)

(defcustom luau-rojo-sourcemap-enabled t
  "Whether Eglot should use Rojo sourcemaps."
  :type 'boolean :group 'luau-rojo)

(defcustom luau-rojo-sourcemap-include-non-scripts t
  "Whether to include non-script instances in Rojo sourcemaps."
  :type 'boolean :group 'luau-rojo)

(defcustom luau-rojo-disable-remote-fflags t
  "Whether to disable automatic Roblox FFlag syncing in Rojo projects."
  :type 'boolean :group 'luau-rojo)

(defcustom luau-rojo-disable-api-auto-update t
  "Whether to disable Roblox type and docs auto-update in Rojo projects."
  :type 'boolean :group 'luau-rojo)

(defcustom luau-rojo-mode-line " Rojo"
  "Mode-line indicator for a Rojo project."
  :type 'string :group 'luau-rojo)

(defcustom luau-rojo-project-variables-key (kbd "C-c C-v")
  "Optional additional key for workspace variable navigation."
  :type 'key-sequence :group 'luau-rojo)

(defvar luau--rojo-processes (make-hash-table :test #'equal)
  "Map canonical Rojo project roots to live serve processes.")

(defun luau--syntactic-face (state)
  "Return a customized syntactic face for parse STATE."
  (cond ((nth 3 state) 'luau-string-face)
        ((nth 4 state) 'luau-comment-face)))

(defun luau--font-lock-syntax-state (position)
  "Return syntax state at POSITION without disturbing font-lock scanning.
Both the point and regexp match data are caller-owned invariants."
  (save-excursion
    (save-match-data (syntax-ppss position))))

(defun luau--font-lock-interpolation (limit)
  "Search for a backtick interpolation before LIMIT.
An expression is recognized only when its opening brace lies in a
backtick-delimited string.  Nested expressions are left to luau-lsp."
  (let (found)
    (while (and (not found)
                (re-search-forward "{[^{}\n]+}" limit t))
      (let* ((state (luau--font-lock-syntax-state (match-beginning 0)))
             (start (nth 8 state)))
        (when (and (nth 3 state) start (eq (char-after start) ?`))
          (setq found t))))
    found))

(defun luau--font-lock-optional-interpolation (limit)
  "Find a backtick interpolation before LIMIT when enabled."
  (and luau-font-lock-interpolations
       (luau--font-lock-interpolation limit)))

(defun luau--font-lock-directive (limit)
  "Find a strictness directive before LIMIT when enabled."
  (and luau-font-lock-directives
       (re-search-forward "^\\s-*\\(--![[:alpha:]-]+\\)" limit t)))

(defun luau--font-lock-roblox-global (limit)
  "Find a configured Roblox global before LIMIT, excluding fields."
  (when luau-font-lock-roblox-globals
    (let ((regexp (concat "\\_<" (regexp-opt luau-roblox-globals t) "\\_>"))
          found)
      (while (and (not found) (re-search-forward regexp limit t))
        (let ((pos (match-beginning 0)))
          (unless (or (nth 8 (luau--font-lock-syntax-state pos))
                      (memq (char-before pos) '(?. ?:)))
            (setq found t))))
      found)))

(defun luau--font-lock-roblox-type (limit)
  "Find an engine datatype before LIMIT, excluding comments and strings."
  (when luau-font-lock-roblox-types
    (let ((regexp (concat "\\_<" (regexp-opt luau-roblox-types t) "\\_>"))
          found)
      (while (and (not found) (re-search-forward regexp limit t))
        (unless (nth 8 (luau--font-lock-syntax-state (match-beginning 0)))
          (setq found t)))
      found)))

(defun luau--font-lock-builtin-type (limit)
  "Find a builtin type annotation before LIMIT.
The matching type name is captured in group 1."
  (when luau-builtin-types
    (let* ((pattern (concat "[:|&][ \t]*\\_<\\("
                            (regexp-opt luau-builtin-types)
                            "\\)\\_>"))
           found)
      (while (and (not found) (re-search-forward pattern limit t))
        (unless (nth 8 (luau--font-lock-syntax-state (match-beginning 1)))
          (setq found t)))
      found)))

(defconst luau--number-regexp
  "\\_<\\(?:0[xX][[:xdigit:]_]+\\|0[bB][01_]+\\|[0-9][0-9_]*\\(?:\\.[0-9_]+\\)?\\(?:[eE][+-]?[0-9_]+\\)?\\)\\_>"
  "Decimal, hexadecimal and binary Luau number literals.")

(defvar luau--extra-font-lock-keywords
  `(("\\_<\\(export\\)[ \t]+\\(type\\)\\_>" (1 'luau-type-keyword-face t) (2 'luau-type-keyword-face t))
    ("\\_<\\(type\\)[ \t]+\\([[:alpha:]_][[:alnum:]_]*\\)" (1 'luau-type-keyword-face t) (2 'luau-type-name-face t))
    ("\\_<\\(type\\)[ \t]+\\(function\\)[ \t]+\\([[:alpha:]_][[:alnum:]_]*\\)"
     (1 'luau-type-keyword-face t) (2 'luau-type-keyword-face t) (3 'luau-function-face t))
    ("\\_<\\(const\\)[ \t]+\\([[:alpha:]_][[:alnum:]_]*\\)" (1 'luau-type-keyword-face t) (2 'luau-variable-face t))
    ("\\_<\\(typeof\\)[ \t]*(" (1 'luau-builtin-face t))
    ("\\_<\\(continue\\)\\_>[ \t]*\\(?:;\\|--.*\\)?$" (1 'luau-keyword-face t))
    ("\\_<\\(function\\)[ \t]+\\([[:alpha:]_][[:alnum:]_.:]*\\)[ \t]*<" (2 'luau-function-face t))
    ("\\_<\\(type\\)[ \t]+[[:alpha:]_][[:alnum:]_]*[ \t]*<\\([^>\n]+\\)>"
     (1 'luau-type-parameter-face t))
    (luau--font-lock-builtin-type (1 'luau-builtin-type-face t))
    ("\\_<\\(Enum\\)\\.\\([[:alpha:]_][[:alnum:]_]*\\)" (1 'luau-roblox-enum-face t) (2 'luau-roblox-enum-face t))
    ("[.:][ \t]*\\([[:alpha:]_][[:alnum:]_]*\\)[ \t]*(" (1 'luau-method-face t))
    ("\\.[ \t]*\\([[:alpha:]_][[:alnum:]_]*\\)" (1 'luau-property-face t))
    ("\\(?:\\+\\|-\\|\\*\\|/\\|//\\|%\\|\\^\\|\\.\\.\\)=" . 'luau-operator-face)
    ("::\\|->" . 'luau-operator-face)
    (,luau--number-regexp . 'luau-number-face)
    (luau--font-lock-directive (1 'luau-directive-face t))
    (luau--font-lock-roblox-type (0 'luau-roblox-class-face t))
    (luau--font-lock-roblox-global (0 'luau-roblox-global-face t))
    (luau--font-lock-optional-interpolation (0 'luau-interpolation-face t)))
  "Extra font-lock matchers for typed Luau and Roblox projects.")


(defun luau--font-lock-optional-keywords (limit regexp option)
  "Match REGEXP until LIMIT when OPTION is enabled.
Only source code outside comments and strings is eligible."
  (when (and luau-font-lock-extended (symbol-value option))
    (let (found)
      (while (and (not found) (re-search-forward regexp limit t))
        (unless (nth 8 (luau--font-lock-syntax-state (match-beginning 0)))
          (setq found t)))
      found)))

(defun luau--font-lock-optional-comment (limit regexp option)
  "Match REGEXP in comments before LIMIT if OPTION permits it."
  (when (and luau-font-lock-extended (symbol-value option))
    (let (found)
      (while (and (not found) (re-search-forward regexp limit t))
        (when (nth 4 (luau--font-lock-syntax-state (match-beginning 0)))
          (setq found t)))
      found)))

(defun luau--font-lock-optional-string (limit regexp option)
  "Match REGEXP inside strings before LIMIT if OPTION permits it."
  (when (and luau-font-lock-extended (symbol-value option))
    (let (found)
      (while (and (not found) (re-search-forward regexp limit t))
        (when (nth 3 (luau--font-lock-syntax-state (match-beginning 0)))
          (setq found t)))
      found)))

(defvar luau--semantic-font-lock-keywords
  `((,(lambda (limit)
         (luau--font-lock-optional-keywords
          limit "\\_<\\(if\\|then\\|else\\|elseif\\)\\_>" 'luau-font-lock-keyword-roles))
     (1 'luau-conditional-face t))
    (,(lambda (limit)
         (luau--font-lock-optional-keywords
          limit "\\_<\\(for\\|while\\|repeat\\|until\\)\\_>" 'luau-font-lock-keyword-roles))
     (1 'luau-loop-face t))
    (,(lambda (limit)
         (luau--font-lock-optional-keywords
          limit "\\_<\\(return\\|break\\|continue\\)\\_>" 'luau-font-lock-keyword-roles))
     (1 'luau-control-flow-face t))
    (,(lambda (limit)
         (luau--font-lock-optional-keywords
          limit "\\_<\\(true\\|false\\)\\_>" 'luau-font-lock-boolean-literals))
     (1 'luau-boolean-face t))
    (,(lambda (limit)
         (luau--font-lock-optional-keywords
          limit "\\_<\\(nil\\)\\_>" 'luau-font-lock-boolean-literals))
     (1 'luau-nil-face t))
    (,(lambda (limit)
         (luau--font-lock-optional-keywords
          limit "\\_<\\(0[xX][[:xdigit:]_]+\\)\\_>" 'luau-font-lock-numeric-radixes))
     (1 'luau-number-hex-face t))
    (,(lambda (limit)
         (luau--font-lock-optional-keywords
          limit "\\_<\\(0[bB][01_]+\\)\\_>" 'luau-font-lock-numeric-radixes))
     (1 'luau-number-binary-face t))
    (,(lambda (limit)
         (luau--font-lock-optional-keywords
          limit "\\_<\\(self\\)\\_>" 'luau-font-lock-self))
     (1 'luau-self-face t))
    (,(lambda (limit)
         (luau--font-lock-optional-keywords
          limit "\\_<\\(GetService\\)\\_>" 'luau-font-lock-roblox-services))
     (1 'luau-rojo-service-face t))
    (,(lambda (limit)
         (luau--font-lock-optional-keywords
          limit "\\_<\\(Connect\\|Wait\\|Once\\|FireServer\\|OnServerEvent\\)\\_>"
          'luau-font-lock-rojo-events))
     (1 'luau-rojo-event-face t))
    (,(lambda (limit)
         (luau--font-lock-optional-keywords
          limit "[{,][ \t]*\\([[:alpha:]_][[:alnum:]_]*\\)[ \t]*=" 'luau-font-lock-table-keys))
     (1 'luau-table-key-face t))
    (,(lambda (limit)
         (luau--font-lock-optional-keywords
          limit "\\(::\\)" 'luau-font-lock-type-operators))
     (1 'luau-type-cast-face t))
    (,(lambda (limit)
         (luau--font-lock-optional-comment
          limit "\\_<\\(TODO\\|HACK\\)\\_>" 'luau-font-lock-comment-markers))
     (1 'luau-todo-face t))
    (,(lambda (limit)
         (luau--font-lock-optional-comment
          limit "\\_<\\(FIXME\\|BUG\\)\\_>" 'luau-font-lock-comment-markers))
     (1 'luau-fixme-face t))
    (,(lambda (limit)
         (luau--font-lock-optional-comment
          limit "\\_<\\(NOTE\\|INFO\\)\\_>" 'luau-font-lock-comment-markers))
     (1 'luau-note-face t))
    (,(lambda (limit)
         (luau--font-lock-optional-comment
          limit "\\(@param\\|@return\\|@see\\|@class\\|@field\\)\\_>" 'luau-font-lock-doc-tags))
     (1 'luau-doc-tag-face t))
    (,(lambda (limit)
         (luau--font-lock-optional-string
          limit "\\(\\.\\./[[:alnum:]_./-]+\\)" 'luau-font-lock-module-paths))
     (1 'luau-module-path-face t)))
  "Optional semantic font-lock rules with theme-inherited custom faces.")

(setq luau-font-lock-keywords
      (append luau-font-lock-keywords luau--extra-font-lock-keywords
              luau--semantic-font-lock-keywords))

(setq luau-imenu-generic-expression
      (append luau-imenu-generic-expression
              '(("Types" "^[ \t]*\\(?:export[ \t]+\\)?type[ \t]+\\([[:alpha:]_][[:alnum:]_]*\\)" 1)
                ("Functions" "^[ \t]*\\(?:local[ \t]+\\|const[ \t]+\\)?function[ \t]+\\([[:alpha:]_][[:alnum:]_.:]*\\)" 1))))

(defun luau--project-root (&optional directory noerror)
  "Find the enclosing Rojo project for DIRECTORY.
Return nil if NOERROR is non-nil and no project was found."
  (let ((root (locate-dominating-file
               (or directory default-directory) luau-rojo-project-file)))
    (or root (unless noerror
               (user-error "Not inside a Rojo project (%s)" luau-rojo-project-file)))))

(defun luau-project-try-rojo (directory)
  "Return a project.el transient project for Rojo above DIRECTORY."
  (when (and luau-rojo-enable-project-discovery directory)
    (when-let* ((root (luau--project-root directory t)))
      (cons 'transient root))))

(add-hook 'project-find-functions #'luau-project-try-rojo)

(defvar luau-rojo-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-h v") #'luau-project-variables)
    (define-key map luau-rojo-project-variables-key #'luau-project-variables)
    (define-key map (kbd "C-c C-i") #'luau-inspect-camera)
    (define-key map (kbd "C-c C-z") #'luau-rojo-serve)
    (define-key map (kbd "C-c C-x") #'luau-rojo-stop)
    map)
  "Key bindings when a buffer belongs to a Rojo project.")

(define-minor-mode luau-rojo-mode
  "Provide Bloblox-inspired Rojo commands in a Luau buffer."
  :init-value nil
  :lighter luau-rojo-mode-line
  :keymap luau-rojo-mode-map)

(defun luau--find-api-types (root)
  "Find pinned generated API type definitions from source checkout ROOT."
  (when-let* ((checkout (locate-dominating-file root luau-rojo-types-file))
              (file (expand-file-name luau-rojo-types-file checkout)))
    (when (file-readable-p file) file)))

(defun luau-setup-language-server ()
  "Start the configured optional Luau language-server client."
  (interactive)
  (require 'luau-lsp)
  (luau-lsp-ensure))

(defun luau--maybe-setup-rojo ()
  "Enable Rojo extensions when inside a Rojo source checkout."
  (when (luau--project-root nil t)
    (luau-rojo-mode 1)))

(defun luau--lsp-position (path line character)
  "Visit PATH at zero-based LINE and UTF-16 CHARACTER offset."
  (find-file path)
  (goto-char (point-min))
  (unless (= 0 (forward-line line))
    (user-error "Workspace symbol line is outside the source file"))
  (let ((units 0)
        (end (line-end-position)))
    (while (and (< units character) (< (point) end))
      (let* ((codepoint (char-after))
             (width (if (> codepoint #xffff) 2 1)))
        (when (> (+ units width) character)
          (user-error "Workspace symbol offset splits a UTF-16 surrogate pair"))
        (setq units (+ units width))
        (forward-char 1)))
    (unless (= units character)
      (user-error "Workspace symbol column is beyond source line"))))

(defun luau--file-uri-path (uri)
  "Decode a local file URI URI into a path, or nil for other schemes."
  (when (and (stringp uri) (string-prefix-p "file://" uri))
    (let* ((rest (substring uri (length "file://")))
           (rest (if (string-prefix-p "localhost/" rest)
                     (substring rest (length "localhost"))
                   rest)))
      (when (string-prefix-p "/" rest)
        (url-unhex-string rest)))))

(defun luau--eglot-project-variables ()
  "Browse Luau workspace variables using Eglot's public JSON-RPC interface.
Only source symbols are returned, never live Roblox runtime values."
  (unless (and (fboundp 'eglot-managed-p) (eglot-managed-p))
    (user-error "Eglot is not managing this Luau buffer"))
  (require 'jsonrpc)
  (let ((symbols (jsonrpc-request (eglot-current-server)
                                  :workspace/symbol '(:query ""))))
    (luau-lsp--select-workspace-variable symbols)))

(defun luau-project-variables ()
  "Browse source-level variable symbols using the active LSP client."
  (interactive)
  (require 'luau-lsp)
  (if (bound-and-true-p lsp-mode)
      (luau-lsp-workspace-variables)
    (luau--eglot-project-variables)))

(defun luau--command-string (command)
  "Quote each element of COMMAND for `compilation-start'."
  (unless (and (consp command) (seq-every-p #'stringp command))
    (user-error "Expected a nonempty list of program and arguments"))
  (mapconcat #'shell-quote-argument command " "))

(defun luau-inspect-camera ()
  "Inspect saved Workspace.Camera properties using project command."
  (interactive)
  (let ((default-directory (luau--project-root)))
    (compilation-start (luau--command-string luau-rojo-camera-command)
                       'compilation-mode
                       (lambda (_command) "*Luau Camera*"))))

(defun luau--canonical-root ()
  "Return canonical Rojo root for process ownership."
  (directory-file-name (file-truename (luau--project-root))))

(defun luau-rojo-serve ()
  "Start Rojo serve for the current project, or show its existing log.
Each root has an independent serve process and log buffer."
  (interactive)
  (let* ((root (luau--canonical-root))
         (existing (gethash root luau--rojo-processes)))
    (if (process-live-p existing)
        (display-buffer (process-buffer existing))
      (let* ((default-directory root)
             (log (get-buffer-create
                   (format "*Luau Rojo: %s*" (directory-file-name root))))
             (command luau-rojo-serve-command))
        (unless (and (consp command) (seq-every-p #'stringp command))
          (user-error "Invalid `luau-rojo-serve-command'"))
        (with-current-buffer log
          (let ((inhibit-read-only t))
            (erase-buffer))
          (setq-local default-directory root))
        (let ((proc (make-process
                     :name "luau-rojo-serve" :buffer log
                     :command command :noquery t
                     :sentinel (lambda (process event)
                                 (unless (process-live-p process)
                                   (when (eq process (gethash root luau--rojo-processes))
                                     (remhash root luau--rojo-processes))
                                   (when (buffer-live-p (process-buffer process))
                                     (with-current-buffer (process-buffer process)
                                       (goto-char (point-max))
                                       (insert (format "\n[Rojo] %s" event)))))))))
          (puthash root proc luau--rojo-processes)
          (display-buffer log))))))

(defun luau-rojo-stop ()
  "Stop the Rojo serve process belonging to the current project."
  (interactive)
  (let* ((root (luau--canonical-root))
         (proc (gethash root luau--rojo-processes)))
    (unless (process-live-p proc)
      (user-error "Rojo serve is not running in this project"))
    (delete-process proc)
    (remhash root luau--rojo-processes)
    (message "Stopped Rojo for %s" root)))

(defun luau-format-buffer ()
  "Format the current Luau buffer using an external StyLua executable.
The original buffer remains untouched if the formatter fails."
  (interactive)
  (unless (and luau-formatter-command
               (executable-find (car luau-formatter-command)))
    (user-error "Formatter not found: %s" (car luau-formatter-command)))
  (let ((origin (current-buffer))
        (filename (or (buffer-file-name) "stdin.luau"))
        (args (cdr luau-formatter-command)))
    (with-temp-buffer
      (insert-buffer-substring origin)
      (let ((err-file (make-temp-file "luau-format-error")))
        (unwind-protect
            (let ((status (apply #'call-process-region
                                 (point-min) (point-max)
                                 (car luau-formatter-command) t
                                 (list t err-file) nil
                                 (append args (list "--stdin-filepath" filename "-")))))
              (unless (eq status 0)
                (user-error "StyLua failed: %s"
                            (string-trim
                             (with-temp-buffer
                               (insert-file-contents err-file)
                               (buffer-string)))))
              (let ((formatted-buffer (current-buffer)))
                (with-current-buffer origin
                  (if (version< emacs-version "31.1")
                      (with-no-warnings
                        (replace-buffer-contents formatted-buffer))
                    (replace-region-contents
                     (point-min) (point-max) formatted-buffer)))))
          (delete-file err-file))))))

(defun luau--format-on-save ()
  "Run the formatter before saving when configured."
  (when luau-format-on-save
    (luau-format-buffer)))

(defun luau-analyze-file ()
  "Analyze the current saved Luau file using a configured CLI."
  (interactive)
  (unless (buffer-file-name)
    (user-error "Save this buffer to a file before analysis"))
  (unless (and luau-analyzer-command
               (executable-find (car luau-analyzer-command)))
    (user-error "Analyzer not found: %s" (car luau-analyzer-command)))
  (save-buffer)
  (let ((default-directory (or (luau--project-root nil t) default-directory)))
    (compilation-start
     (luau--command-string (append luau-analyzer-command
                                   (list (buffer-file-name))))
     'compilation-mode
     (lambda (_command) "*Luau Analyze*"))))

(defun luau-refontify-buffer ()
  "Apply the latest Luau faces and font-lock options to this buffer."
  (interactive)
  (unless (derived-mode-p 'luau-mode)
    (user-error "Not a Luau buffer"))
  (font-lock-flush)
  (font-lock-ensure)
  (when (called-interactively-p 'interactive)
    (message "Luau font-lock refreshed")))

(defun luau--configure-mode ()
  "Install Luau-specific syntax, project, and editor integration."
  (setq-local tab-width luau-tab-width
              indent-tabs-mode luau-use-tabs
              font-lock-syntactic-face-function #'luau--syntactic-face)
  (when (not font-lock-mode)
    (font-lock-mode 1))
  (add-hook 'before-save-hook #'luau--format-on-save nil t)
  (luau--maybe-setup-rojo)
  ;; Register before any user-supplied `luau-mode-hook' invokes `lsp'.
  ;; `lsp-mode' is optional; the editor works without its installation.
  (when (locate-library "lsp-mode")
    (luau-lsp--register-lsp-mode))
  (luau-lsp-auto-ensure))

(autoload 'luau-make-check "luau-make"
  "Run the Luau package quality matrix in a colorized compilation buffer." t)
(define-key luau-mode-map (kbd "C-c C-t") #'luau-make-check)

(add-hook 'luau-mode-hook #'luau--configure-mode)

;; The original Bloblox commands have native luau-prefixed entry points.
;; Older nonstandard bloblox/ aliases are deliberately not exported from the
;; distributable MELPA package; use the luau-* commands listed in README.md.

(define-key luau-mode-map (kbd "C-c C-f") #'luau-format-buffer)
(define-key luau-mode-map (kbd "C-c C-a") #'luau-analyze-file)
(define-key luau-mode-map (kbd "C-c C-k") #'luau-lsp-show-doc)
(define-key luau-mode-map (kbd "C-c C-s") #'luau-setup-language-server)
(define-key luau-mode-map (kbd "C-c C-d") #'luau-browser-at-point)
(define-key luau-mode-map (kbd "C-c C-u") #'luau-roblox-api-status)
(define-key luau-mode-map (kbd "C-c C-r") #'luau-refontify-buffer)
(define-key luau-mode-map (kbd "C-c C-j") #'luau-imenu)
(define-key luau-mode-map (kbd "M-n") #'luau-interface-goto-matching-end)
(define-key luau-mode-map (kbd "M-p") #'luau-interface-goto-matching-beginning)
;; Prefer native local documentation, falling back to `eww' on demand.
(define-key luau-mode-map (kbd "C-c C-o") #'luau-browser-at-point)
(define-key luau-mode-map (kbd "C-c C-b") luau-browser-command-map)
(define-key luau-mode-map (kbd "C-h v") #'luau-project-variables)

(when luau-associate-lua-files
  (add-to-list 'auto-mode-alist '("\\.lua\\'" . luau-mode)))

(provide 'luau-mode)

;;; luau-mode.el ends here
