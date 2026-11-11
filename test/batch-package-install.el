;;; batch-package-install.el --- Isolated Luau package install smoke test -*- lexical-binding: t; -*-

;; Copyright (C) 2026 laluxx
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: laluxx
;; Keywords: languages, tools

;;; Commentary:

;; Run only from make check.  The Emacs process is started with -Q and no
;; source -L path.  Install the generated multi-file tar in an isolated
;; package-user-dir, then verify autoloads and the actual installed modules.

;;; Code:

(require 'package)
(require 'seq)

(defun luau-package-install--run ()
  "Install a package TAR in a fresh profile and check the public APIs."
  (let* ((archive (getenv "LUAU_RELEASE_TAR"))
         (user-emacs-directory
          (file-name-as-directory (make-temp-file "luau-install-home-" t)))
         (package-user-dir (expand-file-name "elpa" user-emacs-directory))
         (package-archives nil)
         (package-enable-at-startup nil))
    (unwind-protect
        (progn
          (unless (and (stringp archive) (file-readable-p archive))
            (error "LUAU_RELEASE_TAR must name a readable package tar"))
          (make-directory package-user-dir t)
          (package-initialize)
          (package-install-file archive)
          (unless (package-installed-p 'luau-mode)
            (error "Package.el did not install luau-mode"))
          ;; package-install-file normally activates the new package.  The
          ;; explicit activation also detects missing dependency metadata.
          (package-activate 'luau-mode)
          (dolist (module '("luau-mode" "luau-lsp" "luau-roblox" "luau-make" "luau-interface"))
            (let ((location (locate-library module)))
              (unless (and location (file-in-directory-p location package-user-dir))
                (error "Module %s escaped installed package dir: %S"
                       module location))))
          ;; Prevent a live server startup during isolated package activation.
          (setq-default luau-lsp-auto-start nil)
          ;; Test the generated auto-mode autoload BEFORE requiring the mode.
          (with-temp-buffer
            (setq-local buffer-file-name
                        (expand-file-name "Example.server.luau" user-emacs-directory))
            (set-auto-mode)
            (unless (eq major-mode 'luau-mode)
              (error "Autoload did not activate luau-mode for .server.luau")))
          (require 'luau-mode)
          (unless (fboundp 'luau-imenu)
            (error "Installed package did not export Luau Imenu"))
          (let ((luau-lsp-auto-start nil))
            (with-temp-buffer
              (insert "--!strict\nlocal v: Vector3 = Vector3.new(1, 2, 3)\n")
              (luau-mode)
              (font-lock-ensure)
              (goto-char (point-min))
              (search-forward "Vector3")
              (unless (get-text-property (- (point) 2) 'face)
                (error "Installed major mode did not apply type highlighting"))
              (unless (eq (lookup-key luau-mode-map (kbd "C-c C-u"))
                          'luau-roblox-api-status)
                (error "Roblox status command missing from installed keymap"))))
          (princ "LUAU INSTALLED PACKAGE / PASS\n")
          (princ "  package-install-file: PASS\n")
          (princ "  load-path isolation:   PASS\n")
          (princ "  generated autoloads:   PASS\n")
          (princ "  installed font-lock:   PASS\n"))
      (delete-directory user-emacs-directory t))))

(luau-package-install--run)

(provide 'batch-package-install)
;;; batch-package-install.el ends here
