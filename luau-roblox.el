;;; luau-roblox.el --- Managed Roblox API assets for Luau LSP -*- lexical-binding: t; -*-

;; Copyright (C) 2026 laluxx
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: laluxx
;; Keywords: languages, tools
;; URL: https://luau.org

;;; Commentary:

;; Optional local Roblox API declarations and documentation for luau-lsp.
;; Modern servers often bundle these.  For reproducible external-editor
;; support this library can cache the official published files explicitly.
;; Nothing is downloaded, generated, or modified during buffer activation.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)

(declare-function url-retrieve-synchronously "url" (url &optional silent inhibit-cookies timeout))
(defvar url-http-response-status)

(defgroup luau-roblox nil
  "Roblox API declarations and documentation used by Luau LSP."
  :group 'luau
  :prefix "luau-roblox-")

(defcustom luau-roblox-api-source 'auto
  "Select how Roblox API assets are passed to the language server.
With `auto', use a complete local cache if present; otherwise rely on
upstream luau-lsp's built-in Roblox definitions.  With `bundled', always
use the server's definitions.  With `cached', require local cached API
assets and report an error when the selected definitions are missing."
  :type '(choice (const :tag "Use cache if present" auto)
                 (const :tag "Use server built-ins" bundled)
                 (const :tag "Require locally cached Roblox API" cached))
  :group 'luau-roblox)

(defcustom luau-roblox-api-security "None"
  "Roblox API security level used for downloaded declarations.
Normal in-game scripts should usually use None; plugin code may need
PluginSecurity.  A changed level selects a different cache filename."
  :type '(choice (const "None")
                 (const "PluginSecurity")
                 (const "LocalUserSecurity")
                 (const "RobloxScriptSecurity"))
  :group 'luau-roblox)

(defcustom luau-roblox-api-cache-directory
  (expand-file-name "luau-lsp/roblox" user-emacs-directory)
  "Directory containing the explicitly downloaded Roblox API assets."
  :type 'directory
  :group 'luau-roblox)

(defcustom luau-roblox-api-definition-override nil
  "Optional custom Roblox declaration file; overrides cache selection.
Use an absolute path to an existing `.d.luau' file, or nil for the
managed definitions.  No file is downloaded when this is set."
  :type '(choice (const :tag "Managed declarations" nil) file)
  :group 'luau-roblox)

(defcustom luau-roblox-api-documentation-override nil
  "Optional custom API documentation JSON file; overrides cached docs."
  :type '(choice (const :tag "Managed documentation" nil) file)
  :group 'luau-roblox)

(defcustom luau-roblox-api-use-documentation t
  "Whether available Roblox API documentation is sent to luau-lsp."
  :type 'boolean
  :group 'luau-roblox)

(defcustom luau-roblox-api-download-timeout 25
  "Maximum number of seconds to wait for each explicit API download."
  :type 'natnum
  :group 'luau-roblox)

(defcustom luau-roblox-api-definitions-base-url
  "https://luau-lsp.pages.dev/type-definitions/"
  "Official Luau LSP CDN prefix for Roblox declarations."
  :type 'string
  :group 'luau-roblox)

(defcustom luau-roblox-api-docs-url
  "https://luau-lsp.pages.dev/api-docs/en-us.json"
  "Official Luau LSP CDN endpoint for Roblox API documentation."
  :type 'string
  :group 'luau-roblox)

(defface luau-roblox-status-ok-face
  '((t :inherit success))
  "Face for validated Roblox API assets."
  :group 'luau-roblox)

(defface luau-roblox-status-missing-face
  '((t :inherit warning))
  "Face for missing or optional Roblox API assets."
  :group 'luau-roblox)

(defun luau-roblox-api-definition-path ()
  "Return the cached definitions path for the selected security level."
  (expand-file-name (format "globalTypes.%s.d.luau" luau-roblox-api-security)
                    luau-roblox-api-cache-directory))

(defun luau-roblox-api-documentation-path ()
  "Return the cached Roblox documentation path."
  (expand-file-name "api-docs.en-us.json" luau-roblox-api-cache-directory))

(defun luau-roblox--valid-file-p (filename)
  "Return non-nil if FILENAME is a nonempty readable regular file."
  (and (stringp filename)
       (file-regular-p filename)
       (file-readable-p filename)
       (> (file-attribute-size (file-attributes filename)) 0)))

(defun luau-roblox--selected-definition ()
  "Return selected Roblox declarations, or nil for server built-ins."
  (cond
   (luau-roblox-api-definition-override
    (unless (luau-roblox--valid-file-p luau-roblox-api-definition-override)
      (user-error "Roblox declaration override is not readable: %s"
                  luau-roblox-api-definition-override))
    (expand-file-name luau-roblox-api-definition-override))
   ((eq luau-roblox-api-source 'bundled) nil)
   ((luau-roblox--valid-file-p (luau-roblox-api-definition-path))
    (luau-roblox-api-definition-path))
   ((eq luau-roblox-api-source 'cached)
    (user-error "Missing cached Roblox API: M-x luau-roblox-api-install"))
   (t nil)))

(defun luau-roblox--selected-documentation (definition)
  "Return documentation for DEFINITION, or nil if not configured."
  (when (and definition luau-roblox-api-use-documentation)
    (let ((file (or luau-roblox-api-documentation-override
                    (luau-roblox-api-documentation-path))))
      (cond
       ((luau-roblox--valid-file-p file) (expand-file-name file))
       (luau-roblox-api-documentation-override
        (user-error "Roblox documentation override is not readable: %s" file))
       (t nil)))))

(defun luau-roblox-api-arguments ()
  "Return validated luau-lsp options for the selected Roblox API assets.
The result is empty if server-bundled declarations are selected."
  (when-let* ((definitions (luau-roblox--selected-definition)))
    (append (list (format "--definitions:@roblox=%s" definitions))
            (when-let* ((docs (luau-roblox--selected-documentation definitions)))
              (list (concat "--docs=" docs))))))

(defun luau-roblox--download-asset (url destination kind)
  "Download URL atomically to DESTINATION, validating its KIND.
KIND is either `definitions' or `documentation'.  Existing assets are
not replaced unless the new response passes basic content validation."
  (unless (string-prefix-p "https://" url)
    (user-error "Roblox API download requires HTTPS: %s" url))
  (require 'url)
  (let* ((buffer (url-retrieve-synchronously
                  url t t luau-roblox-api-download-timeout))
         (temp nil))
    (unless (buffer-live-p buffer)
      (user-error "Roblox API download failed: %s" url))
    (unwind-protect
        (with-current-buffer buffer
          (when (and (boundp 'url-http-response-status)
                     (numberp url-http-response-status)
                     (/= url-http-response-status 200))
            (user-error "Roblox API HTTP %s: %s" url-http-response-status url))
          (goto-char (point-min))
          (unless (re-search-forward "\r?\n\r?\n" nil t)
            (user-error "Roblox API response has no HTTP header boundary"))
          (let ((payload-start (point)))
            (when (< (- (point-max) payload-start) 64)
              (user-error "Roblox API response is unexpectedly small: %s" url))
            (pcase kind
              ('definitions
               (unless (save-excursion
                         (goto-char payload-start)
                         (re-search-forward
                          "\\_<\\(declare\\|type\\|export\\)\\_>"
                          (point-max) t))
                 (user-error "Roblox definitions response is not Luau source")))
              ('documentation
               (condition-case nil
                   (save-excursion
                     (goto-char payload-start)
                     (unless (memq (char-after) '(?\{ ?\[))
                       (error "Unexpected JSON start"))
                     (json-parse-buffer))
                 (error (user-error "Roblox documentation response is not JSON")))))
            (make-directory (file-name-directory destination) t)
            (setq temp (make-temp-file
                        (expand-file-name ".api-download-"
                                          (file-name-directory destination))))
            (write-region payload-start (point-max) temp nil 'silent)
            (rename-file temp destination t)
            (setq temp nil)))
      (when (and temp (file-exists-p temp)) (delete-file temp))
      (kill-buffer buffer)))
  destination)

;;;###autoload
(defun luau-roblox-api-install ()
  "Explicitly install Roblox API declarations and documentation to the cache.
The current cache is never damaged by a failed individual download.
Restart the current LSP workspace after an update."
  (interactive)
  (let* ((definitions (luau-roblox-api-definition-path))
         (docs (luau-roblox-api-documentation-path))
         (url (concat luau-roblox-api-definitions-base-url
                      "globalTypes." luau-roblox-api-security ".d.luau")))
    (luau-roblox--download-asset url definitions 'definitions)
    (when luau-roblox-api-use-documentation
      (luau-roblox--download-asset luau-roblox-api-docs-url
                                  docs 'documentation))
    (message "Roblox API installed in %s; restart the Luau language server"
             luau-roblox-api-cache-directory)
    definitions))

;;;###autoload
(defun luau-roblox-api-status ()
  "Display the Roblox API asset configuration and cache status."
  (interactive)
  (let* ((definition (condition-case err
                         (or (luau-roblox--selected-definition) "SERVER-BUNDLED")
                       (error (format "ERROR: %s" (error-message-string err)))))
         (documentation (if (luau-roblox--valid-file-p
                             (luau-roblox-api-documentation-path))
                            (luau-roblox-api-documentation-path)
                          "NOT CACHED")))
    (with-current-buffer (get-buffer-create "*Luau Roblox API*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "LUAU / ROBLOX API\n\n" 'face 'bold))
        (insert (format "Source:          %s\nSecurity:        %s\nDefinitions:     %s\nDocumentation:   %s\n\n"
                        luau-roblox-api-source luau-roblox-api-security
                        definition documentation))
        (insert "Install/update: M-x luau-roblox-api-install\n")
        (insert "Restart LSP:   M-x luau-lsp-restart\n")
        (insert "Configure:     M-x customize-group RET luau-roblox RET\n")
        (special-mode)))
    (display-buffer "*Luau Roblox API*")))

(provide 'luau-roblox)
;;; luau-roblox.el ends here

;; Local Variables:
;; package-lint-main-file: "luau-mode.el"
;; End:
