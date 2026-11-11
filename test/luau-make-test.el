;;; luau-make-test.el --- Color-aware Make integration tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 laluxx
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Keywords: languages, tools

;;; Commentary:

;; Check that launching Make affects only its own compilation buffer and that
;; no user's global ANSI behavior or compilation configuration is modified.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'luau-mode)
(require 'luau-make)

(defvar compilation-environment)
(defvar compilation-filter-hook)

(ert-deftest luau-make-test-root-rejects-unrelated-workspace ()
  "Reject directories that do not contain the Luau Mode source."
  (with-temp-buffer
    (let ((default-directory temporary-file-directory)
          (luau-make-project-directory temporary-file-directory))
      (should-error (luau-make--root) :type 'user-error))))

(ert-deftest luau-make-test-color-setting-stays-local ()
  "Keep ANSI setup local to the Luau compilation buffer."
  (let ((root (make-temp-file "luau-make-test-" t))
        (luau-make-save-buffers-before-check nil)
        (luau-make-enable-ansi t)
        (seen-env nil))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "luau-mode.el" root) (insert ";;; test\n"))
          (with-temp-file (expand-file-name "Makefile" root) (insert "check:\n\t@true\n"))
          (with-temp-buffer
            (let ((luau-make-project-directory root))
              (cl-letf (((symbol-function 'compilation-start)
                         (lambda (_command _mode _name)
                           (setq seen-env (copy-sequence compilation-environment))
                           (current-buffer))))
                (luau-make-check)
                (should (memq #'ansi-color-compilation-filter compilation-filter-hook)))))
          (should (member "LUAU_COLOR=always" seen-env)))
      (delete-directory root t))))

(provide 'luau-make-test)
;;; luau-make-test.el ends here

;; Local Variables:
;; package-lint-main-file: "luau-mode.el"
;; End:
