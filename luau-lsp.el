;;; luau-lsp.el --- Optional LSP clients for Luau -*- lexical-binding: t; -*-

;; Copyright (C) 2026 laluxx
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: laluxx
;; Keywords: languages, tools

;;; Commentary:

;; Register luau-lsp with lsp-mode, falling back to Eglot when appropriate.
;; Both clients are optional and never loaded to activate the base major mode.
;; This module has no dependency on the legacy lua-mode package.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'luau-roblox)
(require 'luau-interface)

(declare-function lsp-register-client "lsp-mode")
(declare-function make-lsp-client "lsp-mode")
(declare-function lsp-stdio-connection "lsp-mode")
(declare-function lsp-activate-on "lsp-mode")
(declare-function lsp-register-custom-settings "lsp-mode")
(declare-function lsp-deferred "lsp-mode")
(declare-function lsp-workspace-restart "lsp-mode")
(declare-function lsp-request "lsp-mode")
(declare-function lsp-ui-doc-show "lsp-ui-doc")
(declare-function lsp-describe-thing-at-point "lsp-mode")
(declare-function eglot-ensure "eglot")
(declare-function eglot-managed-p "eglot")
(declare-function eglot-shutdown "eglot")
(declare-function eglot-reconnect "eglot")
(declare-function eglot-current-server "eglot")
(declare-function jsonrpc-request "jsonrpc")
(defvar eglot-server-programs)
(defvar eglot-workspace-configuration)
(defvar lsp-language-id-configuration)
(defvar lsp-auto-guess-root)
(defvar lsp-enable-symbol-highlighting)
(defvar lsp-idle-delay)
(defvar lsp-headerline-breadcrumb-enable)
(defvar lsp-ui-doc-enable)
(defvar lsp-ui-doc-show-with-mouse)
(defvar luau-rojo-sourcemap-enabled)
(defvar luau-rojo-sourcemap-include-non-scripts)
(defvar luau-rojo-project-file)
(defvar luau-rojo-automatic-lsp)

(declare-function luau--project-root "luau-mode" (&optional directory noerror))
(declare-function luau--find-api-types "luau-mode" (root))
(declare-function luau--lsp-position "luau-mode" (path line character))
(declare-function luau--file-uri-path "luau-mode" (uri))

(defgroup luau-lsp nil
  "Language servers, project settings, and diagnostics for Luau."
  :group 'luau
  :prefix "luau-lsp-")

(defcustom luau-lsp-backend 'auto
  "LSP client to use for Luau.
`auto' prefers an installed lsp-mode and otherwise uses built-in Eglot.
Neither package is downloaded or installed by this mode."
  :type '(choice (const :tag "Prefer installed lsp-mode" auto)
                 (const :tag "lsp-mode" lsp-mode)
                 (const :tag "Eglot" eglot)
                 (const :tag "Disable language services" none))
  :group 'luau-lsp)

(defcustom luau-lsp-command '("luau-lsp" "lsp")
  "Server executable followed by command-line arguments.
The upstream Luau language server expects the `lsp' subcommand."
  :type '(repeat string)
  :risky t
  :group 'luau-lsp)

(defcustom luau-lsp-auto-start t
  "Automatically connect in file-backed Luau source buffers.
Rojo projects additionally respect `luau-rojo-automatic-lsp'."
  :type 'boolean
  :group 'luau-lsp)

(defcustom luau-lsp-prefer-installed-lsp-mode t
  "When using `auto', prefer lsp-mode over Eglot if it is installed."
  :type 'boolean
  :group 'luau-lsp)

(defcustom luau-lsp-multi-root t
  "Whether lsp-mode may attach one server to multiple project roots."
  :type 'boolean
  :group 'luau-lsp)

(defcustom luau-lsp-idle-delay 0.1
  "Seconds to wait before the Luau LSP sends idle notifications."
  :type 'number
  :group 'luau-lsp)

(defcustom luau-lsp-enable-symbol-highlighting nil
  "Whether lsp-mode highlights all occurrences of the symbol at point."
  :type 'boolean
  :group 'luau-lsp)

(defcustom luau-lsp-headerline-breadcrumb-enable nil
  "Whether lsp-mode shows breadcrumbs in its headerline."
  :type 'boolean
  :group 'luau-lsp)

(defcustom luau-lsp-ui-doc-enable nil
  "Whether lsp-ui automatically displays hover documentation."
  :type 'boolean
  :group 'luau-lsp)

(defcustom luau-lsp-ui-doc-show-with-mouse nil
  "Whether lsp-ui displays hover documentation from mouse movement."
  :type 'boolean
  :group 'luau-lsp)

(defcustom luau-lsp-platform 'roblox
  "Environment used by luau-lsp when resolving built-in globals."
  :type '(choice (const roblox) (const standard))
  :group 'luau-lsp)

(defcustom luau-lsp-sourcemap-autogenerate t
  "Let luau-lsp invoke Rojo to regenerate sourcemaps."
  :type 'boolean
  :group 'luau-lsp)

(defcustom luau-lsp-sourcemap-file "sourcemap.json"
  "Filename for the generated Rojo instance-tree sourcemap."
  :type 'string
  :group 'luau-lsp)

(defcustom luau-lsp-rojo-command "rojo"
  "Rojo binary used by the language server for sourcemap generation."
  :type 'string
  :group 'luau-lsp)

(defcustom luau-lsp-use-pinned-types nil
  "Pass checkout-local API definitions to the server if present.
Roblox types are already bundled by modern luau-lsp releases, so this
is opt-in to avoid accidentally overriding built-in definitions."
  :type 'boolean
  :group 'luau-lsp)

(defcustom luau-lsp-extra-definition-files nil
  "Extra labeled Luau definitions as (NAME . FILE) pairs.
These are translated to `--definitions:@NAME=FILE' arguments."
  :type '(repeat (cons (string :tag "Definition label")
                       (file :tag "Definition file")))
  :group 'luau-lsp)

(defcustom luau-lsp-enable-fflag-sync nil
  "Whether luau-lsp synchronizes Roblox feature flags."
  :type 'boolean
  :group 'luau-lsp)

(defcustom luau-lsp-auto-guess-root t
  "Set `lsp-auto-guess-root' locally for Luau buffers."
  :type 'boolean
  :group 'luau-lsp)

(defcustom luau-lsp-diagnostics-buffer-name "*Luau LSP Doctor*"
  "Buffer used for interactive server setup diagnostics."
  :type 'string
  :group 'luau-lsp)

(defface luau-lsp-status-ok-face
  '((t :inherit success))
  "Face for available language-server components."
  :group 'luau-lsp)

(defface luau-lsp-status-warning-face
  '((t :inherit warning))
  "Face for missing optional language-server components."
  :group 'luau-lsp)

(defface luau-lsp-status-title-face
  '((t :inherit bold :height 1.15))
  "Face for interactive Luau LSP diagnostics headings."
  :group 'luau-lsp)

(defvar luau-lsp--registered nil
  "Non-nil when the lsp-mode client has been registered this session.")

(defun luau-lsp--command-executable-p (command)
  "Return non-nil if COMMAND executable exists and can be invoked."
  (and (consp command)
       (seq-every-p (lambda (s) (and (stringp s) (not (string-empty-p s)))) command)
       (let ((program (car command)))
         (if (file-name-absolute-p program)
             (file-executable-p program)
           (executable-find program)))))

(defun luau-lsp--definitions ()
  "Get the configured type definition arguments for the current project."
  (let ((files (copy-sequence luau-lsp-extra-definition-files)))
    ;; A cached Roblox API and checkout-pinned Roblox types both declare
    ;; the engine globals.  Never load both sets in the same LSP process.
    (when (and luau-lsp-use-pinned-types
               (not (luau-roblox--selected-definition))
               (fboundp 'luau--project-root)
               (fboundp 'luau--find-api-types))
      (when-let* ((root (luau--project-root nil t))
                  (file (luau--find-api-types root)))
        (push (cons "pinned" file) files)))
    (mapcar (lambda (entry)
              (unless (and (consp entry) (stringp (car entry))
                           (string-match-p "\\`[[:alnum:]_-]+\\'" (car entry))
                           (stringp (cdr entry)) (file-readable-p (cdr entry)))
                (user-error "Invalid Luau definition file: %S" entry))
              (format "--definitions:@%s=%s"
                      (car entry) (expand-file-name (cdr entry))))
            files)))

(defun luau-lsp--roblox-arguments ()
  "Get Roblox API arguments, repairing a stale already-loaded API module.
Some users reload Luau Mode between development cycles while an older
`luau-roblox' feature is still loaded.  The command must not call a missing
function from that outdated in-memory feature."
  (unless (fboundp 'luau-roblox-api-arguments)
    (when-let* ((source (locate-library "luau-roblox.el")))
      (load source nil 'nomessage)))
  (unless (fboundp 'luau-roblox-api-arguments)
    (user-error "Roblox API module is stale: reload luau-roblox.el or restart Emacs"))
  (luau-roblox-api-arguments))

(defun luau-lsp--validated-command ()
  "Return the current stdio command, or raise an actionable error."
  (unless (luau-lsp--command-executable-p luau-lsp-command)
    (user-error "Luau LSP unavailable: customize `luau-lsp-command' (%S)"
                luau-lsp-command))
  (append (copy-sequence luau-lsp-command)
          (luau-lsp--roblox-arguments)
          (luau-lsp--definitions)))

(defun luau-lsp--preferred-backend ()
  "Choose the installed LSP client without installing any package."
  (pcase luau-lsp-backend
    ('none nil)
    ('lsp-mode (when (locate-library "lsp-mode") 'lsp-mode))
    ('eglot (when (locate-library "eglot") 'eglot))
    ('auto (if luau-lsp-prefer-installed-lsp-mode
               (cond ((locate-library "lsp-mode") 'lsp-mode)
                     ((locate-library "eglot") 'eglot))
             (cond ((locate-library "eglot") 'eglot)
                   ((locate-library "lsp-mode") 'lsp-mode))))))

(defun luau-lsp--running-backend ()
  "Return the active client for this buffer, or nil."
  (cond ((bound-and-true-p lsp-mode) 'lsp-mode)
        ((and (fboundp 'eglot-managed-p) (eglot-managed-p)) 'eglot)))

(defun luau-lsp--settings ()
  "Return a settings alist, shared by both language-server clients."
  (let ((rojo (and (fboundp 'luau--project-root)
                   (luau--project-root nil t))))
    `(("luau-lsp.platform.type" . ,(symbol-name luau-lsp-platform))
      ("luau-lsp.sourcemap.enabled" . ,(and rojo luau-rojo-sourcemap-enabled t))
      ("luau-lsp.sourcemap.autogenerate" . ,(and rojo luau-lsp-sourcemap-autogenerate t))
      ("luau-lsp.sourcemap.rojoProjectFile" . ,luau-rojo-project-file)
      ("luau-lsp.sourcemap.sourcemapFile" . ,luau-lsp-sourcemap-file)
      ("luau-lsp.sourcemap.includeNonScripts" . ,(and rojo luau-rojo-sourcemap-include-non-scripts t))
      ("luau-lsp.sourcemap.rojoPath" . ,luau-lsp-rojo-command)
      ("luau-lsp.fflags.sync" . ,luau-lsp-enable-fflag-sync))))

(defun luau-lsp--register-lsp-mode ()
  "Register a dedicated luau-lsp stdio client for `luau-mode'."
  (unless (or (featurep 'lsp-mode) (require 'lsp-mode nil t))
    (user-error "LSP-mode is not installed; customize `luau-lsp-backend'"))
  ;; Keep language registration independent of server availability.
  (add-to-list 'lsp-language-id-configuration '(luau-mode . "luau"))
  (unless luau-lsp--registered
    ;; A callback is essential: changing the custom program should not
    ;; require re-registering a client, and per-project definitions vary.
    (lsp-register-client
     (make-lsp-client
      :new-connection (lsp-stdio-connection #'luau-lsp--validated-command)
      :activation-fn (lsp-activate-on "luau")
      :major-modes '(luau-mode)
      :priority 5
      :server-id 'luau-lsp-laluxx
      :multi-root luau-lsp-multi-root))
    ;; lsp-mode's settings map reads the current variable values.  The
    ;; general settings are deliberately global; Rojo-specific settings
    ;; are supplied locally through `luau-lsp--configure-settings'.
    (lsp-register-custom-settings
     '(("luau-lsp.platform.type" luau-lsp--platform-setting)
       ("luau-lsp.sourcemap.enabled" luau-lsp--sourcemap-setting t)
       ("luau-lsp.sourcemap.autogenerate" luau-lsp--autogenerate-setting t)
       ("luau-lsp.sourcemap.rojoProjectFile" luau-rojo-project-file)
       ("luau-lsp.sourcemap.sourcemapFile" luau-lsp-sourcemap-file)
       ("luau-lsp.sourcemap.includeNonScripts" luau-lsp--include-non-scripts-setting t)
       ("luau-lsp.sourcemap.rojoPath" luau-lsp-rojo-command)
       ("luau-lsp.fflags.sync" luau-lsp-enable-fflag-sync t)))
    (setq luau-lsp--registered t)))

(defvar-local luau-lsp--platform-setting "roblox")
(defvar-local luau-lsp--sourcemap-setting nil)
(defvar-local luau-lsp--autogenerate-setting nil)
(defvar-local luau-lsp--include-non-scripts-setting nil)

(defun luau-lsp--configure-settings ()
  "Populate the buffer-local settings used by lsp-mode."
  (let ((rojo (luau--project-root nil t)))
    (setq-local luau-lsp--platform-setting (symbol-name luau-lsp-platform)
                luau-lsp--sourcemap-setting (and rojo luau-rojo-sourcemap-enabled t)
                luau-lsp--autogenerate-setting (and rojo luau-lsp-sourcemap-autogenerate t)
                luau-lsp--include-non-scripts-setting
                (and rojo luau-rojo-sourcemap-include-non-scripts t))))

(defun luau-lsp--start-lsp-mode ()
  "Start lsp-mode with local quality-of-life settings for Luau."
  (luau-lsp--register-lsp-mode)
  (luau-lsp--configure-settings)
  (setq-local lsp-auto-guess-root luau-lsp-auto-guess-root
              lsp-enable-symbol-highlighting luau-lsp-enable-symbol-highlighting
              lsp-idle-delay luau-lsp-idle-delay
              lsp-headerline-breadcrumb-enable luau-lsp-headerline-breadcrumb-enable
              lsp-ui-doc-enable luau-lsp-ui-doc-enable
              lsp-ui-doc-show-with-mouse luau-lsp-ui-doc-show-with-mouse)
  (lsp-deferred))

(defun luau-lsp--eglot-settings ()
  "Build nested Eglot workspace settings from public Luau options."
  (let ((rojo (luau--project-root nil t)))
    `(:luau-lsp
      (:platform (:type ,(symbol-name luau-lsp-platform))
       :sourcemap (:enabled ,(if (and rojo luau-rojo-sourcemap-enabled) t :json-false)
                   :autogenerate ,(if (and rojo luau-lsp-sourcemap-autogenerate) t :json-false)
                   :rojoProjectFile ,luau-rojo-project-file
                   :sourcemapFile ,luau-lsp-sourcemap-file
                   :includeNonScripts ,(if (and rojo luau-rojo-sourcemap-include-non-scripts) t :json-false)
                   :rojoPath ,luau-lsp-rojo-command)
       :fflags (:sync ,(if luau-lsp-enable-fflag-sync t :json-false))))))

(defun luau-lsp--start-eglot ()
  "Start Eglot with a buffer-local, standalone Luau LSP definition."
  (unless (require 'eglot nil t)
    (user-error "Eglot could not be loaded"))
  ;; The first matching association takes precedence over any preinstalled
  ;; eglot-luau integration, keeping the custom command authoritative.
  (setq-local eglot-server-programs
              (cons (cons 'luau-mode (luau-lsp--validated-command))
                    (seq-remove (lambda (entry)
                                  (eq (car-safe entry) 'luau-mode))
                                eglot-server-programs)))
  (setq-local eglot-workspace-configuration (luau-lsp--eglot-settings))
  (eglot-ensure))

(defun luau-lsp-ensure ()
  "Connect Luau to `luau-lsp' with the configured installed LSP client.
Both Eglot and lsp-mode are supported, but only one runs per buffer."
  (interactive)
  (when (eq luau-lsp-backend 'none)
    (user-error "Luau LSP is disabled by `luau-lsp-backend'"))
  (luau-lsp--validated-command)
  (let ((backend (luau-lsp--preferred-backend))
        (active (luau-lsp--running-backend)))
    (unless backend
      (user-error "Install lsp-mode or Eglot, or choose another `luau-lsp-backend'"))
    (cond ((and active (not (eq active backend)))
           (user-error "%s already manages this buffer; stop it before enabling %s"
                       active backend))
          (active active)
          ((eq backend 'lsp-mode) (luau-lsp--start-lsp-mode))
          ((eq backend 'eglot) (luau-lsp--start-eglot)))
    backend))

(defun luau-lsp-auto-ensure ()
  "Start Luau LSP silently when dependencies and source buffers permit."
  (when (and luau-lsp-auto-start
             buffer-file-name
             (or (not (luau--project-root nil t)) luau-rojo-automatic-lsp)
             (luau-lsp--command-executable-p luau-lsp-command)
             (luau-lsp--preferred-backend)
             (not (luau-lsp--running-backend)))
    (condition-case err
        (luau-lsp-ensure)
      (error (message "Luau LSP: %s" (error-message-string err))))))

(defun luau-lsp-show-doc ()
  "Display documentation at point using lsp-ui or the active client."
  (interactive)
  (pcase (luau-lsp--running-backend)
    ('lsp-mode
     (cond ((and (require 'lsp-ui-doc nil t) (fboundp 'lsp-ui-doc-show))
            (lsp-ui-doc-show))
           ((fboundp 'lsp-describe-thing-at-point)
            (lsp-describe-thing-at-point))
           (t (user-error "No lsp-mode documentation command available"))))
    ('eglot (if (fboundp 'eldoc-print-current-symbol-info)
                (eldoc-print-current-symbol-info)
              (user-error "Eldoc is unavailable")))
    (_ (user-error "Start the Luau language server first"))))

(defun luau-lsp--value (object key)
  "Fetch KEY in LSP OBJECT, supporting hash tables and plists."
  (cond ((hash-table-p object)
         (or (gethash key object)
             (and (keywordp key)
                  (gethash (substring (symbol-name key) 1) object))))
        ((listp object) (plist-get object key))))

(defvar luau-lsp--workspace-candidates nil
  "Dynamically bound completion candidates for workspace symbol annotations.")

(defun luau-lsp--workspace-annotation (candidate)
  "Return the type of workspace variable CANDIDATE for completion UIs.
This standard completion annotation also works with optional Marginalia
without loading or modifying the Marginalia package."
  (when-let* ((entry (assoc candidate luau-lsp--workspace-candidates)))
    (propertize
     (format "  %-9s"
             (pcase (nth 3 (cdr entry))
               (7 "property") (8 "field")
               (13 "variable") (14 "constant") (_ "symbol")))
     'face 'luau-interface-symbol-kind-face)))

(defun luau-lsp--select-workspace-variable (symbols)
  "Select a source variable from LSP SYMBOLS and navigate to its definition.
Accept both JSON-RPC vectors and lists using the same representation."
  (let* ((root (or (luau--project-root nil t) default-directory))
         (candidates
          (delq nil
                (mapcar
                 (lambda (symbol)
                   (let* ((kind (luau-lsp--value symbol :kind))
                          (location (luau-lsp--value symbol :location))
                          (uri (luau-lsp--value location :uri))
                          (range (luau-lsp--value location :range))
                          (start (luau-lsp--value range :start))
                          (line (luau-lsp--value start :line))
                          (column (luau-lsp--value start :character))
                          (path (and (stringp uri) (luau--file-uri-path uri)))
                          (name (luau-lsp--value symbol :name)))
                     (when (and (memq kind '(7 8 13 14))
                                (stringp name) path
                                (natnump line) (natnump column))
                       (cons (concat
                              (propertize name 'face 'luau-interface-symbol-kind-face)
                              (propertize
                               (format "  %s:%d"
                                       (file-relative-name path root) (1+ line))
                               'face 'luau-interface-imenu-location-face))
                             (list path line column kind)))))
                 (append symbols nil)))))
    (unless candidates
      (user-error "Luau LSP returned no navigable workspace variable symbols"))
    (let* ((luau-lsp--workspace-candidates candidates)
           (completion-extra-properties
            (list :annotation-function #'luau-lsp--workspace-annotation))
           (selection (completing-read "Luau project variable: " candidates nil t))
           (entry (cdr (assoc selection candidates))))
      (luau--lsp-position (nth 0 entry) (nth 1 entry) (nth 2 entry)))))

(defun luau-lsp-workspace-variables ()
  "Browse variables, fields, constants and properties using lsp-mode.
Workspace symbols are static source locations, not live Roblox values."
  (interactive)
  (unless (eq (luau-lsp--running-backend) 'lsp-mode)
    (user-error "The current buffer is not managed by lsp-mode"))
  (luau-lsp--select-workspace-variable
   (lsp-request "workspace/symbol" (list :query ""))))

;;;###autoload
(defun luau-lsp-restart ()
  "Restart the active Luau LSP client to load changed API declarations."
  (interactive)
  (pcase (luau-lsp--running-backend)
    ('lsp-mode (lsp-workspace-restart))
    ('eglot (unless (fboundp 'eglot-reconnect)
              (user-error "Eglot reconnect is unavailable"))
            (eglot-reconnect (eglot-current-server)))
    (_ (luau-lsp-ensure))))

(defun luau-lsp-diagnose ()
  "Show executable, client, Rojo, and active-server diagnostics in one buffer."
  (interactive)
  (let* ((backend (luau-lsp--preferred-backend))
         (running (luau-lsp--running-backend))
         (root (luau--project-root nil t))
         (found (luau-lsp--command-executable-p luau-lsp-command))
         (api-definition (condition-case err
                             (or (luau-roblox--selected-definition)
                                 "SERVER-BUNDLED")
                           (error (format "MISSING: %s" (error-message-string err)))))
         (checks
          `(("Command" ,(if found "AVAILABLE" "MISSING")
             ,(if found 'luau-lsp-status-ok-face 'luau-lsp-status-warning-face))
            ("lsp-mode" ,(if (locate-library "lsp-mode") "INSTALLED" "NOT INSTALLED")
             ,(if (locate-library "lsp-mode") 'luau-lsp-status-ok-face
                'luau-lsp-status-warning-face))
            ("Eglot" ,(if (locate-library "eglot") "INSTALLED" "NOT INSTALLED")
             ,(if (locate-library "eglot") 'luau-lsp-status-ok-face
                'luau-lsp-status-warning-face))
            ("Active client" ,(format "%s" (or running "NONE"))
             ,(if running 'luau-lsp-status-ok-face 'luau-lsp-status-warning-face))
            ("Roblox API" ,api-definition
             ,(if (string-prefix-p "MISSING:" api-definition)
                  'luau-lsp-status-warning-face 'luau-lsp-status-ok-face))
            ("Rojo project" ,(if root root "NOT DETECTED")
             ,(if root 'luau-lsp-status-ok-face 'luau-lsp-status-warning-face)))))
    (with-current-buffer (get-buffer-create luau-lsp-diagnostics-buffer-name)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "LUAU LANGUAGE SERVER\n" 'face 'luau-lsp-status-title-face))
        (insert (format "Selected backend: %s   Auto-start: %s\n"
                        (or backend "NONE") luau-lsp-auto-start))
        (insert (format "Command: %s\n\n" (mapconcat #'identity luau-lsp-command " ")))
        (dolist (row checks)
          (insert (format "%-18s" (car row)))
          (insert (propertize (cadr row) 'face (caddr row)))
          (insert "\n"))
        (insert "\nRoblox types: M-x luau-roblox-api-install RET\n")
        (insert "Restart: M-x luau-lsp-restart RET\n")
        (insert "Customize: M-x customize-group RET luau-lsp RET\n")
        (insert "Connect: M-x luau-lsp-ensure RET\n")
        (special-mode)))
    (display-buffer luau-lsp-diagnostics-buffer-name)))

;; Registration is initiated by `luau-mode-hook' when lsp-mode is installed.
;; Avoid top-level `eval-after-load' in a library: package-lint flags it as
;; configuration-specific, and ordinary Luau buffers register in time for
;; user hooks that invoke `lsp' or `lsp-deferred'.

(provide 'luau-lsp)
;;; luau-lsp.el ends here

;; Local Variables:
;; package-lint-main-file: "luau-mode.el"
;; End:
