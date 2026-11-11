;;; luau-mode-tests.el --- Behavioral tests for Luau mode -*- lexical-binding: t; -*-

;; Copyright (C) 2026 laluxx

;; Package-Requires: ((emacs "30.1"))
;; Keywords: languages, tools

;;; Commentary:
;; Run with: Emacs -Q --batch -L . -l tests/luau-mode-tests.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'luau-mode)

(defmacro luau-test-with-file-project (&rest body)
  "Evaluate BODY with a disposable Rojo root in `default-directory'."
  (declare (indent 0) (debug t))
  `(let* ((root (make-temp-file "luau-rojo-test-" t))
          (default-directory (file-name-as-directory root))
          (luau-rojo-automatic-lsp nil))
     (unwind-protect
         (progn
           (with-temp-file (expand-file-name luau-rojo-project-file root)
             (insert "{}"))
           ,@body)
       (delete-directory root t))))

(ert-deftest luau-test-major-mode-self-contained ()
  "The mode should not need `lua-mode' to be loaded."
  (with-temp-buffer
    (let ((luau-rojo-automatic-lsp nil))
      (luau-mode)
      (should (eq major-mode 'luau-mode))
      (should (eq (lookup-key luau-mode-map (kbd "C-c C-f"))
                  #'luau-format-buffer))
      (should (eq indent-line-function 'luau-indent-line))
      (should (eq font-lock-syntactic-face-function #'luau--syntactic-face)))))

(ert-deftest luau-test-syntax-quotes-comments-and-backticks ()
  "String and comment syntaxes should be parsed independently."
  (with-temp-buffer
    (insert "local a = `hello {name}`\n--!strict\n--[[ long comment ]]\n")
    (luau-mode)
    (syntax-propertize (point-max))
    (goto-char (point-min))
    (search-forward "hello")
    (should (nth 3 (syntax-ppss)))
    (search-forward "strict")
    (should (nth 4 (syntax-ppss)))))

(ert-deftest luau-test-type-declaration-and-roblox-font-lock ()
  "Typed declarations and Roblox globals should have custom faces."
  (with-temp-buffer
    (insert "--!strict\nexport type CameraState = { position: Vector3 }\n"
            "local service = game:GetService(\"Players\")\n")
    (luau-mode)
    (font-lock-ensure)
    (goto-char (point-min))
    (search-forward "strict")
    (should (get-text-property (- (point) 3) 'face))
    (search-forward "CameraState")
    (should (get-text-property (- (point) 5) 'face))
    (search-forward "game")
    (should (get-text-property (- (point) 2) 'face))))

(ert-deftest luau-test-rojo-root-discovery ()
  "Rojo roots should be discoverable in nested source directories."
  (luau-test-with-file-project
    (make-directory "src/server" t)
    (let ((default-directory (expand-file-name "src/server" default-directory)))
      (should (equal (directory-file-name (file-truename (luau--project-root)))
                     (directory-file-name (file-truename (expand-file-name "../..")))))
      (should (eq (car (luau-project-try-rojo default-directory)) 'transient))
      (with-temp-buffer
        (setq default-directory (file-name-as-directory default-directory))
        (luau-mode)
        (should luau-rojo-mode)
        (should (eq (lookup-key luau-rojo-mode-map (kbd "C-c C-i"))
                    #'luau-inspect-camera))))))

(ert-deftest luau-test-default-directory-without-rojo ()
  "Non-Rojo Luau files should still get useful editing features."
  (let ((default-directory temporary-file-directory)
        (luau-rojo-automatic-lsp nil))
    (with-temp-buffer
      (luau-mode)
      (should-not luau-rojo-mode)
      (should (eq major-mode 'luau-mode)))))

(ert-deftest luau-test-command-shell-quoting ()
  "Compilation commands should quote arguments, never concatenate raw code."
  (should (equal (luau--command-string '("make" "a b"))
                 (concat (shell-quote-argument "make") " "
                         (shell-quote-argument "a b"))))
  (should-error (luau--command-string nil) :type 'user-error))

(ert-deftest luau-test-uri-decoding ()
  "Local file URIs should be decoded; nonlocal URIs should be ignored."
  (should (equal (luau--file-uri-path "file:///tmp/a%20b.luau") "/tmp/a b.luau"))
  (should (equal (luau--file-uri-path "file://localhost/tmp/test.luau")
                 "/tmp/test.luau"))
  (should-not (luau--file-uri-path "https://example.org/x.luau")))

(ert-deftest luau-test-lsp-offset-utf16 ()
  "LSP UTF-16 coordinates should work with non-BMP characters."
  (let ((file (make-temp-file "luau-offset-" nil ".luau")))
    (unwind-protect
        (progn
          (with-temp-file file (insert "x😀abc\n"))
          (with-temp-buffer
            (luau--lsp-position file 0 3)
            (should (looking-at "a"))))
      (when-let* ((buffer (find-buffer-visiting file)))
        (kill-buffer buffer))
      (delete-file file))))

(ert-deftest luau-test-formatter-error-preserves-buffer ()
  "Failed external formatting should leave the source intact."
  (let ((program (make-temp-file "luau-stylua-fail-")))
    (unwind-protect
        (progn
          (with-temp-file program
            (insert "#!/bin/sh\necho broken >&2\nexit 3\n"))
          (set-file-modes program #o755)
          (with-temp-buffer
            (insert "local x=1\n")
            (let ((luau-formatter-command (list program)))
              (should-error (luau-format-buffer) :type 'user-error)
              (should (equal (buffer-string) "local x=1\n")))))
      (delete-file program))))

(ert-deftest luau-test-rojo-processes-are-project-scoped ()
  "Stopping one Rojo root should leave another root's server alive."
  (let ((a (make-temp-file "luau-rojo-a-" t))
        (b (make-temp-file "luau-rojo-b-" t))
        (luau-rojo-serve-command '("sh" "-c" "sleep 30")))
    (unwind-protect
        (progn
          (dolist (root (list a b))
            (with-temp-file (expand-file-name luau-rojo-project-file root)
              (insert "{}")))
          (let ((default-directory a)) (luau-rojo-serve))
          (let ((default-directory b)) (luau-rojo-serve))
          (let ((pa (gethash (file-truename a) luau--rojo-processes))
                (pb (gethash (file-truename b) luau--rojo-processes)))
            (should (and (process-live-p pa) (process-live-p pb)))
            (should-not (eq pa pb))
            (let ((default-directory a)) (luau-rojo-stop))
            (should (process-live-p pb))))
      (dolist (root (list a b))
        (when-let* ((proc (gethash (file-truename root)
                                   luau--rojo-processes)))
          (when (process-live-p proc) (delete-process proc))
          (remhash (file-truename root) luau--rojo-processes))
        (delete-directory root t)))))

(provide 'luau-mode-tests)
;;; luau-mode-tests.el ends here

;; Local Variables:
;; package-lint-main-file: "luau-mode.el"
;; End:
