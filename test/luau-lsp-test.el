;;; luau-lsp-test.el --- Language-server integration tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 laluxx
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Package-Requires: ((emacs "30.1"))
;; Keywords: languages, tools

;;; Commentary:

;; Test optional-client dispatch without needing installed external servers.
;; All language-server process entry points are replaced by local test doubles.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'luau-mode)
(require 'luau-lsp)

;; The tests bind these integrations dynamically even when compiling before
;; the optional lsp-mode and Eglot packages have been loaded.
(defvar lsp-language-id-configuration)
(defvar eglot-server-programs)
(defvar eglot-workspace-configuration)

(ert-deftest luau-lsp-test-default-command-is-upstream-stdio ()
  "Use the official luau-lsp stdio subcommand by default."
  (should (equal luau-lsp-command '("luau-lsp" "lsp"))))

(ert-deftest luau-lsp-test-command-can-be-overridden ()
  "Accept a user-provided executable and additional arguments."
  (let ((luau-lsp-command '("/tmp/my-luau-lsp" "lsp" "--no-flags-enabled"))
        (luau-roblox-api-source 'bundled)
        (luau-roblox-api-definition-override nil))
    (cl-letf (((symbol-function 'file-executable-p)
               (lambda (_file) t)))
      (should (equal (luau-lsp--validated-command) luau-lsp-command)))))

(ert-deftest luau-lsp-test-malformed-command-fails-closed ()
  "Reject empty or malformed programs before starting a server."
  (let ((luau-lsp-command nil))
    (should-error (luau-lsp--validated-command) :type 'user-error))
  (let ((luau-lsp-command '("" "lsp")))
    (should-error (luau-lsp--validated-command) :type 'user-error)))

(ert-deftest luau-lsp-test-automatic-preference ()
  "Favor lsp-mode if installed, otherwise Eglot."
  (let ((luau-lsp-backend 'auto)
        (luau-lsp-prefer-installed-lsp-mode t))
    (cl-letf (((symbol-function 'locate-library)
               (lambda (name) (and (member name '("eglot" "lsp-mode")) name))))
      (should (eq (luau-lsp--preferred-backend) 'lsp-mode))
      (let ((luau-lsp-prefer-installed-lsp-mode nil))
        (should (eq (luau-lsp--preferred-backend) 'eglot))))
    (cl-letf (((symbol-function 'locate-library)
               (lambda (name) (and (equal name "eglot") name))))
      (should (eq (luau-lsp--preferred-backend) 'eglot)))))

(ert-deftest luau-lsp-test-disabled-backend ()
  "Do not connect if the user explicitly disables language services."
  (let ((luau-lsp-backend 'none))
    (should (null (luau-lsp--preferred-backend)))
    (should-error (luau-lsp-ensure) :type 'user-error)))

(ert-deftest luau-lsp-test-does-not-autostart-in-temporary-buffer ()
  "Opening a temporary buffer must not spawn an LSP process."
  (with-temp-buffer
    (let ((luau-lsp-auto-start t)
          (called nil))
      (cl-letf (((symbol-function 'luau-lsp-ensure)
                 (lambda () (setq called t))))
        (luau-mode)
        (should-not called)))))

(ert-deftest luau-lsp-test-does-not-start-both-clients ()
  "Never silently switch away from the currently running LSP client."
  (with-temp-buffer
    (setq-local lsp-mode t)
    (let ((luau-lsp-backend 'eglot))
      (cl-letf (((symbol-function 'locate-library) (lambda (_) "eglot"))
                ((symbol-function 'luau-lsp--validated-command)
                 (lambda () '("luau-lsp" "lsp"))))
        (should-error (luau-lsp-ensure) :type 'user-error)))))

(ert-deftest luau-lsp-test-lsp-mode-registration ()
  "Register a multi-root Luau client with the custom stdio command."
  (let ((lsp-language-id-configuration nil)
        (luau-lsp--registered nil)
        (saved-client nil)
        (saved-settings nil))
    (cl-letf (((symbol-function 'require)
               (let ((original-require (symbol-function 'require)))
                 (lambda (feature &optional filename noerror)
                   (if (eq feature 'lsp-mode) t
                     (funcall original-require feature filename noerror)))))
              ((symbol-function 'lsp-stdio-connection) #'identity)
              ((symbol-function 'lsp-activate-on) #'identity)
              ((symbol-function 'make-lsp-client) #'list)
              ((symbol-function 'lsp-register-client)
               (lambda (client) (setq saved-client client)))
              ((symbol-function 'lsp-register-custom-settings)
               (lambda (settings) (setq saved-settings settings))))
      (luau-lsp--register-lsp-mode)
      (should (member '(luau-mode . "luau") lsp-language-id-configuration))
      (should (eq (plist-get saved-client :server-id) 'luau-lsp-laluxx))
      (should (plist-get saved-client :multi-root))
      (should (functionp (plist-get saved-client :new-connection)))
      (should (assoc "luau-lsp.sourcemap.enabled" saved-settings))
      (let ((previous saved-client))
        (luau-lsp--register-lsp-mode)
        (should (eq previous saved-client))))))

(ert-deftest luau-lsp-test-mode-registers-before-auto-start ()
  "Initialize an installed lsp-mode client before Luau automatic startup."
  (with-temp-buffer
    (let ((sequence nil))
      (cl-letf (((symbol-function 'locate-library)
                 (lambda (name) (and (equal name "lsp-mode") "/mock/lsp-mode.el")))
                ((symbol-function 'luau-lsp--register-lsp-mode)
                 (lambda () (push 'register sequence)))
                ((symbol-function 'luau-lsp-auto-ensure)
                 (lambda () (push 'auto-start sequence))))
        (luau-mode)
        (should (equal (nreverse sequence) '(register auto-start)))))))

(ert-deftest luau-lsp-test-eglot-local-server-command ()
  "Eglot must use the selected program and not change global settings."
  (require 'eglot)
  (let ((global-server-programs (copy-tree (default-value 'eglot-server-programs))))
    (with-temp-buffer
      ;; `setq-local' is required: a dynamically bound special variable
      ;; would change what `default-value' reports while the test runs.
      (setq-local eglot-server-programs '((python-mode . ("pyls"))))
      (let ((started nil)
            (luau-lsp-command '("/tmp/fake-luau-lsp" "lsp"))
            (luau-roblox-api-source 'bundled)
            (luau-roblox-api-definition-override nil))
        (cl-letf (((symbol-function 'file-executable-p) (lambda (_path) t))
                  ((symbol-function 'eglot-ensure)
                   (lambda () (setq started t))))
          (luau-lsp--start-eglot)
          (should started)
          (should (equal (cdar eglot-server-programs)
                         '("/tmp/fake-luau-lsp" "lsp")))
          (should (equal (default-value 'eglot-server-programs)
                         global-server-programs))
          (should (plist-get eglot-workspace-configuration :luau-lsp)))))))

(ert-deftest luau-lsp-test-eglot-workspace-symbol-public-rpc ()
  "Eglot variable navigation must not call Eglot private implementation APIs."
  (require 'eglot)
  (require 'jsonrpc)
  (with-temp-buffer
    (let ((called nil))
      (cl-letf (((symbol-function 'eglot-managed-p) (lambda () t))
                ((symbol-function 'eglot-current-server) (lambda () 'stub-server))
                ((symbol-function 'jsonrpc-request)
                 (lambda (server method params)
                   (should (eq server 'stub-server))
                   (should (eq method :workspace/symbol))
                   (should (equal params '(:query "")))
                   [(:name "foo" :kind 13)]))
                ((symbol-function 'luau-lsp--select-workspace-variable)
                 (lambda (symbols)
                   (setq called symbols))))
        (luau--eglot-project-variables)
        (should (equal called [(:name "foo" :kind 13)]))))))

(ert-deftest luau-lsp-test-project-definition-files ()
  "Resolve labeled API definitions without auto-updating files."
  (let ((file (make-temp-file "luau-defs-" nil ".d.luau")))
    (unwind-protect
        (let ((luau-lsp-extra-definition-files (list (cons "custom" file)))
              (luau-lsp-command '("/tmp/luau-lsp" "lsp"))
              (luau-roblox-api-source 'bundled)
              (luau-roblox-api-definition-override nil))
          (cl-letf (((symbol-function 'file-executable-p) (lambda (_p) t)))
            (should (equal (luau-lsp--validated-command)
                           (list "/tmp/luau-lsp" "lsp"
                                 (concat "--definitions:@custom=" file))))))
      (delete-file file))))

(ert-deftest luau-lsp-test-static-workspace-symbols ()
  "Only navigate source variable kinds returned by the server."
  (let* ((symbol (let ((s (make-hash-table :test 'equal))
                       (loc (make-hash-table :test 'equal))
                       (range (make-hash-table :test 'equal))
                       (start (make-hash-table :test 'equal)))
                   (puthash :name "velocity" s)
                   (puthash :kind 13 s)
                   (puthash :line 5 start)
                   (puthash :character 3 start)
                   (puthash :start start range)
                   (puthash :range range loc)
                   (puthash :uri "file:///tmp/velocity.luau" loc)
                   (puthash :location loc s)
                   s))
         (target nil))
    (with-temp-buffer
      (setq-local lsp-mode t)
      (cl-letf (((symbol-function 'lsp-request)
                 (lambda (_method _params) (vector symbol)))
                ((symbol-function 'completing-read)
                 (lambda (_prompt candidates &rest _args)
                   (caar candidates)))
                ((symbol-function 'luau--lsp-position)
                 (lambda (path line character)
                   (setq target (list path line character)))))
        (luau-lsp-workspace-variables)
        (should (equal target '("/tmp/velocity.luau" 5 3)))))))

(ert-deftest luau-lsp-test-show-doc-prefers-ui-if-available ()
  "Display documentation with lsp-ui when available without global keys."
  (with-temp-buffer
    (setq-local lsp-mode t)
    (let ((showed nil))
      (cl-letf (((symbol-function 'require) (lambda (&rest _) t))
                ((symbol-function 'lsp-ui-doc-show)
                 (lambda () (setq showed t))))
        (luau-lsp-show-doc)
        (should showed)))))

(provide 'luau-lsp-test)
;;; luau-lsp-test.el ends here

;; Local Variables:
;; package-lint-main-file: "luau-mode.el"
;; End:
