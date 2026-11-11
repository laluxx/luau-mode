;;; batch-doctor.el --- Headless recursive Luau quality gate -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Luau contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Package-Requires: ((emacs "30.1"))
;; Keywords: languages, tools

;;; Commentary:

;; Invoked by `make doctor'.  Fail closed when package-lint is unavailable
;; or any project Emacs Lisp file fails an inspection.

;;; Code:

(require 'package)
(require 'luau-doctor)

;;; Execution

(condition-case err
    (let* ((choice (getenv "LUAU_DOCTOR_CHECKS"))
           (checkers (luau-doctor-select-checkers choice)))
      (kill-emacs (if (luau-doctor-run nil checkers) 0 1)))
  (error
   (princ (format "[ERROR] Luau doctor: %s\n" (error-message-string err)))
   (kill-emacs 2)))

(provide 'batch-doctor)
;;; batch-doctor.el ends here

;; Local Variables:
;; package-lint-main-file: "luau-mode.el"
;; End:
