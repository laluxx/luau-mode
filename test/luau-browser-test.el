;;; luau-browser-test.el --- Native reference UI tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Luau contributors
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: Luau contributors
;; Keywords: languages, tools

;;; Commentary:

;; Offline fixture tests for reference discovery, UI navigation, completion,
;; cache invalidation, native rendering and conservative enum validation.

;;; Code:

(require 'ert)
(require 'luau-mode)
(require 'luau-browser)
(require 'luau-roblox)

(defmacro luau-browser-test--fixture (&rest body)
  "Execute BODY in an isolated Creator Docs fixture checkout."
  (declare (indent 0) (debug t))
  `(let* ((root (make-temp-file "luau-browser-test-" t))
          (luau-browser-assets-root root)
          (luau-browser--root nil)
          (luau-browser--index nil)
          (luau-browser--stamp nil)
          (enum (expand-file-name
                 "roblox-creator-docs/content/en-us/reference/engine/enums/Material.yaml"
                 root))
          (datatype (expand-file-name
                     "roblox-creator-docs/content/en-us/reference/engine/datatypes/Vector3.md"
                     root)))
     (unwind-protect
         (progn
           (make-directory (file-name-directory enum) t)
           (make-directory (file-name-directory datatype) t)
           (with-temp-file enum
             (insert "name: Material\nsummary: Available materials\nitems:\n"
                     "  - name: Grass\n  - name: Plastic\n"))
           (with-temp-file datatype
             (insert "# Vector3\n\nA 3D vector.\n\n## Methods\n\nCross\n"))
           ,@body)
       (delete-directory root t))))

(ert-deftest luau-browser-test-index-and-refresh ()
  "Local references are discovered and cache invalidation is explicit."
  (luau-browser-test--fixture
    (should (= (length (luau-browser-refresh)) 2))
    (should (equal (mapcar #'cadr (luau-browser--entries))
                   '("Material" "Vector3")))
    (should (equal (car (car (luau-browser--entries))) "enums"))
    (let ((cache luau-browser--index))
      (should (eq (luau-browser--entries) cache)))
    (should (= (length (luau-browser--rows)) 2))))

(ert-deftest luau-browser-test-completion-metadata ()
  "Standard completion exposes affixation to Consult and Vertico."
  (luau-browser-test--fixture
    (let* ((entry (car (luau-browser-refresh)))
           (candidate (luau-browser--candidate entry))
           (table (luau-browser--completion-table (list entry)))
           (metadata (funcall table "" nil 'metadata)))
      (should (equal (get-text-property 0 'luau-browser-entry candidate) entry))
      (should (eq (cdr (assq 'category (cdr metadata))) 'luau-roblox-api))
      (should (string-match-p "Available materials"
                              (luau-browser--annotate candidate)))
      (should (= (length (luau-browser--affixate (list candidate))) 1)))))

(ert-deftest luau-browser-test-native-document ()
  "Native document rendering uses local Markdown without EWW."
  (luau-browser-test--fixture
    (let ((entry (cadr (luau-browser-refresh))))
      (with-temp-buffer
        (luau-browser-document-mode)
        (luau-browser--render entry)
        (should (string-match-p "Vector3" (buffer-string)))
        (should (string-match-p "Methods" (buffer-string)))
        (should buffer-read-only)))))

(ert-deftest luau-browser-test-enum-capf ()
  "Recognized enum members are completed without LSP dependency."
  (luau-browser-test--fixture
    (luau-browser-refresh)
    (with-temp-buffer
      (insert "Enum.Material.Gra")
      (let ((capf (luau-browser-capf)))
        (should capf)
        (should (member "Grass" (all-completions "" (nth 2 capf))))
        (should (eq (completion-metadata-get
                     (completion-metadata "" (nth 2 capf) nil) 'category)
                    'luau-roblox-api))
        (should (= (nth 0 capf) (- (point) 3)))))))

(ert-deftest luau-browser-test-enum-lint ()
  "Unknown members are diagnosed; valid and unknown types are ignored."
  (luau-browser-test--fixture
    (luau-browser-refresh)
    (with-temp-buffer
      (insert "local a = Enum.Material.Grass\n"
              "local b = Enum.Material.Unreal\n"
              "local c = Enum.NotIndexed.Unreal\n")
      (luau-mode)
      (let (result)
        (luau-browser-flymake (lambda (diagnostics &rest _) (setq result diagnostics)))
        (should (= (length result) 1))
        (should (string-match-p "Unreal"
                                (flymake-diagnostic-text (car result))))))))

(ert-deftest luau-browser-test-mode-local-keymap ()
  "Browser and document keys do not leak into global maps."
  (should (eq (lookup-key luau-browser-mode-map (kbd "RET"))
              #'luau-browser-visit))
  (should (eq (lookup-key luau-browser-mode-map (kbd "/"))
              #'luau-browser-search))
  (should (eq (lookup-key luau-browser-document-mode-map (kbd "b"))
              #'luau-browser)))

(ert-deftest luau-browser-test-yaml-canonical-with-markdown-companion ()
  "YAML structure and Markdown content must form one API entry."
  (luau-browser-test--fixture
    (let* ((yaml (expand-file-name
                  "roblox-creator-docs/content/en-us/reference/engine/datatypes/Vector3.yaml"
                  root)))
      (with-temp-file yaml
        (insert "name: Vector3\nsummary: |\n  Three-dimensional vectors\n"
                "methods:\n- name: Vector3.Cross\n"
                "properties:\n- name: Vector3.Magnitude\n"))
      (let* ((entries (luau-browser-refresh))
             (entry (cl-find "Vector3" entries :key #'cadr :test #'equal)))
        (should (= (length entries) 2))
        (should (equal (nth 2 entry) yaml))
        (should (string-match-p "Three-dimensional vectors" (nth 3 entry)))
        (should (file-equal-p
                 (luau-browser--companion-markdown yaml)
                 datatype))
        (with-temp-buffer
          (luau-browser-document-mode)
          (luau-browser--render entry)
          (should (string-match-p "Cross" (buffer-string)))
          (should (string-match-p "Magnitude" (buffer-string)))
          (should (string-match-p "A 3D vector" (buffer-string))))))))

(ert-deftest luau-browser-test-custom-root-reloads-entries ()
  "Switching asset root never silently retains an unrelated index."
  (luau-browser-test--fixture
    (should (= (length (luau-browser--entries)) 2))
    (let ((luau-browser-assets-root (make-temp-file "luau-empty-" t)))
      (unwind-protect
          (should-not (luau-browser--entries))
        (delete-directory luau-browser-assets-root t)))
    (should (= (length (luau-browser--entries)) 2))))

(ert-deftest luau-browser-test-members-cache-refresh ()
  "Index refresh must invalidate cached enum declarations."
  (luau-browser-test--fixture
    (let ((entry (car (luau-browser-refresh))))
      (should (member "Grass" (luau-browser--enum-members entry)))
      (with-temp-file enum
        (insert "name: Material\nitems:\n  - name: NewMaterial\n"))
      (luau-browser-refresh)
      (should (equal (luau-browser--enum-members
                      (car (luau-browser--entries))) '("NewMaterial"))))))

(ert-deftest luau-browser-test-navigation-keymaps ()
  "Source, copy, help and motion keys are mode-local."
  (should (eq (lookup-key luau-browser-mode-map (kbd "c"))
              #'luau-browser-copy-name))
  (should (eq (lookup-key luau-browser-mode-map (kbd "C"))
              #'luau-browser-copy-qualified-name))
  (should (eq (lookup-key luau-browser-mode-map (kbd "j")) #'next-line))
  (should (eq (lookup-key luau-browser-document-mode-map (kbd "v"))
              #'luau-browser-view-source)))

(ert-deftest luau-browser-test-flymake-multi-diagnostic-progress ()
  "Multiple enum references terminate and produce accurate non-overlapping warnings."
  (luau-browser-test--fixture
    (luau-browser-refresh)
    (with-temp-buffer
      (insert "local a = Enum.Material.Grass\n"
              "local b = Enum.Material.NotMaterial\n"
              "local c = Enum.Material.MissingToo\n"
              "-- Enum.Material.InComment\n"
              "local s = \"Enum.Material.InString\"\n")
      (luau-mode)
      (let (result)
        (luau-browser-flymake (lambda (diagnostics &rest _)
                                (setq result diagnostics)))
        (should (= (length result) 2))
        (should (equal (mapcar (lambda (diagnostic)
                                 (string-trim-left (flymake-diagnostic-text diagnostic)))
                               result)
                       '("Unknown Enum.Material.NotMaterial in local Roblox API"
                         "Unknown Enum.Material.MissingToo in local Roblox API")))
        (should (string= (buffer-substring-no-properties
                          (flymake-diagnostic-beg (car result))
                          (flymake-diagnostic-end (car result)))
                         "NotMaterial"))))))

(ert-deftest luau-browser-test-flymake-preserves-point ()
  "Flymake enum scanning does not change the editing point."
  (luau-browser-test--fixture
    (luau-browser-refresh)
    (with-temp-buffer
      (luau-mode)
      (insert "Enum.Material.NotMaterial Enum.Material.Grass")
      (goto-char 7)
      (let ((before (point)) result)
        (luau-browser-flymake (lambda (diagnostics &rest _)
                                (setq result diagnostics)))
        (should (= before (point)))
        (should (= (length result) 1))))))

(ert-deftest luau-browser-test-local-document-preferred-over-eww ()
  "Known local documentation opens natively even with online fallback enabled."
  (luau-browser-test--fixture
    (luau-browser-refresh)
    (with-temp-buffer
      (insert "Vector3")
      (goto-char (point-min))
      (let (opened)
        (cl-letf (((symbol-function 'luau-browser-open)
                   (lambda (entry) (setq opened entry)))
                  ((symbol-function 'luau-roblox-doc-at-point)
                   (lambda (&optional _name)
                     (ert-fail "EWW unexpectedly called"))))
          (luau-browser-at-point))
        (should (equal (nth 1 opened) "Vector3"))))))

(ert-deftest luau-browser-test-online-fallback-when-local-missing ()
  "Missing local documentation dispatches to the existing live browser."
  (luau-browser-test--fixture
    (luau-browser-refresh)
    (with-temp-buffer
      (insert "Camera")
      (goto-char (point-min))
      (let (visited)
        (cl-letf (((symbol-function 'luau-roblox-doc-at-point)
                   (lambda (&optional name) (setq visited name))))
          (luau-browser-at-point))
        (should (equal visited "Camera"))))))

(ert-deftest luau-browser-test-online-fallback-is-configurable ()
  "Opting out of live fallback rejects missing local documentation."
  (luau-browser-test--fixture
    (let ((luau-browser-online-fallback nil))
      (with-temp-buffer
        (insert "Camera")
        (goto-char (point-min))
        (should-error (luau-browser-at-point) :type 'user-error)))))

(ert-deftest luau-browser-test-online-when-markdown-missing ()
  "A YAML schema without companion Markdown uses EWW for documentation."
  (luau-browser-test--fixture
    (let* ((entry (car (luau-browser-refresh)))
           visited
           (luau-roblox-docs-browser (lambda (url) (setq visited url))))
      (should (file-readable-p (nth 2 entry)))
      (should-not (luau-browser--documentation-file entry))
      (luau-browser-open entry)
      (should (string-match-p "/enums/Material\\'" visited)))))

(ert-deftest luau-browser-test-online-when-source-removed ()
  "A disappearing local page gracefully falls back to its known category."
  (luau-browser-test--fixture
    (let* ((entry (cadr (luau-browser-refresh)))
           visited
           (luau-roblox-docs-browser (lambda (url) (setq visited url))))
      (delete-file datatype)
      (luau-browser-open entry)
      (should (string-match-p "/datatypes/Vector3\\'" visited)))))

(ert-deftest luau-browser-test-completion-groups-by-api-kind ()
  "Native completion metadata groups records and retains semantic affixes."
  (luau-browser-test--fixture
    (let* ((entries (luau-browser-refresh))
           (candidate (luau-browser--candidate (car entries)))
           (table (luau-browser--completion-table entries))
           (metadata (completion-metadata "" table nil))
           (group (completion-metadata-get metadata 'group-function)))
      (should (functionp group))
      (should (equal (funcall group candidate nil) "Enums"))
      (should (equal (funcall group candidate t) candidate)))))

(ert-deftest luau-browser-test-corfu-is-buffer-local ()
  "Install a Roblox-only Corfu formatter without changing global completion."
  (let ((before (default-value 'corfu-margin-formatters)))
    (with-temp-buffer
      (let ((luau-browser-enable-corfu-icons t))
        (luau-browser-setup)
        (should (local-variable-p 'corfu-margin-formatters))
        (should (eq (car corfu-margin-formatters)
                    #'luau-browser-corfu-margin-formatter))))
    (should (equal (default-value 'corfu-margin-formatters) before))))

(ert-deftest luau-browser-test-corfu-icon-protocol ()
  "Corfu's public formatter gets a three-column icon only for our category."
  (luau-browser-test--fixture
    (let* ((entry (car (luau-browser-refresh)))
           (formatter (luau-browser-corfu-margin-formatter
                       (completion-metadata
                        "" (luau-browser--capf-table '("Grass") "enums") nil))))
      (should (functionp formatter))
      (should (= (length (funcall formatter "Grass")) 3))
      (should-not (luau-browser-corfu-margin-formatter
                   '(metadata (category . file))))
      (should (equal (nth 1 entry) "Material")))))

(ert-deftest luau-browser-test-capf-enum-type-and-doc-preview ()
  "Complete partially entered enum types and expose a native preview."
  (luau-browser-test--fixture
    (luau-browser-refresh)
    (with-temp-buffer
      (insert "Enum.Mat")
      (let* ((capf (luau-browser-capf))
             (table (nth 2 capf))
             (docs (plist-get (nthcdr 3 capf) :company-doc-buffer))
             (preview (funcall docs "Material")))
        (should capf)
        (should (equal (all-completions "Mat" table) '("Material")))
        (should (buffer-live-p preview))
        (with-current-buffer preview
          (should (string-match-p "Available materials" (buffer-string))))
        (kill-buffer preview)))))

(ert-deftest luau-browser-test-document-outline-keymaps ()
  "Documentation has usable outline, online and jump navigation keys."
  (should (eq (lookup-key luau-browser-document-mode-map (kbd "TAB"))
              #'forward-button))
  (should (eq (lookup-key luau-browser-document-mode-map (kbd "W"))
              #'luau-browser-open-online))
  (should (eq (lookup-key luau-browser-document-mode-map (kbd "i"))
              #'luau-browser-document-jump-heading))
  (should (eq (lookup-key luau-browser-mode-map (kbd "f"))
              #'luau-browser-filter-kind)))

(ert-deftest luau-browser-test-browser-kind-filter ()
  "The Dired-style list narrows by API kind and restores all entries."
  (luau-browser-test--fixture
    (luau-browser-refresh)
    (with-temp-buffer
      (luau-browser-mode)
      (setq-local luau-browser--kind-filter "enums")
      (should (= (length (luau-browser--rows)) 1))
      (luau-browser-clear-filter)
      (should (= (length (luau-browser--rows)) 2)))))

(ert-deftest luau-browser-test-markdown-native-code-styling ()
  "Local Markdown retains native code styling without showing fence markers."
  (luau-browser-test--fixture
    (with-temp-file datatype
      (insert "# Vector3\n\nUse `Vector3.new` to construct.\n"
              "```luau\nlocal vector = Vector3.new()\n```\n"))
    (with-temp-buffer
      (luau-browser-document-mode)
      (luau-browser--render (cadr (luau-browser-refresh)))
      (should-not (string-match-p "```" (buffer-string)))
      (goto-char (point-min))
      (should (search-forward "Vector3.new" nil t))
      (should (eq (get-text-property (1- (point)) 'face)
                  'luau-browser-inline-code-face))
      (should (search-forward "local vector" nil t))
      (should (eq (get-text-property (1- (point)) 'face)
                  'luau-browser-code-block-face)))))

(ert-deftest luau-browser-test-member-parser-realistic-yaml ()
  "Only direct engine API members are indexed, with typed signatures."
  (luau-browser-test--fixture
    (let ((yaml (expand-file-name
                 "roblox-creator-docs/content/en-us/reference/engine/datatypes/Vector3.yaml"
                 root)))
      (with-temp-file yaml
        (insert "name: Vector3\nsummary: |\n  3D vector\n"
                "constructors:\n"
                "  - name: Vector3.new\n"
                "    summary: |\n      Construct a new vector.\n"
                "    parameters:\n"
                "      - name: x\n        type: number\n"
                "      - name: y\n        type: number\n"
                "    returns:\n      - type: Vector3\n"
                "properties:\n"
                "  - name: Vector3.Magnitude\n    type: number\n"
                "    summary: |\n      Vector length.\n"
                "methods:\n"
                "  - name: Vector3:Cross\n"
                "    parameters:\n"
                "      - name: other\n        type: Vector3\n"
                "    returns:\n      - type: Vector3\n"
                "    tags:\n      - Deprecated\n"))
      (let* ((entry (cl-find "Vector3" (luau-browser-refresh)
                             :test #'equal :key #'cadr))
             (members (luau-browser--members entry)))
        (should (equal (mapcar #'luau-browser-member-name members)
                       '("Vector3.new" "Vector3.Magnitude" "Vector3:Cross")))
        (should (equal (mapcar #'luau-browser-member-kind members)
                       '("constructors" "properties" "methods")))
        (should (equal (luau-browser--member-signature (car members))
                       "(x: number, y: number) → Vector3"))
        (should (equal (luau-browser--member-signature (cadr members))
                       ": number"))
        (should (string-match-p "Construct a new vector"
                                (luau-browser-member-summary (car members))))
        (should (luau-browser-member-deprecated (nth 2 members)))
        (should (equal (mapcar #'car (luau-browser--yaml-sections entry))
                       '("Constructors" "Properties" "Methods")))))))

(ert-deftest luau-browser-test-member-index-cache-and-refresh ()
  "Cached member records are reused and cleared by an explicit refresh."
  (luau-browser-test--fixture
    (let* ((entry (car (luau-browser-refresh)))
           (before (luau-browser--members entry)))
      (should (eq before (luau-browser--members entry)))
      (with-temp-file enum
        (insert "name: Material\nitems:\n  - name: NewMaterial\n"))
      (luau-browser-refresh)
      (should (equal (mapcar #'luau-browser-member-name
                             (luau-browser--members
                              (car (luau-browser--entries))))
                     '("NewMaterial"))))))

(ert-deftest luau-browser-test-member-rows-and-keymaps ()
  "Member rows have structural IDs and a fully mode-local keymap."
  (luau-browser-test--fixture
    (let ((entry (car (luau-browser-refresh))))
      (with-temp-buffer
        (luau-browser-member-mode)
        (setq-local luau-browser--member-owner entry)
        (luau-browser--member-refresh-buffer)
        (should (= (length tabulated-list-entries) 2))
        (should (luau-browser-member-p (caar tabulated-list-entries)))
        (should (equal (aref (cadar tabulated-list-entries) 0) "Grass")))))
  (should (eq (lookup-key luau-browser-mode-map (kbd "m"))
              #'luau-browser-members))
  (should (eq (lookup-key luau-browser-document-mode-map (kbd "m"))
              #'luau-browser-members))
  (should (eq (lookup-key luau-browser-member-mode-map (kbd "RET"))
              #'luau-browser-member-visit))
  (should (eq (lookup-key luau-browser-member-mode-map (kbd "/"))
              #'luau-browser-member-search)))

(ert-deftest luau-browser-test-member-completion-metadata ()
  "Member completion exposes kind groups and styled affixation metadata."
  (luau-browser-test--fixture
    (let* ((members (luau-browser--members (car (luau-browser-refresh))))
           (table (luau-browser--member-table members))
           (candidate (luau-browser--member-candidate (car members)))
           (metadata (completion-metadata "" table nil))
           (aff (completion-metadata-get metadata 'affixation-function))
           (group (completion-metadata-get metadata 'group-function)))
      (should (eq (completion-metadata-get metadata 'category)
                  'luau-roblox-api-member))
      (should (equal (funcall group candidate nil) "Items"))
      (should (equal (funcall group candidate t) candidate))
      (should (= (length (funcall aff (list candidate))) 1))
      (should-not (all-completions "Material" table))
      (should (member "Grass" (all-completions "Gra" table))))))

(ert-deftest luau-browser-test-member-selector-without-text-properties ()
  "Completion selection resolves records even when a frontend removes properties."
  (luau-browser-test--fixture
    (let ((members (luau-browser--members (car (luau-browser-refresh)))))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) "Plastic")))
        (should (equal (luau-browser-member-name
                        (luau-browser--member-select members))
                       "Plastic"))))))

(ert-deftest luau-browser-test-member-document-jump ()
  "Member navigation searches native Markdown headings before YAML summaries."
  (luau-browser-test--fixture
    (let ((yaml (expand-file-name
                 "roblox-creator-docs/content/en-us/reference/engine/datatypes/Vector3.yaml"
                 root)))
      (with-temp-file yaml
        (insert "name: Vector3\nmethods:\n  - name: Vector3:Cross\n"))
      (with-temp-file datatype
        (insert "# Vector3\n## Cross\n\nCross product\n"))
      (let* ((entry (cadr (luau-browser-refresh)))
             (member (car (luau-browser--members entry))))
        (with-temp-buffer
          (luau-browser-document-mode)
          (luau-browser--render entry)
          (should (luau-browser-document-goto-member member))
          (should (looking-at-p "## Cross")))))))

(ert-deftest luau-browser-test-member-online-fallback ()
  "Missing Markdown uses EWW routing when a YAML member is selected."
  (luau-browser-test--fixture
    (let ((member (car (luau-browser--members
                        (car (luau-browser-refresh)))))
          target)
      (cl-letf (((symbol-function 'luau-browser--online)
                 (lambda (name &optional kind)
                   (setq target (list name kind)))))
        (let ((luau-browser-online-fallback t))
          (luau-browser-member-visit member)))
      (should (equal target '("Material" "enums"))))))

(ert-deftest luau-browser-test-mode-automatically-installs-capf ()
  "Luau setup installs its API source only locally, with no global mutation."
  (with-temp-buffer
    (luau-mode)
    (should (memq #'luau-browser-capf completion-at-point-functions))
    (should (eq (lookup-key luau-mode-map (kbd "C-c C-b b"))
                #'luau-browser))
    (should (eq (lookup-key luau-mode-map (kbd "C-c C-b m"))
                #'luau-browser-members))
    (should (eq (lookup-key luau-mode-map (kbd "C-c C-b w"))
                #'luau-roblox-doc-at-point))))

(ert-deftest luau-browser-test-heading-search-keeps-all-alist-entries ()
  "Heading navigation must not lose completions through destructive reversal."
  (with-temp-buffer
    (insert "# First\n# Second\n# Third\n")
    (luau-browser-document-mode)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt choices &rest _)
                 (car (car (last choices))))))
      (luau-browser-document-jump-heading))
    (should (looking-at-p "# Third"))))


(ert-deftest luau-browser-test-cycle15-document-keys ()
  "Documentation keys remain local, with diagnostics at the browser prefix."
  (should (eq (lookup-key luau-mode-map (kbd "C-c C-d"))
              #'luau-browser-at-point))
  (should (eq (lookup-key luau-mode-map (kbd "C-c C-b D"))
              #'luau-lsp-diagnose))
  (should (eq (lookup-key luau-mode-map (kbd "C-c C-o"))
              #'luau-browser-at-point))
  (should (eq (lookup-key luau-browser-document-mode-map (kbd "TAB"))
              #'forward-button))
  (should (eq (lookup-key luau-browser-document-mode-map (kbd "RET"))
              #'push-button))
  (should (eq (lookup-key luau-browser-document-mode-map (kbd "z"))
              #'outline-cycle))
  (should (eq (lookup-key luau-browser-document-mode-map (kbd "l"))
              #'luau-browser-document-back))
  (should (eq (lookup-key luau-mode-map (kbd "C-c C-b t"))
              #'luau-browser-search-docs)))

(ert-deftest luau-browser-test-cycle15-web-browser-options ()
  "The default browser remains user-configurable, with explicit overrides."
  (let ((luau-roblox-docs-browser #'ignore))
    (should (eq (let ((luau-browser-web-browser 'inherit))
                  (luau-browser--web-function)) #'ignore))
    (should (eq (let ((luau-browser-web-browser 'eww))
                  (luau-browser--web-function)) #'eww))
    (should (eq (let ((luau-browser-web-browser 'external))
                  (luau-browser--web-function)) #'browse-url))))

(ert-deftest luau-browser-test-cycle15-force-external-documentation ()
  "Explicit external mode takes precedence over an available local page."
  (luau-browser-test--fixture
    (let* ((entry (cadr (luau-browser-refresh)))
           (luau-browser-document-presentation 'external)
           opened)
      (cl-letf (((symbol-function 'browse-url)
                 (lambda (url &rest _) (setq opened url))))
        (luau-browser-open entry))
      (should (string-suffix-p "/datatypes/Vector3" opened)))))

(ert-deftest luau-browser-test-cycle15-all-search-candidates ()
  "Apropos integrates type entries and fully qualified member names."
  (luau-browser-test--fixture
    (luau-browser-refresh)
    (let ((items (luau-browser--all-candidates)))
      (should (= (length items) 4))
      (should (cl-find-if (lambda (item)
                            (string-prefix-p "Material.Grass · items" (car item))) items))
      (should (cl-find-if (lambda (item)
                            (string-prefix-p "Vector3 · datatypes" (car item))) items))
      (should (equal (luau-browser--all-group "Material.Grass · items — " nil)
                     "Items")))))

(ert-deftest luau-browser-test-cycle15-guide-file-discovery ()
  "The guide picker sees Markdown pages outside the engine API subset."
  (luau-browser-test--fixture
    (let ((guide (expand-file-name
                  "roblox-creator-docs/content/en-us/scripting/example.md" root)))
      (make-directory (file-name-directory guide) t)
      (with-temp-file guide (insert "# Example\nA guide.\n"))
      (should (member guide (luau-browser--markdown-files)))
      (should (equal (luau-browser--documentation-file
                      (luau-browser--guide-entry guide)) guide)))))

(ert-deftest luau-browser-test-cycle15-markdown-full-text-fallback ()
  "Search all Markdown locally without requiring the rg binary."
  (luau-browser-test--fixture
    (let ((guide (expand-file-name
                  "roblox-creator-docs/content/en-us/scripting/testing.md" root)))
      (make-directory (file-name-directory guide) t)
      (with-temp-file guide
        (insert "# Testing\nThis has a searchable MagicalUnicorn token.\n"))
      (cl-letf (((symbol-function 'executable-find) (lambda (_program) nil)))
        (let ((hits (luau-browser--markdown-hits "MagicalUnicorn")))
          (should (= (length hits) 1))
          (should (equal (car (car hits)) guide))
          (should (= (cadr (car hits)) 2)))))))

(ert-deftest luau-browser-test-cycle15-rendered-markdown-buttons ()
  "Markdown links are rendered as native clickable Emacs buttons."
  (luau-browser-test--fixture
    (luau-browser-refresh)
    (let ((entry (cadr luau-browser--index)))
      (with-temp-file datatype
        (insert "# Vector3\n\nSee [Example](../../examples/example.md) and `Enum.Material`.\n"))
      (with-temp-buffer
        (luau-browser-document-mode)
        (setq-local luau-browser--entry entry)
        (luau-browser--render entry)
        (goto-char (point-min))
        (should (search-forward "Example" nil t))
        (should (equal (button-get (button-at (1- (point))) 'luau-browser-target)
                       "../../examples/example.md"))
        (should (search-forward "Enum.Material" nil t))
        (should (button-at (1- (point))))))))

(ert-deftest luau-browser-test-cycle15-safe-markdown-resolution ()
  "Relative links cannot follow files outside the configured docs root."
  (luau-browser-test--fixture
    (let ((entry (cadr (luau-browser-refresh))))
      (with-temp-buffer
        (luau-browser-document-mode)
        (setq-local luau-browser--entry entry)
        (should-not (luau-browser-document--resolve
                     "../../../../../../../../etc/passwd"))
        (should (eq (car (luau-browser-document--resolve "#methods")) entry))
        (let ((target (luau-browser-document--resolve
                       "/reference/engine/datatypes/Vector3#methods")))
          (should (equal (nth 1 (car target)) "Vector3"))
          (should (equal (cdr target) "methods")))))))

(ert-deftest luau-browser-test-cycle15-info-history ()
  "Back and forward navigation restore the displayed native reference."
  (luau-browser-test--fixture
    (let* ((entries (luau-browser-refresh))
           (enum-entry (car entries))
           (datatype-entry (cadr entries)))
      (with-temp-buffer
        (luau-browser-document-mode)
        (luau-browser-document--show enum-entry)
        (luau-browser-document--remember)
        (luau-browser-document--show datatype-entry)
        (should (equal luau-browser--entry datatype-entry))
        (luau-browser-document-back)
        (should (equal luau-browser--entry enum-entry))
        (luau-browser-document-forward)
        (should (equal luau-browser--entry datatype-entry))))))

(ert-deftest luau-browser-test-cycle15-guide-heading-links ()
  "Local document anchors follow Info-like heading navigation."
  (with-temp-buffer
    (luau-browser-document-mode)
    (let ((inhibit-read-only t))
      (insert "# Overview\nText\n## Some Methods\nDetails\n"))
    (should (luau-browser-document--goto-anchor "some-methods"))
    (should (looking-at "## Some Methods"))))

(ert-deftest luau-browser-test-cycle15-kind-search-dispatch ()
  "Typed minibuffer searches preserve category and open native references."
  (luau-browser-test--fixture
    (luau-browser-refresh)
    (let (opened)
      (cl-letf (((symbol-function 'luau-browser--select)
                 (lambda (entries &optional _prompt) (car entries)))
                ((symbol-function 'luau-browser-open)
                 (lambda (entry) (setq opened entry))))
        (luau-browser-search-enums)
        (should (equal (car opened) "enums"))
        (should-error (luau-browser-search-classes) :type 'user-error)))))

(ert-deftest luau-browser-test-cycle15-complete-documents-by-default ()
  "Native pages are not truncated at an arbitrary line count."
  (luau-browser-test--fixture
    (let ((entry (cadr (luau-browser-refresh))))
      (with-temp-file datatype
        (dotimes (index 1230)
          (insert (format "line %d\n" index))))
      (with-temp-buffer
        (luau-browser-document-mode)
        (let ((luau-browser-document-max-lines nil))
          (luau-browser--render entry))
        (goto-char (point-min))
        (should (search-forward "line 1229" nil t))))))

(provide 'luau-browser-test)
;;; luau-browser-test.el ends here
