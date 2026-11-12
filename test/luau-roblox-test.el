;;; luau-roblox-test.el --- Roblox API integration tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 laluxx
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "31.1"))
;; Keywords: languages, tools

;;; Commentary:

;; Test explicit Roblox asset selection and safe caching without network I/O.
;; No Roblox Studio or running language server is required for these tests.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'luau-mode)
(require 'luau-roblox)
(require 'luau-lsp)
(require 'url)

(defun luau-roblox-test--response (payload &optional status)
  "Return a fake HTTP buffer containing PAYLOAD and optional STATUS."
  (let ((buffer (generate-new-buffer " *Luau mock Roblox API*")))
    (with-current-buffer buffer
      (setq-local url-http-response-status (or status 200))
      (insert "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n")
      (insert payload))
    buffer))

(defconst luau-roblox-test--declarations
  (concat "-- Roblox API test definition fixture\n"
          "declare extern type Vector3 with\n"
          "\tMagnitude: number\n"
          "end\n"
          "declare Other: {\n"
          "\tnew: (number) -> Other,\n"
          "}\n"
          "declare Vector3: {\n"
          "\tzero: Vector3,\n"
          "\tnew: (number, number, number) -> Vector3,\n"
          "}\n"
          "export type Camera = {CFrame: CFrame}\n"))

(defconst luau-roblox-test--documentation
  "{\"Camera\": {\"description\": \"A generated documentation fixture\", \"members\": [\"CFrame\"]}}")

(ert-deftest luau-roblox-test-library-is-readable ()
  "Ensure the Roblox library is readable by Emacs syntax scanners."
  (with-temp-buffer
    (let ((library (locate-library "luau-roblox")))
      (should library)
      (insert-file-contents (expand-file-name
                             "luau-roblox.el"
                             (file-name-directory library))))
    (check-parens)))

(ert-deftest luau-roblox-test-status-command-is-available ()
  "The Roblox API status command must be available to Luau buffers."
  (should (commandp 'luau-roblox-api-status))
  (should (eq (lookup-key luau-mode-map (kbd "C-c C-u"))
              'luau-roblox-api-status)))

(ert-deftest luau-roblox-test-definition-navigates-api-symbol-and-member ()
  "Definition navigation targets the Roblox API type or exact member."
  (let* ((luau-roblox-api-source 'cached)
         (luau-roblox-api-definition-override nil)
         (luau-roblox-api-cache-directory
          (make-temp-file "luau-api-definition-test-" t))
         (definition (luau-roblox-api-definition-path))
         (source (generate-new-buffer " *Luau API definition source*")))
    (unwind-protect
        (progn
          (with-temp-file definition
            (insert luau-roblox-test--declarations))
          (with-current-buffer source
            (insert "local value = Vector3.new(1, 2, 3)\n")
            (luau-mode))
          (dolist (case '(("Vector3" . "declare extern type Vector3 with")
                          ("new" . "\tnew:")))
            (with-current-buffer source
              (goto-char (point-min))
              (search-forward (car case))
              (backward-word)
              (luau-roblox-find-definition)
              (should (equal (buffer-file-name) definition))
              (should (looking-at (regexp-quote (cdr case)))))))
      (when (buffer-live-p source) (kill-buffer source))
      (when-let* ((api-buffer (get-file-buffer definition)))
        (kill-buffer api-buffer))
      (delete-directory luau-roblox-api-cache-directory t))))

(ert-deftest luau-roblox-test-mode-never-downloads ()
  "Opening a Luau buffer must never contact the Roblox API endpoint."
  (with-temp-buffer
    (cl-letf (((symbol-function 'url-retrieve-synchronously)
               (lambda (&rest _) (ert-fail "Unexpected network activity"))))
      (luau-mode)
      (should (eq major-mode 'luau-mode)))))

(ert-deftest luau-roblox-test-server-bundled-by-default ()
  "Bundled Roblox types should not introduce additional CLI arguments."
  (let ((luau-roblox-api-source 'bundled)
        (luau-roblox-api-definition-override nil)
        (luau-roblox-api-documentation-override nil))
    (should (null (luau-roblox-api-arguments)))))

(ert-deftest luau-roblox-test-cached-is-fail-closed ()
  "Require a valid local file in cached-only mode."
  (let ((luau-roblox-api-source 'cached)
        (luau-roblox-api-definition-override nil)
        (luau-roblox-api-cache-directory (make-temp-file "luau-empty-api-" t)))
    (unwind-protect
        (should-error (luau-roblox-api-arguments) :type 'user-error)
      (delete-directory luau-roblox-api-cache-directory t))))

(ert-deftest luau-roblox-test-cache-arguments-and-documentation ()
  "Include cached Roblox API files in the actual LSP stdio invocation."
  (let ((luau-roblox-api-source 'cached)
        (luau-roblox-api-definition-override nil)
        (luau-roblox-api-documentation-override nil)
        (luau-roblox-api-security "None")
        (luau-roblox-api-cache-directory (make-temp-file "luau-api-test-" t))
        (luau-roblox-api-use-documentation t)
        (luau-lsp-command '("/tmp/fake-luau-lsp" "lsp")))
    (unwind-protect
        (progn
          (with-temp-file (luau-roblox-api-definition-path)
            (insert luau-roblox-test--declarations))
          (with-temp-file (luau-roblox-api-documentation-path)
            (insert luau-roblox-test--documentation))
          (cl-letf (((symbol-function 'file-executable-p) (lambda (_) t)))
            (should (equal (luau-lsp--validated-command)
                           (list "/tmp/fake-luau-lsp" "lsp"
                                 (concat "--definitions:@roblox="
                                         (luau-roblox-api-definition-path))
                                 (concat "--docs="
                                         (luau-roblox-api-documentation-path)))))))
      (delete-directory luau-roblox-api-cache-directory t))))

(ert-deftest luau-roblox-test-invalid-definition-override ()
  "Reject a missing explicit declaration file instead of hiding errors."
  (let ((luau-roblox-api-definition-override
         (expand-file-name "missing-definition.d.luau" temporary-file-directory)))
    (should-error (luau-roblox-api-arguments) :type 'user-error)))

(ert-deftest luau-roblox-test-install-is-explicit-and-atomic ()
  "Download assets only on request and write validated content atomically."
  (let ((luau-roblox-api-cache-directory (make-temp-file "luau-api-test-" t))
        (luau-roblox-api-security "None")
        (luau-roblox-api-use-documentation t)
        (fetches nil))
    (unwind-protect
        (cl-letf (((symbol-function 'url-retrieve-synchronously)
                   (lambda (url &rest _)
                     (push url fetches)
                     (luau-roblox-test--response
                      (if (string-suffix-p ".json" url)
                          luau-roblox-test--documentation
                        luau-roblox-test--declarations)))))
          (luau-roblox-api-install)
          (should (= (length fetches) 2))
          (should (luau-roblox--valid-file-p
                   (luau-roblox-api-definition-path)))
          (should (luau-roblox--valid-file-p
                   (luau-roblox-api-documentation-path)))
          (should-not (directory-files
                       luau-roblox-api-cache-directory nil
                       "\\`\\.api-download-")))
      (delete-directory luau-roblox-api-cache-directory t))))

(ert-deftest luau-roblox-test-download-failure-keeps-old-file ()
  "A malformed remote response must not replace cached declarations."
  (let* ((luau-roblox-api-cache-directory (make-temp-file "luau-api-test-" t))
         (destination (luau-roblox-api-definition-path)))
    (unwind-protect
        (progn
          (with-temp-file destination
            (insert luau-roblox-test--declarations))
          (cl-letf (((symbol-function 'url-retrieve-synchronously)
                     (lambda (&rest _) (luau-roblox-test--response
                                          (make-string 100 ?x)))))
            (should-error
             (luau-roblox--download-asset "https://example.test/malformed"
                                         destination 'definitions)
             :type 'user-error))
          (with-temp-buffer
            (insert-file-contents destination)
            (should (equal (buffer-string)
                           luau-roblox-test--declarations))))
      (delete-directory luau-roblox-api-cache-directory t))))

(ert-deftest luau-roblox-test-http-errors-do-not-replace-files ()
  "A non-successful HTTP status must not overwrite local cache files."
  (let* ((luau-roblox-api-cache-directory (make-temp-file "luau-api-test-" t))
         (destination (luau-roblox-api-definition-path)))
    (unwind-protect
        (progn
          (with-temp-file destination (insert "original"))
          (cl-letf (((symbol-function 'url-retrieve-synchronously)
                     (lambda (&rest _)
                       (luau-roblox-test--response
                        luau-roblox-test--declarations 503))))
            (should-error
             (luau-roblox--download-asset "https://example.test/err"
                                         destination 'definitions)
             :type 'user-error))
          (with-temp-buffer
            (insert-file-contents destination)
            (should (equal (buffer-string) "original"))))
      (delete-directory luau-roblox-api-cache-directory t))))

(ert-deftest luau-roblox-test-explicit-definitions-avoid-duplicate-pinned-api ()
  "Prefer a selected Roblox API over checkout-pinned engine declarations."
  (let ((luau-lsp-use-pinned-types t)
        (luau-roblox-api-source 'cached)
        (luau-roblox-api-definition-override nil)
        (luau-roblox-api-cache-directory (make-temp-file "luau-api-test-" t)))
    (unwind-protect
        (progn
          (with-temp-file (luau-roblox-api-definition-path)
            (insert luau-roblox-test--declarations))
          (cl-letf (((symbol-function 'luau--project-root)
                     (lambda (&rest _) "/fake/root/"))
                    ((symbol-function 'luau--find-api-types)
                     (lambda (&rest _) "/fake/root/build/api.d.luau")))
            (should-not (seq-some
                         (lambda (arg)
                           (string-prefix-p "--definitions:@pinned=" arg))
                         (luau-lsp--definitions)))))
      (delete-directory luau-roblox-api-cache-directory t))))

(provide 'luau-roblox-test)
;;; luau-roblox-test.el ends here

;; Local Variables:
;; package-lint-main-file: "luau-mode.el"
;; End:
