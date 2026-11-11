;;; luau-font-test.el --- Fontification and activation regressions -*- lexical-binding: t; -*-

;; Copyright (C) 2026 laluxx
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Package-Requires: ((emacs "30.1"))
;; Keywords: languages, tools

;;; Commentary:

;; Behavioral font-lock tests use the actual editor implementation without
;; requiring lsp-mode, Eglot, Roblox Studio, or a running language server.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'luau-mode)
(require 'luau-lsp)

(defvar lsp-language-id-configuration)

(defun luau-font-test--face-at (source token)
  "Return the effective font-lock face applied to TOKEN in SOURCE."
  (with-temp-buffer
    (insert source)
    (luau-mode)
    (font-lock-ensure)
    (goto-char (point-min))
    (unless (search-forward token nil t)
      (error "Missing test token %s" token))
    (get-text-property (- (point) (length token)) 'face)))

(defun luau-font-test--contains-p (face expected)
  "Check whether FACE contains EXPECTED, including inherited face lists."
  (or (eq face expected)
      (and (consp face) (memq expected face))))

(ert-deftest luau-font-test-luau-extension-auto-activates ()
  "Files ending in .luau should select Luau major mode automatically."
  (with-temp-buffer
    (setq-local buffer-file-name
                (expand-file-name "MeadowGenerator.server.luau" temporary-file-directory))
    (set-auto-mode)
    (should (eq major-mode 'luau-mode))))

(ert-deftest luau-font-test-lua-extension-is-opt-in ()
  "Plain Lua files must not be hijacked by default."
  (should-not luau-associate-lua-files))

(ert-deftest luau-font-test-all-face-symbols-exist ()
  "Every dedicated Luau face should be registered as an Emacs face."
  (dolist (name '(luau-keyword-face luau-constant-face
                  luau-builtin-face luau-function-face luau-type-name-face
                  luau-roblox-global-face luau-directive-face
                  luau-todo-face luau-warning-face luau-success-face
                  luau-error-face luau-boolean-face luau-nil-face))
    (should (facep name))))

(ert-deftest luau-font-test-core-keywords-do-not-signal-void-variable ()
  "Highlighting plain Luau must not resolve faces as variable values."
  (with-temp-buffer
    (insert "local function greet(person: string): boolean\n"
            " if person == nil then return false end\n"
            " return true\nend\n")
    (luau-mode)
    (font-lock-ensure)
    (goto-char (point-min))
    (search-forward "local")
    (should (get-text-property (- (point) 1) 'face))))

(ert-deftest luau-font-test-typed-and-roblox-highlighting ()
  "Typed declarations and Roblox globals must both be visible."
  (with-temp-buffer
    (insert "--!strict\nexport type CameraState = { position: Vector3 }\n"
            "local camera = workspace.CurrentCamera\n")
    (luau-mode)
    (font-lock-ensure)
    (goto-char (point-min))
    (search-forward "CameraState")
    (should (get-text-property (- (point) 2) 'face))
    (search-forward "Vector3")
    (should (get-text-property (- (point) 2) 'face))
    (search-forward "workspace")
    (should (get-text-property (- (point) 2) 'face))))

(ert-deftest luau-font-test-custom-severity-face-inheritance ()
  "Diagnostic faces should inherit from built-in theme roles."
  (should (equal 'error (face-attribute 'luau-error-face :inherit nil t)))
  (should (equal 'warning (face-attribute 'luau-warning-face :inherit nil t)))
  (should (equal 'success (face-attribute 'luau-success-face :inherit nil t))))

(ert-deftest luau-font-test-change-toggles-then-refontify ()
  "Custom font-lock toggles can be changed and applied in-place."
  (with-temp-buffer
    (insert "return true\n")
    (luau-mode)
    (let ((luau-font-lock-extended nil))
      (luau-refontify-buffer)
      (goto-char (point-min))
      (search-forward "true")
      (should (get-text-property (- (point) 2) 'face)))
    (let ((luau-font-lock-extended t)
          (luau-font-lock-boolean-literals t))
      (luau-refontify-buffer)
      (goto-char (point-min))
      (search-forward "true")
      (should (get-text-property (- (point) 2) 'face)))))

(ert-deftest luau-font-test-roblox-global-preserves-match-boundaries ()
  "Roblox token matchers must never corrupt regexp state during syntax parsing."
  (with-temp-buffer
    (insert "local camera = workspace.CurrentCamera\n")
    (luau-mode)
    (goto-char (point-min))
    (should (luau--font-lock-roblox-global (point-max)))
    (should (equal (match-string 0) "workspace"))
    (should (= (point) (match-end 0)))))

(ert-deftest luau-font-test-roblox-global-advances-past-rejections ()
  "Rejected fields and comments must not cause an infinite font-lock scan."
  (with-temp-buffer
    (insert "local obj = thing.game\n-- workspace is a comment\n"
            "local camera = workspace.CurrentCamera\n")
    (luau-mode)
    (goto-char (point-min))
    (should (luau--font-lock-roblox-global (point-max)))
    (should (equal (match-string 0) "workspace"))
    (should (= (point) (match-end 0)))
    (should-not (luau--font-lock-roblox-global (point-max)))))

(ert-deftest luau-font-test-server-registration-not-dependent-on-binary ()
  "Registering the client must not require an installed luau-lsp binary."
  (let ((lsp-language-id-configuration nil)
        (luau-lsp--registered nil)
        registered)
    (cl-letf (((symbol-function 'require)
               (let ((original-require (symbol-function 'require)))
                 (lambda (feature &optional filename noerror)
                   (if (eq feature 'lsp-mode) t
                     (funcall original-require feature filename noerror)))))
              ((symbol-function 'lsp-stdio-connection) #'identity)
              ((symbol-function 'lsp-activate-on) #'identity)
              ((symbol-function 'make-lsp-client) #'list)
              ((symbol-function 'lsp-register-client)
               (lambda (client) (setq registered client)))
              ((symbol-function 'lsp-register-custom-settings) #'ignore)
              ((symbol-function 'luau-lsp--validated-command)
               (lambda () (error "This must not be called by registration"))))
      (luau-lsp--register-lsp-mode)
      (should registered)
      (should (member '(luau-mode . "luau") lsp-language-id-configuration)))))

(provide 'luau-font-test)
;;; luau-font-test.el ends here

;; Local Variables:
;; package-lint-main-file: "luau-mode.el"
;; End:
