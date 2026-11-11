;;; luau-interface.el --- Structural editor UI for Luau -*- lexical-binding: t; -*-

;; Copyright (C) 2026 laluxx
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: laluxx
;; Keywords: languages, tools
;; URL: https://luau.org

;;; Commentary:

;; Cached source indexing, aligned and colorized Imenu annotations, Eldoc
;; call signatures, and matching control-flow keyword overlays.  Inspired by
;; the independently authored Monad Mode UI; no Monad dependency is required.
;; This module does not start LSP clients, fetch data, or change global hooks.

;;; Code:

(require 'cl-lib)
(require 'imenu)
(require 'eldoc)
(require 'subr-x)

(defgroup luau-interface nil
  "Structural navigation and local editor presentation for Luau."
  :group 'luau
  :prefix "luau-interface-")

(defcustom luau-interface-enable-imenu t
  "Whether to enable the cached Luau Imenu index."
  :type 'boolean :group 'luau-interface)

(defcustom luau-interface-imenu-show-signatures t
  "Whether Imenu displays type and parameter annotations."
  :type 'boolean :group 'luau-interface)

(defcustom luau-interface-imenu-show-docs t
  "Whether Imenu displays leading documentation comment previews."
  :type 'boolean :group 'luau-interface)

(defcustom luau-interface-imenu-signature-max-length 110
  "Maximum number of characters shown for an Imenu signature."
  :type 'natnum :group 'luau-interface)

(defcustom luau-interface-imenu-doc-max-length 72
  "Maximum number of characters shown for an Imenu documentation preview."
  :type 'natnum :group 'luau-interface)

(defcustom luau-interface-enable-eldoc t
  "Whether to show local function signatures in the echo area."
  :type 'boolean :group 'luau-interface)

(defcustom luau-interface-eldoc-highlight-argument t
  "Whether to emphasize the current argument in the Eldoc signature."
  :type 'boolean :group 'luau-interface)

(defcustom luau-interface-eldoc-max-call-size 4000
  "Maximum characters scanned backward for a call signature."
  :type 'natnum :group 'luau-interface)

(defcustom luau-interface-highlight-matching-keywords t
  "Highlight matching Luau block keywords near point."
  :type 'boolean :group 'luau-interface)

(defcustom luau-interface-match-max-buffer-size 250000
  "Maximum size of a buffer scanned for control-flow keyword pairs.
The scanner only runs when point is on a relevant keyword.  Oversized
buffers continue to support regular editing without matching overlays."
  :type 'natnum :group 'luau-interface)

(defface luau-interface-imenu-function-face
  '((t :inherit font-lock-function-name-face))
  "Face for function names in Luau Imenu." :group 'luau-interface)
(defface luau-interface-imenu-type-face
  '((t :inherit font-lock-type-face))
  "Face for named types in Luau Imenu." :group 'luau-interface)
(defface luau-interface-imenu-require-face
  '((t :inherit font-lock-builtin-face))
  "Face for require bindings in Luau Imenu." :group 'luau-interface)
(defface luau-interface-imenu-signature-face
  '((t :inherit font-lock-type-face))
  "Face for Imenu signature annotations." :group 'luau-interface)
(defface luau-interface-imenu-doc-face
  '((t :inherit font-lock-doc-face))
  "Face for Imenu docstring previews." :group 'luau-interface)
(defface luau-interface-imenu-location-face
  '((t :inherit shadow))
  "Face for location annotations in Imenu." :group 'luau-interface)
(defface luau-interface-eldoc-function-face
  '((t :inherit font-lock-function-name-face))
  "Face for the active Eldoc function name." :group 'luau-interface)
(defface luau-interface-eldoc-active-face
  '((t :inherit region))
  "Face for the current argument in a call signature." :group 'luau-interface)
(defface luau-interface-eldoc-inactive-face
  '((t :inherit shadow))
  "Face for inactive arguments in a call signature." :group 'luau-interface)
(defface luau-interface-match-face
  '((t :inherit region))
  "Face for a matching Luau opener or terminator." :group 'luau-interface)
(defface luau-interface-match-current-face
  '((t :inherit region :weight bold))
  "Face for the keyword currently under the cursor." :group 'luau-interface)
(defface luau-interface-symbol-kind-face
  '((t :inherit font-lock-keyword-face))
  "Face for symbol-kind annotations in workspace pickers." :group 'luau-interface)

(defvar-local luau-interface--index-tick nil
  "Modification tick for the last calculated Imenu index.")
(defvar-local luau-interface--index nil
  "Cached Imenu entries: (NAME MARKER KIND SIGNATURE DOC LINE).")
(defvar luau-interface--completion-buffer nil
  "Source buffer supplying annotations during minibuffer completion.")
(defvar-local luau-interface--eldoc-tick nil
  "Last buffer modification tick used for local Eldoc.")
(defvar-local luau-interface--eldoc-point nil
  "Last point queried for local Eldoc.")
(defvar-local luau-interface--eldoc-value nil
  "Cached Eldoc text for the last point and buffer contents.")
(defvar-local luau-interface--match-overlays nil
  "Current pair of local keyword highlighting overlays.")
(defvar-local luau-interface--match-tick nil
  "Modification tick of the matching-keyword cache.")
(defvar-local luau-interface--match-position nil
  "Keyword position used in the matching-keyword cache.")

(defconst luau-interface--declaration-regexp
  (concat "^[ \t]*\\(?:"
          "\\(?:local[ \t]+\\|const[ \t]+\\)?function[ \t]+\\([[:alpha:]_][[:alnum:]_.:]*\\)"
          "\\|\\(?:export[ \t]+\\)?type[ \t]+\\([[:alpha:]_][[:alnum:]_]*\\)"
          "\\|\\(?:local[ \t]+\\)?\\([[:alpha:]_][[:alnum:]_]*\\)[ \t]*=[ \t]*require[ \t]*("
          "\\)")
  "Regexp matching indexed function, type and require declarations.")

(defun luau-interface--code-p (position)
  "Return non-nil if POSITION is outside strings and comments."
  (save-excursion
    (save-match-data
      (let ((state (syntax-ppss position)))
        (not (or (nth 3 state) (nth 4 state)))))))

(defun luau-interface--truncate (value width)
  "Return VALUE truncated to WIDTH characters, never modifying VALUE."
  (when value
    (truncate-string-to-width (string-trim value) (max 0 width) nil nil t)))

(defun luau-interface--leading-doc (position)
  "Return the nearest preceding Luau doc-comment above POSITION."
  (save-excursion
    (goto-char position)
    (forward-line -1)
    (when (looking-at "^[ \t]*---+[ \t]*\\(.*\\)$")
      (luau-interface--truncate (match-string-no-properties 1)
                                luau-interface-imenu-doc-max-length))))

(defun luau-interface--index-build ()
  "Collect a source-ordered list of Luau declarations in the buffer."
  (let (entries)
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (while (re-search-forward luau-interface--declaration-regexp nil t)
          (let* ((name (or (match-string-no-properties 1)
                           (match-string-no-properties 2)
                           (match-string-no-properties 3)))
                 (kind (cond ((match-beginning 1) 'function)
                             ((match-beginning 2) 'type)
                             (t 'require)))
                 (position (match-beginning 0))
                 (start (or (match-beginning 1)
                            (match-beginning 2)
                            (match-beginning 3)))
                 (line (line-number-at-pos position))
                 (signature (when (eq kind 'function)
                              (luau-interface--truncate
                               (buffer-substring-no-properties
                                start (line-end-position))
                               luau-interface-imenu-signature-max-length)))
                 (doc (luau-interface--leading-doc position)))
            (when (and name (luau-interface--code-p position))
              (push (list name (copy-marker start) kind signature doc line)
                    entries))))))
    (nreverse entries)))

(defun luau-interface--entries ()
  "Return the cached Imenu entries, rebuilding after source modifications."
  (let ((tick (buffer-chars-modified-tick)))
    (unless (equal luau-interface--index-tick tick)
      (dolist (entry luau-interface--index)
        (set-marker (nth 1 entry) nil))
      (setq luau-interface--index (luau-interface--index-build)
            luau-interface--index-tick tick))
    luau-interface--index))

(defun luau-interface--entry-face (kind)
  "Return the Imenu face corresponding to KIND."
  (pcase kind
    ('type 'luau-interface-imenu-type-face)
    ('require 'luau-interface-imenu-require-face)
    (_ 'luau-interface-imenu-function-face)))

(defun luau-interface--imenu-candidates ()
  "Return source-ordered propertized Imenu candidates and markers."
  (mapcar (lambda (entry)
            (cons (propertize (car entry) 'face
                              (luau-interface--entry-face (nth 2 entry)))
                  (nth 1 entry)))
          (luau-interface--entries)))

(defun luau-interface-imenu-create-index ()
  "Build the flat cached Luau Imenu index for standard Emacs commands."
  (luau-interface--imenu-candidates))

(defun luau-interface-imenu-annotate (candidate)
  "Return a colored and aligned annotation for CANDIDATE.
This function also works when called by optional Marginalia in a minibuffer."
  (when (buffer-live-p luau-interface--completion-buffer)
    (with-current-buffer luau-interface--completion-buffer
      (when-let* ((entry (cl-find (substring-no-properties candidate)
                                 (luau-interface--entries)
                                 :key #'car :test #'equal)))
        (let* ((signature (and luau-interface-imenu-show-signatures (nth 3 entry)))
               (doc (and luau-interface-imenu-show-docs (nth 4 entry)))
               (kind (nth 2 entry))
               (line (nth 5 entry)))
          (concat
           (propertize (format "  %-8s" (symbol-name kind))
                       'face 'luau-interface-symbol-kind-face)
           (when signature
             (propertize (format " %-48s"
                                 (luau-interface--truncate signature 46))
                         'face 'luau-interface-imenu-signature-face))
           (when doc
             (propertize (concat "  " doc) 'face 'luau-interface-imenu-doc-face))
           (propertize (format "  :%d" line)
                       'face 'luau-interface-imenu-location-face)))))))

;;;###autoload
(defun luau-imenu ()
  "Jump to an indexed Luau declaration with colored metadata."
  (interactive)
  (let* ((luau-interface--completion-buffer (current-buffer))
         (candidates (luau-interface--imenu-candidates))
         (completion-extra-properties
          (list :annotation-function #'luau-interface-imenu-annotate)))
    (unless candidates
      (user-error "No Luau declarations in this buffer"))
    (let* ((selection (completing-read "Luau declaration: " candidates nil t))
           (target (cdr (assoc selection candidates))))
      (unless (markerp target)
        (user-error "No source position for %s" selection))
      (push-mark)
      (goto-char target)
      (when (get-buffer-window (current-buffer))
        (recenter)))))

(defun luau-interface--enclosing-call ()
  "Return (NAME ARGUMENT-INDEX) for a parenthesized call at point.
Comments and strings are ignored; nested argument expressions are supported."
  (save-excursion
    (let* ((original (point))
           (open (nth 1 (syntax-ppss original))))
      (when (and open
                 (< (- original open) luau-interface-eldoc-max-call-size))
        (goto-char open)
        (when (and (eq (char-after) ?\()
                   (> (point) (point-min)))
          (backward-char)
          (skip-syntax-backward "w_")
          (let ((name (thing-at-point 'symbol t))
                (args 0)
                (cursor (1+ open))
                (depth (1+ (car (syntax-ppss open)))))
            (when name
              (while (< cursor original)
                (when (and (eq (char-after cursor) ?,)
                           (let ((state (syntax-ppss cursor)))
                             (and (= (car state) depth)
                                  (not (nth 3 state))
                                  (not (nth 4 state)))))
                  (setq args (1+ args)))
                (setq cursor (1+ cursor)))
              (list name args))))))))

(defun luau-interface--signature-args (signature)
  "Extract the simple parameter list from SIGNATURE, or nil."
  (when (string-match "(\\([^()]*\\))" signature)
    (split-string (match-string 1 signature) "[ \t]*,[ \t]*" t)))

(defun luau-interface--local-eldoc ()
  "Return highlighted call help from a local function declaration."
  (when-let* ((call (luau-interface--enclosing-call))
              (entry (cl-find (car call) (luau-interface--entries)
                              :key #'car :test #'equal))
              (signature (nth 3 entry))
              (args (luau-interface--signature-args signature)))
    (concat (propertize (car call) 'face 'luau-interface-eldoc-function-face)
            "("
            (mapconcat
             #'identity
             (cl-loop for arg in args
                      for index from 0
                      collect (propertize
                               arg 'face
                               (if (and luau-interface-eldoc-highlight-argument
                                        (= index (cadr call)))
                                   'luau-interface-eldoc-active-face
                                 'luau-interface-eldoc-inactive-face)))
             ", ")
            ")")))

(defun luau-interface-eldoc (callback &rest _ignored)
  "Call CALLBACK with local Luau call documentation when available."
  (when luau-interface-enable-eldoc
    (let ((tick (buffer-chars-modified-tick))
          (position (point)))
      (unless (and (equal tick luau-interface--eldoc-tick)
                   (equal position luau-interface--eldoc-point))
        (setq luau-interface--eldoc-tick tick
              luau-interface--eldoc-point position
              luau-interface--eldoc-value (luau-interface--local-eldoc)))
      (when luau-interface--eldoc-value
        (funcall callback luau-interface--eldoc-value)
        t))))

(defconst luau-interface--keyword-regexp
  "\\_<\\(function\\|if\\|for\\|while\\|do\\|repeat\\|end\\|until\\|then\\|elseif\\|else\\)\\_>"
  "Regexp matching Luau block-control tokens for pairing overlays.")

(defun luau-interface--keyword-at-point ()
  "Return (START END TOKEN) when point touches a Luau block keyword."
  (save-excursion
    (when (and (> (point) (point-min))
               (not (looking-at "\\_<[[:alpha:]]")))
      (backward-char))
    (when (looking-at "[[:alpha:]]")
      (skip-syntax-backward "w")
      (when (and (looking-at luau-interface--keyword-regexp)
                 (<= (match-beginning 0) (point))
                 (<= (point) (match-end 0))
                 (luau-interface--code-p (match-beginning 0)))
        (list (match-beginning 0) (match-end 0)
              (match-string-no-properties 1))))))

(defun luau-interface--keyword-pair (target)
  "Return matching block positions for TARGET as (START END), or nil.
The scan deliberately ignores comments, strings and nested block keywords."
  (when (<= (buffer-size) luau-interface-match-max-buffer-size)
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (let ((stack nil) (branch nil) pair)
          (catch 'found
            (while (re-search-forward luau-interface--keyword-regexp nil t)
              (let ((position (match-beginning 0))
                    (word (match-string-no-properties 1)))
                (when (luau-interface--code-p position)
                  (cond
                   ((member word '("function" "if" "for" "while" "repeat"))
                    (push (cons word position) stack))
                   ((equal word "do")
                    (if (member (caar stack) '("for" "while"))
                        (when (= position target) (setq branch (car stack)))
                      (push (cons word position) stack)))
                   ((member word '("then" "else" "elseif"))
                    (when (= position target)
                      (setq branch (cl-find-if
                                    (lambda (item) (equal (car item) "if"))
                                    stack))))
                   ((member word '("end" "until"))
                    (when (and stack
                               (if (equal word "until")
                                   (equal (caar stack) "repeat")
                                 (not (equal (caar stack) "repeat"))))
                      (let ((opening (pop stack)))
                        (when (or (= (cdr opening) target)
                                  (= position target)
                                  (and branch (= (cdr opening) (cdr branch))))
                          (setq pair (list (if (and branch
                                                    (= (cdr opening) (cdr branch)))
                                               target
                                             (cdr opening))
                                           position))
                          (throw 'found pair)))))))))
            pair))))))

(defun luau-interface--clear-match ()
  "Remove matching-keyword overlays from this buffer."
  (mapc #'delete-overlay luau-interface--match-overlays)
  (setq luau-interface--match-overlays nil))

(defun luau-interface--refresh-match ()
  "Refresh matching keyword overlays when point is on a block keyword."
  (when luau-interface-highlight-matching-keywords
    (let* ((keyword (luau-interface--keyword-at-point))
           (position (car keyword))
           (tick (buffer-chars-modified-tick)))
      (unless (and (equal position luau-interface--match-position)
                   (equal tick luau-interface--match-tick))
        (luau-interface--clear-match)
        (setq luau-interface--match-position position
              luau-interface--match-tick tick)
        (when-let* ((pair (and position (luau-interface--keyword-pair position))))
          (dolist (p pair)
            (save-excursion
              (goto-char p)
              (when (looking-at luau-interface--keyword-regexp)
                (let ((overlay (make-overlay p (match-end 0) nil t nil)))
                  (overlay-put overlay 'face
                               (if (= p position)
                                   'luau-interface-match-current-face
                                 'luau-interface-match-face))
                  (overlay-put overlay 'priority 100)
                  (push overlay luau-interface--match-overlays))))))))))

(defun luau-interface--teardown ()
  "Release overlays and cached markers when changing major modes."
  (luau-interface--clear-match)
  (dolist (entry luau-interface--index)
    (set-marker (nth 1 entry) nil))
  (setq luau-interface--index nil
        luau-interface--index-tick nil))

(defun luau-interface-setup ()
  "Install optional source navigation and presentation in this Luau buffer."
  (when luau-interface-enable-imenu
    (setq-local imenu-create-index-function #'luau-interface-imenu-create-index))
  (when luau-interface-enable-eldoc
    (add-hook 'eldoc-documentation-functions #'luau-interface-eldoc nil t)
    (eldoc-mode 1))
  (when luau-interface-highlight-matching-keywords
    (add-hook 'post-command-hook #'luau-interface--refresh-match nil t))
  (add-hook 'change-major-mode-hook #'luau-interface--teardown nil t))

(provide 'luau-interface)
;;; luau-interface.el ends here

;; Local Variables:
;; package-lint-main-file: "luau-mode.el"
;; End:
