;;; luau-doctor.el --- Recursive quality checks for Luau -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Luau contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Package-Requires: ((emacs "30.1"))
;; Keywords: languages, tools

;;; Commentary:

;; Shared functions for the headless `make doctor' quality gate.  Every
;; project-owned Emacs Lisp file receives Checkdoc.  package-lint applies
;; to the actual distributed package files, not executable test entrypoints
;; or benchmarks; package-lint assumes that its input is a MELPA package.  The external package installation directory
;; is excluded because it is not part of the Luau source tree.
;;
;; This library does not execute any checks at load time, so ERT can test
;; file discovery without requiring an installed package-lint.

;;; Code:

(require 'cl-lib)
(require 'checkdoc)
(require 'subr-x)

(declare-function package-lint-current-buffer "package-lint" ())
(declare-function package-lint-buffer "package-lint" ())

;;; Check Selection

(defun luau-doctor-select-checkers (&optional choice)
  "Parse CHOICE into the explicit recursive checkers to run.

Nil, an empty string and `all' select both quality gates.  Unknown
values fail closed instead of accidentally disabling any check."
  (cond
   ((member choice '(nil "" "all")) '(checkdoc package-lint))
   ((equal choice "checkdoc") '(checkdoc))
   ((equal choice "package-lint") '(package-lint))
   (t (user-error "Unknown LUAU_DOCTOR_CHECKS: %s" choice))))

(defcustom luau-doctor-distributed-sources
  '("luau-mode.el" "luau-lsp.el" "luau-roblox.el" "luau-make.el" "luau-interface.el")
  "Top-level distribution files to validate with `package-lint'.
Development scripts under test/, tests/, bench/, and tools/ are checked
recursively by Checkdoc and the Make test/compile gates instead."
  :type '(repeat string)
  :group 'luau)

(defun luau-doctor--distributable-p (file root)
  "Return non-nil when FILE belongs to the shipped package under ROOT."
  (member (file-relative-name file root) luau-doctor-distributed-sources))

;;; Project File Discovery

(defun luau-doctor-files (&optional root)
  "Find all project-owned .el files recursively under ROOT.

ROOT defaults to `default-directory'.  Paths are returned absolute,
lexicographically ordered, and never include the .git or .packages trees."
  (let ((directory (file-name-as-directory
                    (expand-file-name (or root default-directory)))))
    (sort (directory-files-recursively
           directory "\\.el\\'" nil
           (lambda (subdirectory)
             (not (member (file-name-nondirectory subdirectory)
                          '(".git" ".packages" ".build")))))
          #'string<)))

;;; Reporting

(defun luau-doctor--relative-name (file root)
  "Format FILE relative to ROOT for actionable diagnostics."
  (file-relative-name file root))

(defun luau-doctor--log (format-string &rest args)
  "Write a diagnostic line using FORMAT-STRING and ARGS."
  (princ (concat (apply #'format format-string args) "\n")))

(defun luau-doctor--trace (checker file error-data)
  "Log CHECKER failure for FILE and ERROR-DATA with an Emacs backtrace."
  (luau-doctor--log "       %s:1:1: %s crashed: %s"
                     file checker (error-message-string error-data))
  (when (fboundp 'backtrace)
    (condition-case err
        (let ((trace (with-output-to-string (backtrace))))
          (when (and (stringp trace) (not (string-empty-p trace)))
            (luau-doctor--log "       TRACE %s: %s" checker trace)))
      (error
       (luau-doctor--log "       TRACE unavailable: %s"
                          (error-message-string err))))))

;;; Checkdoc

(defun luau-doctor--checkdoc-file (file)
  "Run `checkdoc-current-buffer' on FILE and return its diagnostic lines."
  (with-current-buffer (find-file-noselect file)
    (let* ((checkdoc-diagnostic-buffer " *Luau doctor Checkdoc*")
           (checkdoc-pending-errors nil)
           (checkdoc-autofix-flag 'never)
           (checkdoc-generate-compile-warnings-flag t)
           (checkdoc-spellcheck-documentation-flag nil)
           (diagnostics (get-buffer-create checkdoc-diagnostic-buffer)))
      (unwind-protect
          (progn
            (with-current-buffer diagnostics
              (erase-buffer))
            (emacs-lisp-mode)
            (checkdoc-current-buffer t)
            (with-current-buffer diagnostics
              (cl-remove-if-not
               (lambda (line)
                 (string-match-p ":[0-9]+:" line))
               (split-string (buffer-string) "\n" t))))
        (kill-buffer diagnostics)))))

;;; Package Lint

(defun luau-doctor--package-lint-file (file)
  "Run `package-lint-current-buffer' on FILE and return its issues.

Run the requested interactive command for every file, then obtain the
structured issues for concise output and a reliable exit status."
  (with-current-buffer (find-file-noselect file)
    (emacs-lisp-mode)
    (package-lint-current-buffer)
    (package-lint-buffer)))

;;; Complete Project Inspection

(defun luau-doctor--package-lint-available-p ()
  "Return non-nil if the external package-lint checker can be loaded."
  (require 'package-lint nil t))

(defun luau-doctor-run (&optional root checkers)
  "Run CHECKERS on every project Emacs Lisp file under ROOT.

CHECKERS defaults to both `checkdoc' and `package-lint'.  Return
non-nil only if all files were checked and no issue or checker error
occurred.  An absent requested checker is an error, not a skip."
  (let ((selected (or checkers '(checkdoc package-lint))))
    (unless (and selected
                 (cl-every (lambda (checker)
                             (memq checker '(checkdoc package-lint)))
                           selected))
      (user-error "Unknown Luau doctor checker: %S" selected)))
  (let* ((directory (file-name-as-directory
                     (expand-file-name (or root default-directory))))
         (files (luau-doctor-files directory))
         (passed 0)
         (failed 0)
         (total-checkdoc 0)
         (total-lint 0)
         (selected (or checkers '(checkdoc package-lint)))
         (lint-available (or (not (memq 'package-lint selected))
                             (luau-doctor--package-lint-available-p))))
    (luau-doctor--log "")
    (luau-doctor--log "===============================================================")
    (luau-doctor--log " LUAU DOCTOR  |  %s" selected)
    (luau-doctor--log "===============================================================")
    (luau-doctor--log "Project: %s" directory)
    (luau-doctor--log "Files:   %d (all project-owned *.el, recursively)" (length files))
    (luau-doctor--log "Package lint: %d distributed source files; auxiliary Elisp: Checkdoc + compile"
                     (cl-count-if (lambda (file)
                                    (luau-doctor--distributable-p file directory))
                                  files))
    (luau-doctor--log "")
    (dolist (file (if (equal selected '(package-lint))
                      (cl-remove-if-not
                       (lambda (item)
                         (luau-doctor--distributable-p item directory))
                       files)
                    files))
      (let ((name (luau-doctor--relative-name file directory))
            (checkdoc-issues nil)
            (package-issues nil)
            (checker-errors nil))
        (when (memq 'checkdoc selected)
          (condition-case err
              (setq checkdoc-issues (luau-doctor--checkdoc-file file))
            (error
             (luau-doctor--trace "Checkdoc" name err)
             (push (format "Checkdoc crashed: %s" (error-message-string err))
                   checker-errors))))
        (when (and (memq 'package-lint selected)
                   (luau-doctor--distributable-p file directory))
          (if (not lint-available)
              (push "package-lint unavailable; run `make bootstrap'" checker-errors)
            (condition-case err
                (setq package-issues (luau-doctor--package-lint-file file))
              (error
               (luau-doctor--trace "package-lint" name err)
               (push (format "package-lint crashed: %s" (error-message-string err))
                     checker-errors)))))
        (cl-incf total-checkdoc (length checkdoc-issues))
        (cl-incf total-lint (length package-issues))
        (if (or checkdoc-issues package-issues checker-errors)
            (progn
              (cl-incf failed)
              (luau-doctor--log "[FAIL] %s  (%d checkdoc, %d package-lint)"
                                 name (length checkdoc-issues)
                                 (length package-issues))
              (dolist (entry checkdoc-issues)
                (luau-doctor--log "       checkdoc: %s" entry))
              (dolist (entry package-issues)
                (if (and (listp entry) (= (length entry) 4)
                         (integerp (nth 0 entry))
                         (integerp (nth 1 entry)))
                    (luau-doctor--log "       %s:%d:%d: %s: %s"
                                       name (nth 0 entry) (nth 1 entry)
                                       (nth 2 entry) (nth 3 entry))
                  (luau-doctor--log "       package-lint: %S" entry)))
              (dolist (message-text checker-errors)
                (luau-doctor--log "       ERROR: %s" message-text)))
          (cl-incf passed)
          (luau-doctor--log "[ OK ] %s" name))))
    (luau-doctor--log "")
    (luau-doctor--log "---------------------------------------------------------------")
    (luau-doctor--log " Files: %d passed / %d failed | Checkdoc: %d | package-lint: %d"
                       passed failed total-checkdoc total-lint)
    (luau-doctor--log "---------------------------------------------------------------")
    (and files (zerop failed))))

(provide 'luau-doctor)
;;; luau-doctor.el ends here

;; Local Variables:
;; package-lint-main-file: "luau-mode.el"
;; End:
