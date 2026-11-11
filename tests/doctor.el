;;; doctor.el --- Recursive package diagnostics -*- lexical-binding: t; -*-

;; Copyright (C) 2026 laluxx

;; Package-Requires: ((emacs "30.1"))
;; Keywords: languages, tools

;;; Commentary:
;; Loaded by Makefile after byte-compilation and ERT.

;;; Code:

(require 'checkdoc)
(require 'seq)

(let* ((root (expand-file-name ".." (file-name-directory load-file-name)))
       (files (directory-files-recursively root "\\.el\\'"))
       (package-lint-available (require 'package-lint nil t)))
  (dolist (file files)
    (message "[CHECKDOC] %s" (file-relative-name file root))
    (with-current-buffer (find-file-noselect file)
      (checkdoc-current-buffer t)
      (if package-lint-available
          (progn
            (message "[PACKAGE-LINT] %s" (file-relative-name file root))
            (package-lint-current-buffer))
        (message "[SKIP] package-lint unavailable for %s"
                 (file-relative-name file root))))))

(provide 'doctor)
;;; doctor.el ends here

;; Local Variables:
;; package-lint-main-file: "luau-mode.el"
;; End:
