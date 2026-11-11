;;; luau-interface-test.el --- Structural UI regression tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 laluxx
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: laluxx
;; Keywords: languages, tools

;;; Commentary:

;; Isolated tests for cached Imenu, local Eldoc, live-reference dispatch,
;; keyword matching, key bindings, and LSP command loading behavior.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'luau-mode)
(require 'luau-interface)
(require 'luau-roblox)
(require 'luau-lsp)

(ert-deftest luau-interface-test-navigation-and-keymaps ()
  "Enable navigation, Roblox documentation and source-symbol key bindings."
  (with-temp-buffer
    (luau-mode)
    (should (eq imenu-create-index-function
                #'luau-interface-imenu-create-index))
    (should (memq #'luau-interface-eldoc eldoc-documentation-functions))
    (should (memq #'luau-interface--refresh-match post-command-hook))
    (should (eq (lookup-key luau-mode-map (kbd "C-c C-j")) #'luau-imenu))
    (should (eq (lookup-key luau-mode-map (kbd "C-c C-o"))
                #'luau-roblox-doc-at-point))
    (should (eq (lookup-key luau-mode-map (kbd "C-h v"))
                #'luau-project-variables))))

(ert-deftest luau-interface-test-imenu-index-source-order ()
  "Index named functions, types and requires in source order."
  (with-temp-buffer
    (insert "--- Greets a player\n"
            "local function greet(name: string, count: number): boolean\n"
            "  return count > 0\n"
            "end\n"
            "export type CameraState = {focus: Vector3}\n"
            "local Signal = require(script.Signal)\n")
    (luau-mode)
    (let ((entries (luau-interface--entries)))
      (should (equal (mapcar #'car entries)
                     '("greet" "CameraState" "Signal")))
      (should (equal (nth 2 (car entries)) 'function))
      (should (string-match-p "count: number" (nth 3 (car entries))))
      (should (equal (nth 4 (car entries)) "Greets a player"))
      (should (markerp (nth 1 (car entries))))
      (should (= (length (luau-interface-imenu-create-index)) 3)))))

(ert-deftest luau-interface-test-imenu-cache-invalidates ()
  "Source edits rebuild indexed entries without leaving stale results."
  (with-temp-buffer
    (insert "function first()\nend\n")
    (luau-mode)
    (should (equal (mapcar #'car (luau-interface--entries)) '("first")))
    (goto-char (point-max))
    (insert "function second()\nend\n")
    (should (equal (mapcar #'car (luau-interface--entries))
                   '("first" "second")))))

(ert-deftest luau-interface-test-annotated-imenu ()
  "Imenu annotations carry a signature, docs and semantic faces."
  (with-temp-buffer
    (insert "--- Moves an actor\nfunction move(to: Vector3): boolean\nend\n")
    (luau-mode)
    (let* ((luau-interface--completion-buffer (current-buffer))
           (annotation (luau-interface-imenu-annotate "move")))
      (should (string-match-p "function" annotation))
      (should (string-match-p "Moves an actor" annotation))
      (should (string-match-p "to: Vector3" annotation))
      (should (text-property-any 0 (length annotation) 'face
                                 'luau-interface-imenu-doc-face annotation)))))

(ert-deftest luau-interface-test-eldoc-active-parameter ()
  "Show the current function argument with its own region-inherited face."
  (with-temp-buffer
    (insert "local function transform(first: number, second: Vector3)\nend\n"
            "transform(1, Vector3.new(0, 1, 2))\n")
    (luau-mode)
    (goto-char (point-max))
    (search-backward "Vector3.new")
    (let ((doc (luau-interface--local-eldoc)))
      (should (string-match-p "transform" doc))
      (should (string-match-p "second: Vector3" doc))
      (should (text-property-any 0 (length doc) 'face
                                 'luau-interface-eldoc-active-face doc)))))

(ert-deftest luau-interface-test-matching-keyword-pairs ()
  "Match nested block openers and terminators without confusing nesting."
  (with-temp-buffer
    (insert "function greet()\n"
            "  if true then\n"
            "    warn('ok')\n"
            "  end\n"
            "end\n"
            "repeat\n"
            "  task.wait()\n"
            "until true\n")
    (luau-mode)
    (goto-char (point-min))
    (let ((function-pos (point)))
      (should (equal (luau-interface--keyword-pair function-pos)
                     (list function-pos
                           (save-excursion
                             (search-forward "end" nil t 2)
                             (- (point) 3))))))
    (goto-char (point-min))
    (search-forward "repeat")
    (let* ((repeat-pos (- (point) (length "repeat")))
           (pair (luau-interface--keyword-pair repeat-pos)))
      (should (equal (car pair) repeat-pos))
      (should (equal (save-excursion
                       (goto-char (cadr pair))
                       (buffer-substring-no-properties (point) (+ (point) 5)))
                     "until")))))

(ert-deftest luau-interface-test-branch-keyword-matching ()
  "Highlight the matching end from an if/else keyword or a loop do."
  (with-temp-buffer
    (insert "if true then\n  warn('yes')\nelse\n  warn('no')\nend\n")
    (luau-mode)
    (goto-char (point-min))
    (search-forward "else")
    (let* ((branch (- (point) 4))
           (pair (luau-interface--keyword-pair branch)))
      (should (= (car pair) branch))
      (should (equal (save-excursion
                       (goto-char (cadr pair))
                       (buffer-substring-no-properties (point) (+ (point) 3)))
                     "end")))))

(ert-deftest luau-interface-test-matching-face-and-cleanup ()
  "Keyword overlays use region faces and are removed with the mode."
  (with-temp-buffer
    (insert "function a()\nend\n")
    (luau-mode)
    (goto-char (point-min))
    (luau-interface--refresh-match)
    (should (= (length luau-interface--match-overlays) 2))
    (should (eq (face-attribute 'luau-interface-match-face :inherit nil t)
                'region))
    (luau-interface--teardown)
    (should-not luau-interface--match-overlays)))

(ert-deftest luau-interface-test-roblox-reference-urls ()
  "Use supported official Creator Hub reference routes."
  (should (equal (luau-roblox-docs--reference "Vector3" "datatypes")
                 "https://create.roblox.com/docs/reference/engine/datatypes/Vector3"))
  (should (equal (luau-roblox-docs--reference "workspace" "classes")
                 "https://create.roblox.com/docs/reference/engine/classes/Workspace"))
  (should-error (luau-roblox-docs--reference "../../unsafe" "classes")
                :type 'user-error))

(ert-deftest luau-interface-test-documentation-is-explicit ()
  "Only the explicit browser command opens an external documentation page."
  (with-temp-buffer
    (insert "local p = Vector3.new(1, 2, 3)\n")
    (let* ((opened nil)
           (luau-roblox-docs-browser (lambda (url) (setq opened url))))
      (luau-mode)
      (should-not opened)
      (goto-char (point-min))
      (search-forward "Vector3")
      (backward-word)
      (luau-roblox-doc-at-point)
      (should (string-suffix-p "/datatypes/Vector3" opened)))))

(ert-deftest luau-interface-test-roblox-command-available ()
  "Use the API argument function even after editor modules are loaded."
  (let ((luau-roblox-api-source 'bundled)
        (luau-roblox-api-definition-override nil))
    (should (fboundp 'luau-roblox-api-arguments))
    (should-not (luau-lsp--roblox-arguments))))

(provide 'luau-interface-test)
;;; luau-interface-test.el ends here

;; Local Variables:
;; package-lint-main-file: "luau-mode.el"
;; End:
