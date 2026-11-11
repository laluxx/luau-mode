;;; font-lock-perf.el --- Luau fontification benchmark -*- lexical-binding: t; -*-

;; Copyright (C) 2026 laluxx
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Package-Requires: ((emacs "30.1"))
;; Keywords: languages, tools

;;; Commentary:

;; Observational benchmark; do not treat absolute time as a quality gate.

;;; Code:

(require 'benchmark)
(require 'luau-mode)
(require 'luau-lsp)

(with-temp-buffer
  (let ((luau-lsp-auto-start nil))
    (dotimes (_ 24)
      (insert "--!strict\nexport type Node<T> = { value: T, parent: Node<T>? }\n"
              "local camera: Camera = workspace.CurrentCamera\n"
              "function focus<T>(item: T): T\n"
              "  return if item then item else item\nend\n"))
    (luau-mode)
    (princ "LUAU_BENCH_STAGE:mode-ready\n")
    (let* ((sample (benchmark-run 3 (font-lock-flush) (font-lock-ensure)))
           (seconds (car sample)))
      (princ (format "LUAU benchmark font-lock: %.4fs / 3 iterations\n" seconds)))))

(provide 'font-lock-perf)
;;; font-lock-perf.el ends here

;; Local Variables:
;; package-lint-main-file: "luau-mode.el"
;; End:
