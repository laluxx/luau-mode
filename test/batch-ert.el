;;; batch-ert.el --- Headless project-wide ERT runner -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Luau contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Package-Requires: ((emacs "30.1"))
;; Keywords: languages, tools

;;; Commentary:

;; Automatically loads every nested *-test.el file before invoking ERT.
;; The normal ERT reporter prints every test and detailed failure trace;
;; the additional summary makes regressions visible at a glance.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'subr-x)

;;; Discovery

(defvar luau-tests-selector nil
  "ERT selector used by the batch runner, or nil for the full suite.")

(defun luau-tests--files (&optional root)
  "Return sorted, unique ERT test modules under ROOT."
  (let ((directory (file-name-as-directory
                    (expand-file-name (or root default-directory)))))
    (sort (append (directory-files-recursively
                   (expand-file-name "test" directory) "-test\\.el\\'")
                  (directory-files-recursively
                   (expand-file-name "tests" directory) "-tests\\.el\\'"))
          #'string<)))

;;; Execution

(defun luau-tests--suite-label (name)
  "Classify ERT test NAME for the headless overview."
  (cond ((string-prefix-p "luau-lsp-test-" name) "LSP / Rojo")
        ((string-prefix-p "luau-test-" name) "Editor baseline")
        ((string-prefix-p "luau-interface-test-" name) "Structural UI")
        (t "Other tooling")))

(defun luau-tests--print-inventory (selector)
  "Print a deterministic test-suite inventory for SELECTOR."
  (let ((counts (make-hash-table :test #'equal)))
    (dolist (test (ert-select-tests selector t))
      (let ((group (luau-tests--suite-label
                    (symbol-name (ert-test-name test)))))
        (puthash group (1+ (gethash group counts 0)) counts)))
    (princ "  Coverage by test family:\n")
    (dolist (group '("Editor baseline" "LSP / Rojo" "Structural UI" "Other tooling"))
      (when (> (gethash group counts 0) 0)
        (princ (format "    %-22s %5d tests\n"
                       group (gethash group counts 0)))))))

(defun luau-tests-run ()
  "Load the project test suite and terminate Emacs with its result."
  (let* ((files (luau-tests--files))
         (env-selector (getenv "LUAU_TEST_SELECTOR"))
         (luau-tests-selector
          (if (and env-selector (not (string-empty-p env-selector)))
              env-selector
            luau-tests-selector))
         (started (float-time)))
    (princ "\n===============================================================\n")
    (princ " LUAU MODE  |  HEADLESS ERT REGRESSION SUITE\n")
    (princ "===============================================================\n")
    (dolist (file files)
      (princ (format "  + %s\n" (file-relative-name file)))
      (load file nil 'nomessage))
    (princ (format "\n  Emacs %s | %d test modules loaded | selector: %S\n\n"
                   emacs-version
                   (length files) (or luau-tests-selector t)))
    (luau-tests--print-inventory (or luau-tests-selector t))
    (princ "\n")
    (when (null (ert-select-tests (or luau-tests-selector t) t))
      (princ "ERROR: selector matched zero tests; refusing a false PASS\n")
      (kill-emacs 2))
    (let* ((test-selector (or (and (getenv "LUAU_ERT_SINGLE")
                                    (intern (getenv "LUAU_ERT_SINGLE")))
                               luau-tests-selector t))
           (stats (ert-run-tests-batch test-selector))
           (total (ert-stats-total stats))
           (expected (ert-stats-completed-expected stats))
           (unexpected (ert-stats-completed-unexpected stats))
           (skipped (ert-stats-skipped stats)))
      (princ "\n---------------------------------------------------------------\n")
      (princ (format " RESULT  %d/%d expected  |  %d unexpected  |  %d skipped\n"
                     expected total unexpected skipped))
      (princ (format " Runtime: %.3fs | %s\n"
                     (- (float-time) started)
                     (if (and (zerop unexpected) (zerop skipped)) "PASS" "FAIL")))
      (princ "---------------------------------------------------------------\n")
      (kill-emacs (if (and (zerop unexpected) (zerop skipped)) 0 1)))))

(defun luau-tests-list ()
  "Print available ERT names for the isolated Make test runner."
  (dolist (file (luau-tests--files))
    (load file nil 'nomessage))
  (let ((selector (or (getenv "LUAU_TEST_SELECTOR") t)))
    (dolist (test (ert-select-tests selector t))
      (princ (format "LUAU_ERT_TEST:%s\n" (ert-test-name test))))))

(if (getenv "LUAU_ERT_LIST")
    (luau-tests-list)
  (luau-tests-run))

(provide 'batch-ert)
;;; batch-ert.el ends here

;; Local Variables:
;; package-lint-main-file: "luau-mode.el"
;; End:
