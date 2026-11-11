;;; luau-make.el --- Color-aware quality checks for Luau Mode -*- lexical-binding: t; -*-

;; Copyright (C) 2026 laluxx
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: laluxx
;; Keywords: languages, tools

;;; Commentary:

;; Launch the existing `make check' quality matrix from Emacs compilation
;; mode.  Colors remain encoded as ANSI escapes in the source process, then
;; converted to Emacs faces locally in this compilation buffer.  Other
;; compilation buffers and the user's global color settings are untouched.

;;; Code:

(require 'compile)
(require 'ansi-color)
(require 'subr-x)

(defgroup luau-make nil
  "Run Luau Mode Make checks with color-aware Emacs diagnostics."
  :group 'luau
  :prefix "luau-make-")

(defcustom luau-make-command "make check"
  "Command run by `luau-make-check'."
  :type 'string
  :risky t
  :group 'luau-make)

(defcustom luau-make-project-directory nil
  "Optional directory containing the Luau Mode development Makefile.
When nil, discover the nearest enclosing directory containing `luau-mode.el'."
  :type '(choice (const :tag "Find package root" nil)
                 (directory :tag "Package directory"))
  :group 'luau-make)

(defcustom luau-make-enable-ansi t
  "Translate ANSI-colored status output into Emacs faces in the check buffer."
  :type 'boolean
  :group 'luau-make)

(defcustom luau-make-output-buffer-name "*Luau Make Check*"
  "Buffer name used for the colorized Make quality report."
  :type 'string
  :group 'luau-make)

(defcustom luau-make-scroll-output nil
  "When non-nil, scroll the Luau check buffer as new output arrives."
  :type 'boolean
  :group 'luau-make)

(defcustom luau-make-save-buffers-before-check t
  "Whether to save modified Luau package sources before checks."
  :type 'boolean
  :group 'luau-make)

(defface luau-make-pass-face
  '((t :inherit success))
  "Semantic face for successful Luau Make checks."
  :group 'luau-make)

(defface luau-make-fail-face
  '((t :inherit error))
  "Semantic face for failed Luau Make checks."
  :group 'luau-make)

(defface luau-make-progress-face
  '((t :inherit font-lock-keyword-face))
  "Semantic face for active Luau Make checks."
  :group 'luau-make)

(defface luau-make-timeout-face
  '((t :inherit warning))
  "Semantic face for bounded execution timeouts."
  :group 'luau-make)

(defun luau-make--root ()
  "Return a verified Luau package root for a Make quality check."
  (let ((root (or luau-make-project-directory
                  (locate-dominating-file default-directory "luau-mode.el"))))
    (unless (and root (file-readable-p (expand-file-name "Makefile" root))
                 (file-readable-p (expand-file-name "luau-mode.el" root)))
      (user-error "Set `luau-make-project-directory' to the Luau Mode source directory"))
    (file-name-as-directory (expand-file-name root))))

;;;###autoload
(defun luau-make-check ()
  "Run `make check' with an ANSI-color-aware Emacs compilation buffer.
All Make targets continue after individual failures, and a TAR.GZ report
is produced by the underlying Makefile for the next development cycle."
  (interactive)
  (when luau-make-save-buffers-before-check
    (save-some-buffers))
  (let* ((default-directory (luau-make--root))
         (compilation-environment
          (cons (if luau-make-enable-ansi "LUAU_COLOR=always" "LUAU_COLOR=never")
                compilation-environment))
         (compilation-scroll-output luau-make-scroll-output)
         (buffer (compilation-start
                  luau-make-command 'compilation-mode
                  (lambda (_command) luau-make-output-buffer-name))))
    (when (and buffer luau-make-enable-ansi)
      (with-current-buffer buffer
        (add-hook 'compilation-filter-hook #'ansi-color-compilation-filter nil t)))
    buffer))

(provide 'luau-make)
;;; luau-make.el ends here

;; Local Variables:
;; package-lint-main-file: "luau-mode.el"
;; End:
