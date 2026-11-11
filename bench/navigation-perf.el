;;; navigation-perf.el --- Luau navigation benchmark -*- lexical-binding: t; -*-

;; Copyright (C) 2026 laluxx
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Package-Requires: ((emacs "30.1"))
;; Keywords: languages, tools

;;; Commentary:

;; Observational benchmark for repeated top-level function navigation.

;;; Code:

(require 'benchmark)
(require 'luau-mode)
(require 'luau-lsp)

(with-temp-buffer
  (let ((luau-lsp-auto-start nil))
    (dotimes (n 200)
      (insert (format "local function work%d(x)\n  return x + %d\nend\n" n n)))
    (luau-mode)
    (let* ((sample (benchmark-run 15
                     (goto-char (point-max))
                     (luau-beginning-of-proc 1)))
           (seconds (car sample)))
      (princ (format "LUAU benchmark navigation: %.4fs / 15 iterations\n" seconds)))))

(provide 'navigation-perf)
;;; navigation-perf.el ends here

;; Local Variables:
;; package-lint-main-file: "luau-mode.el"
;; End:
