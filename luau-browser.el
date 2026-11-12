;;; luau-browser.el --- Native Roblox API browser for Luau -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Luau contributors
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: Luau contributors
;; Keywords: languages, tools
;; URL: https://luau.org

;;; Commentary:

;; Offline-first Creator Docs index, Dired-like browser, native documentation
;; rendering, completing-read/Consult navigation, Corfu CAPF, and opt-in
;; conservative enum Flymake diagnostics.  No web requests or dependencies
;; are needed; the user's local Roblox/creator-docs checkout is authoritative.
;; This module deliberately does not modify global Vertico/Corfu settings.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'button)
(require 'tabulated-list)
(require 'flymake)
(require 'outline)
(require 'imenu)
(require 'url-util)
(require 'browse-url)
(require 'eww)

(declare-function luau-roblox-doc-at-point "luau-roblox" (&optional symbol))
(declare-function consult-ripgrep "consult" (&optional dir initial))
(declare-function luau-lsp-diagnose "luau-lsp" ())
(declare-function luau-roblox-docs--reference "luau-roblox" (name category))
(declare-function luau-roblox-docs--target-at-point "luau-roblox" ())
(defvar luau-roblox-docs-browser)

(defgroup luau-browser nil
  "Local Roblox API reference and editor integration."
  :group 'luau :prefix "luau-browser-")

(defcustom luau-browser-assets-root nil
  "Root directory for local Roblox documentation and official SVG icons.
Set this to the directory containing `roblox-creator-docs' and
`engine-reference-svg-icons'.  It is not tied to a machine-specific
path.  When nil, search the current project ancestry."
  :type '(choice (const :tag "Discover from project" nil) directory)
  :group 'luau-browser)

(defcustom luau-browser-use-icons t
  "Display locally installed SVG icons when image support is available."
  :type 'boolean :group 'luau-browser)

(defcustom luau-browser-enable-capf t
  "Include local API candidates in Luau `completion-at-point'."
  :type 'boolean :group 'luau-browser)

(defcustom luau-browser-online-fallback t
  "Use the configured live Roblox documentation browser when local docs are absent.
The default `luau-roblox-docs-browser' is `eww'.  Network access only
occurs after an explicit navigation command.  When nil, missing local
references produce an actionable user error."
  :type 'boolean :group 'luau-browser)

(defcustom luau-browser-enable-corfu-icons t
  "Add official Roblox icons to Corfu's margin in Luau buffers.
Only local Roblox completion candidates are decorated; other sources
retain the user's normal Corfu margin formatters.  No dependency on
Corfu is introduced by this option."
  :type 'boolean :group 'luau-browser)

(defcustom luau-browser-document-presentation 'native
  "Choose how to display reference pages when documentation is requested.
`native' uses the local Info-like Emacs reader and falls back online when
Markdown is missing.  `eww' and `external' always open the web version,
even if a local Markdown page exists.  No automatic network request is
performed when entering `luau-mode'."
  :type '(choice (const :tag "Local reader, browser fallback" native)
                 (const :tag "Always use EWW" eww)
                 (const :tag "Always use system browser" external))
  :group 'luau-browser)

(defcustom luau-browser-web-browser 'inherit
  "Choose which web browser handles explicit links and missing local docs.
`inherit' uses `luau-roblox-docs-browser'; `eww' opens Emacs EWW,
and `external' calls `browse-url', honoring its Firefox, xdg-open,
or other configured system-browser settings."
  :type '(choice (const :tag "Existing Roblox browser function" inherit)
                 (const :tag "EWW inside Emacs" eww)
                 (const :tag "browse-url (Firefox/xdg-open etc.)" external))
  :group 'luau-browser)

(defcustom luau-browser-document-search-limit 180
  "Maximum numbered Markdown matches offered in a minibuffer text search."
  :type '(integer 1 2000) :group 'luau-browser)

(defface luau-browser-link-face
  '((t :inherit link :weight medium))
  "Cross-reference and internal Markdown link appearance."
  :group 'luau-browser)
(defface luau-browser-breadcrumb-face
  '((t :inherit (shadow variable-pitch)))
  "Native documentation breadcrumb and navigation hints."
  :group 'luau-browser)
(defface luau-browser-section-face
  '((t :inherit (font-lock-type-face variable-pitch) :weight bold))
  "Section navigation and Info-like page sections."
  :group 'luau-browser)

(defcustom luau-browser-enable-enum-lint nil
  "Report unknown Enum.TYPE.MEMBER combinations using indexed YAML.
Only enum types with a successfully indexed nonempty member set are
validated.  Defaults to off to avoid duplicating language-server lint."
  :type 'boolean :group 'luau-browser)

(defface luau-browser-kind-face
  '((t :inherit font-lock-keyword-face))
  "API reference kind heading." :group 'luau-browser)
(defface luau-browser-name-face
  '((t :inherit font-lock-function-name-face :weight bold))
  "API reference symbols." :group 'luau-browser)
(defface luau-browser-path-face
  '((t :inherit shadow))
  "Local reference paths and secondary descriptions." :group 'luau-browser)
(defface luau-browser-heading-face
  '((t :inherit font-lock-type-face :weight bold))
  "Native reference heading." :group 'luau-browser)
(defface luau-browser-description-face
  '((t :inherit font-lock-doc-face))
  "Reference summary text." :group 'luau-browser)
(defface luau-browser-inline-code-face
  '((t :inherit (fixed-pitch font-lock-constant-face)))
  "Inline Markdown code in local documentation." :group 'luau-browser)
(defface luau-browser-code-block-face
  '((t :inherit (fixed-pitch font-lock-string-face)))
  "Fenced code examples in local documentation." :group 'luau-browser)

(defvar luau-browser--index nil
  "Cached references as (KIND NAME PATH SUMMARY).")
(defvar luau-browser--root nil
  "Root used to construct the last reference index.")
(defvar luau-browser--stamp nil
  "Explicit cache invalidation generation number.")
(defvar luau-browser--icons-cache (make-hash-table :test #'equal)
  "Cache of resolved local official SVG icon paths.")
(defvar luau-browser--members-cache (make-hash-table :test #'equal)
  "Cache of parsed local reference members keyed by file identity.")
(defvar luau-browser--completion-index (make-hash-table :test #'equal)
  "Name to reference entry index, rebuilt with the reference cache.")
(defvar corfu-margin-formatters nil
  "Optional Corfu margin formatter registry.")

(defcustom luau-browser-document-max-lines nil
  "Maximum lines to show from a local Markdown document, or nil for all.
The default does not silently truncate reference pages or full-text search
results.  Set a positive bound for unusually large Markdown files."
  :type '(choice (const :tag "Render entire document" nil)
                 (integer :tag "Maximum lines" 1))
  :group 'luau-browser)

(defvar luau-browser-history nil
  "History for Roblox API completion.")
(defvar-local luau-browser--entry nil
  "Reference displayed in the current documentation buffer.")
(defvar-local luau-browser--back-stack nil
  "Previously visited native document positions.")
(defvar-local luau-browser--forward-stack nil
  "Native document positions available after going backward.")
(defvar luau-browser--source-buffer nil
  "Source buffer before opening an API reference.")
(defvar-local luau-browser--kind-filter nil
  "Reference category selected in the current browser buffer.")

(defun luau-browser--root-directory ()
  "Find the local documentation asset root without network access."
  (or (and luau-browser-assets-root
           (file-directory-p luau-browser-assets-root)
           (expand-file-name luau-browser-assets-root))
      (let ((ancestor (locate-dominating-file
                       default-directory "docs/roblox-creator-docs")))
        (when ancestor (expand-file-name "docs" ancestor)))
      (let ((ancestor (locate-dominating-file
                       default-directory "roblox-creator-docs")))
        (when ancestor ancestor))))

(defun luau-browser--docs-directory ()
  "Return the Creator Docs checkout directory, if one is available."
  (when-let* ((root (luau-browser--root-directory)))
    (let ((nested (expand-file-name "roblox-creator-docs" root)))
      (if (file-directory-p nested) nested root))))

(defun luau-browser--reference-files (root)
  "Find supported local reference source files under ROOT."
  (when root
    (let* ((content (expand-file-name "content/en-us/reference" root))
           (directory (if (file-directory-p content) content root)))
      (when (file-directory-p directory)
        (cl-remove-if-not
         (lambda (file)
           (and (string-match-p "\\.\\(yaml\\|yml\\|md\\)\\'" file)
                (string-match-p
                 "/\\(classes\\|datatypes\\|enums\\|globals\\|libraries\\)/" file)))
         (directory-files-recursively directory "\\.\\(yaml\\|yml\\|md\\)\\'"))))))

(defun luau-browser--kind (file)
  "Return supported reference kind from FILE's path."
  (when (string-match
         "/\\(classes\\|datatypes\\|enums\\|globals\\|libraries\\)/" file)
    (match-string 1 file)))

(defun luau-browser--summary (file)
  "Extract a short readable summary from local FILE."
  (with-temp-buffer
    (insert-file-contents file nil 0
                          (min 8192 (file-attribute-size (file-attributes file))))
    (goto-char (point-min))
    (let ((case-fold-search t))
      (cond
       ((re-search-forward
         "^\\(?:summary\\|description\\):[[:space:]]*\\(.*\\)$" nil t)
        (let ((value (string-trim (match-string-no-properties 1))))
          (when (member value '("|" ">" "|-" ">-" ""))
            (forward-line 1)
            (setq value (string-trim
                         (buffer-substring-no-properties
                          (line-beginning-position) (line-end-position)))))
          (truncate-string-to-width
           (string-trim value "['\"]" "['\"]") 160 nil nil t)))
       ((re-search-forward "^#[[:space:]]+\\(.+\\)$" nil t)
        (match-string-no-properties 1))
       (t "")))))

(cl-defstruct (luau-browser-member
               (:constructor luau-browser--make-member))
  "A local YAML API declaration, rather than a rendered Markdown section."
  name kind entry line summary type parameters returns deprecated)

(defvar luau-browser--yaml-members-cache (make-hash-table :test #'equal)
  "File identity to parsed engine API member records.")
(defvar luau-browser-member-history nil
  "Minibuffer completion history for API member searches.")
(defvar-local luau-browser--member-owner nil
  "Current parent API reference in a member-list buffer.")

(defun luau-browser--unquote-yaml (value)
  "Return a normalized scalar string from the limited YAML VALUE syntax."
  (let ((scalar (string-trim (or value ""))))
    (if (and (>= (length scalar) 2)
             (memq (aref scalar 0) '(34 39))
             (eq (aref scalar 0) (aref scalar (1- (length scalar)))))
        (substring scalar 1 -1)
      scalar)))

(defun luau-browser--parse-members (entry)
  "Parse the top-level API member sections of YAML ENTRY without executing YAML.
Nested parameter `name' fields must never become top-level members.
This is intentionally a conservative parser for Roblox's generated engine
reference schema, not a general-purpose YAML reader."
  (let ((file (nth 2 entry)) section current nested summary-pending result)
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (while (not (eobp))
        (let ((line (buffer-substring-no-properties
                     (line-beginning-position) (line-end-position))))
          (cond
           ((string-match "^\\([[:alpha:]_]+\\):" line)
            (setq section (and (member (match-string 1 line)
                                       '("items" "properties" "constants"
                                         "constructors" "methods" "events"
                                         "callbacks" "functions"))
                               (match-string 1 line))
                  current nil nested nil summary-pending nil))
           ((and section
                 (string-match "^\\(?:  \\)?- name: +\\(.+\\)$" line))
            (setq current (luau-browser--make-member
                           :name (luau-browser--unquote-yaml (match-string 1 line))
                           :kind section :entry entry
                           :line (line-number-at-pos)
                           :summary "" :type "" :parameters nil :returns "")
                  nested nil summary-pending nil)
            (push current result))
           ((and current
                 (string-match "^    summary: *\\(.*\\)$" line))
            (let ((value (luau-browser--unquote-yaml (match-string 1 line))))
              (setq summary-pending (member value '("|" "|-" ">" ">-")))
              (unless summary-pending
                (setf (luau-browser-member-summary current) value))))
           ((and current summary-pending
                 (string-match "^      \\(.*\\)$" line))
            (let ((value (string-trim (match-string 1 line))))
              (unless (string-empty-p value)
                (setf (luau-browser-member-summary current) value)
                (setq summary-pending nil))))
           ((and current (string-match "^    type: *\\(.*\\)$" line))
            (setf (luau-browser-member-type current)
                  (luau-browser--unquote-yaml (match-string 1 line)))
            (setq nested nil summary-pending nil))
           ((and current (string-match "^    parameters:" line))
            (setq nested 'parameters summary-pending nil))
           ((and current (string-match "^    returns:" line))
            (setq nested 'returns summary-pending nil))
           ((and current (eq nested 'parameters)
                 (string-match "^      - name: *\\(.+\\)$" line))
            (push (cons (luau-browser--unquote-yaml (match-string 1 line)) "")
                  (luau-browser-member-parameters current)))
           ((and current (eq nested 'parameters)
                 (string-match "^        type: *\\(.+\\)$" line)
                 (luau-browser-member-parameters current))
            (setcdr (car (luau-browser-member-parameters current))
                    (luau-browser--unquote-yaml (match-string 1 line))))
           ((and current (eq nested 'returns)
                 (string-match "^      - type: *\\(.+\\)$" line))
            (setf (luau-browser-member-returns current)
                  (luau-browser--unquote-yaml (match-string 1 line))))
           ((and current (string-match "^    tags:" line))
            (setq nested 'tags summary-pending nil))
           ((and current (eq nested 'tags)
                 (string-match "^      - Deprecated\\(?:[[:space:]]\\|$\\)" line))
            (setf (luau-browser-member-deprecated current) t))
           ((and current (string-match "^    [[:alpha:]_]+:" line))
            (setq nested nil summary-pending nil))))
        (forward-line 1)))
    (nreverse result)))

(defun luau-browser--members (entry)
  "Return cached structural member records for API ENTRY, when YAML exists."
  (when (and entry (string-match-p "\\.ya?ml\\'" (nth 2 entry))
             (file-readable-p (nth 2 entry)))
    (let* ((file (nth 2 entry))
           (attributes (file-attributes file))
           (key (list file (file-attribute-modification-time attributes)
                      (file-attribute-size attributes)))
           (cached (gethash key luau-browser--yaml-members-cache 'missing)))
      (if (eq cached 'missing)
          (let ((parsed (luau-browser--parse-members entry)))
            (puthash key parsed luau-browser--yaml-members-cache)
            parsed)
        cached))))

(defun luau-browser--member-short-name (member)
  "Return the unqualified name of MEMBER, retaining original case."
  (let ((name (luau-browser-member-name member)))
    (if (string-match "[.:]\\([^.:]+\\)\\'" name)
        (match-string 1 name)
      name)))

(defun luau-browser--member-signature (member)
  "Return the compact typed signature for MEMBER when declared in YAML."
  (let* ((parameters (nreverse (copy-sequence
                                (luau-browser-member-parameters member))))
         (return (luau-browser-member-returns member))
         (type (luau-browser-member-type member))
         (function-p (member (luau-browser-member-kind member)
                             '("constructors" "methods" "functions" "callbacks"))))
    (if function-p
        (concat "(" (mapconcat (lambda (param)
                                (concat (car param)
                                        (if (string-empty-p (cdr param)) ""
                                          (concat ": " (cdr param)))))
                              parameters ", ") ")"
                (if (string-empty-p return) "" (concat " → " return)))
      (if (string-empty-p type) "" (concat ": " type)))))

(defun luau-browser--member-annotation (candidate)
  "Return a styled completion annotation for member CANDIDATE."
  (when-let* ((member (get-text-property 0 'luau-browser-member candidate)))
    (concat (propertize (format "  %-12s" (luau-browser-member-kind member))
                        'face 'luau-browser-kind-face)
            (propertize (luau-browser--member-signature member)
                        'face 'luau-browser-path-face)
            (let ((summary (luau-browser-member-summary member)))
              (if (string-empty-p summary) ""
                (concat "  " (propertize
                              (truncate-string-to-width summary 74 nil nil t)
                              'face 'luau-browser-description-face)))))))

(defun luau-browser--member-candidate (member)
  "Build a completion candidate referring to MEMBER."
  (propertize (luau-browser-member-name member) 'luau-browser-member member))

(defun luau-browser--member-affixate (candidates)
  "Return MEMBER CANDIDATES as native completion affixation triples."
  (mapcar (lambda (candidate)
            (let* ((member (get-text-property 0 'luau-browser-member candidate))
                   (icon (and member
                              (luau-browser--icon (luau-browser-member-kind member)))))
              (list candidate
                    (if icon (propertize "  " 'display icon)
                      (propertize "◆ " 'face 'luau-browser-kind-face))
                    (luau-browser--member-annotation candidate))))
          candidates))

(defun luau-browser--member-group (candidate transform)
  "Group member CANDIDATE by YAML section unless TRANSFORM is non-nil."
  (if transform candidate
    (if-let* ((member (get-text-property 0 'luau-browser-member candidate)))
        (capitalize (luau-browser-member-kind member))
      "Members")))

(defun luau-browser--member-table (members)
  "Return a metadata-rich standard completion table for MEMBERS."
  (let ((candidates (mapcar #'luau-browser--member-candidate members)))
    (lambda (string predicate action)
      (if (eq action 'metadata)
          '(metadata (category . luau-roblox-api-member)
                     (affixation-function . luau-browser--member-affixate)
                     (group-function . luau-browser--member-group)
                     (display-sort-function . identity))
        (complete-with-action action candidates string predicate)))))

(defun luau-browser--member-select (members)
  "Select a record among MEMBERS with Consult/Vertico-compatible completion."
  (let* ((choice (completing-read "Roblox member: "
                                  (luau-browser--member-table members)
                                  nil t nil 'luau-browser-member-history))
         (member (get-text-property 0 'luau-browser-member choice)))
    (or member
        (cl-find choice members :key #'luau-browser-member-name :test #'equal))))

(defun luau-browser--canonical-files (files)
  "Return FILES with YAML taking precedence over same-stem Markdown.
A matching YAML file is the engine API structure; ordinary Markdown is
retained when no YAML with the same stem exists.  Markdown companion
pages can still be opened through `luau-browser--companion-markdown'."
  (let ((seen (make-hash-table :test #'equal)) result)
    (dolist (file (sort (copy-sequence files) #'string<))
      (let* ((stem (file-name-sans-extension file))
             (prior (gethash stem seen)))
        (when (or (null prior)
                  (and (string-match-p "\\.md\\'" prior)
                       (string-match-p "\\.ya?ml\\'" file)))
          (puthash stem file seen))))
    (maphash (lambda (_ file) (push file result)) seen)
    (sort result #'string<)))

(defun luau-browser--companion-markdown (file)
  "Return a Markdown content companion to YAML FILE when it exists."
  (when (string-match-p "\\.ya?ml\\'" file)
    (let ((candidate (concat (file-name-sans-extension file) ".md")))
      (when (file-readable-p candidate) candidate))))

(defun luau-browser--documentation-file (entry)
  "Return the readable Markdown content file for API ENTRY, or nil.
YAML is the structural schema for completion, not a replacement for a
missing local documentation page."
  (when entry
    (let ((file (nth 2 entry)))
      (if (string-match-p "\\.ya?ml\\'" file)
          (luau-browser--companion-markdown file)
        (and (file-readable-p file) file)))))

(defun luau-browser-refresh ()
  "Rebuild the reference cache from local YAML structure and Markdown."
  (interactive)
  (let* ((root (luau-browser--docs-directory))
         (files (luau-browser--canonical-files
                 (luau-browser--reference-files root))))
    (clrhash luau-browser--members-cache)
    (clrhash luau-browser--yaml-members-cache)
    (clrhash luau-browser--icons-cache)
    (clrhash luau-browser--completion-index)
    (setq luau-browser--root root
          luau-browser--index
          (sort (mapcar (lambda (file)
                          (list (luau-browser--kind file)
                                (file-name-base file)
                                file (luau-browser--summary file)))
                        files)
                (lambda (a b)
                  (string-lessp (concat (nth 1 a) (car a))
                                (concat (nth 1 b) (car b)))))
          luau-browser--stamp (1+ (or luau-browser--stamp 0)))
    (dolist (entry luau-browser--index)
      (puthash (nth 1 entry) entry luau-browser--completion-index))
    (when (called-interactively-p 'interactive)
      (message "Luau API: indexed %d local references" (length files)))
    luau-browser--index))

(defun luau-browser--entries ()
  "Return indexed Roblox references, refreshing after a root change."
  (let ((root (luau-browser--docs-directory)))
    (if (and (equal root luau-browser--root) luau-browser--stamp)
        luau-browser--index
      (luau-browser-refresh))))

(defun luau-browser--require-entries ()
  "Return reference entries or explain missing local assets."
  (or (luau-browser--entries)
      (user-error "No Roblox references found; customize `luau-browser-assets-root'")))

(defun luau-browser--icon (kind)
  "Return a local official SVG image for KIND, or nil if unavailable."
  (when (and luau-browser-use-icons (image-type-available-p 'svg))
    (let* ((root (luau-browser--root-directory))
           (icons (and root (expand-file-name "engine-reference-svg-icons" root)))
           (cache-key (cons icons kind))
           (cached (gethash cache-key luau-browser--icons-cache 'missing)))
      (when (file-directory-p icons)
        (let ((file
               (if (eq cached 'missing)
                   (let* ((names (pcase kind
                                   ("classes" '("class" "classes"))
                                   ("datatypes" '("datatype" "data-type" "type"))
                                   ("enums" '("enum" "enumeration"))
                                   ("properties" '("property" "properties"))
                                   ("methods" '("method" "methods"))
                                   ("events" '("event" "events"))
                                   ("callbacks" '("callback" "callbacks"))
                                   ("constructors" '("constructor" "method"))
                                   ("constants" '("constant" "property"))
                                   ("items" '("enum" "enumeration"))
                                   ("functions" '("function" "method"))
                                   (_ (list kind))))
                          (found (cl-find-if
                                  (lambda (path)
                                    (member (downcase (file-name-base path)) names))
                                  (directory-files-recursively icons "\\.svg\\'"))))
                     (puthash cache-key found luau-browser--icons-cache)
                     found)
                 cached)))
          (when file
            (condition-case nil
                (create-image file 'svg nil :width (frame-char-width)
                              :height (frame-char-height) :ascent 'center)
              (error nil))))))))

(defun luau-browser--candidate (entry)
  "Create a completion candidate for ENTRY with semantic metadata."
  (let ((candidate (format "%s · %s" (nth 1 entry) (car entry))))
    (propertize candidate 'luau-browser-entry entry)))

(defun luau-browser--annotate (candidate)
  "Annotate CANDIDATE for Vertico, Consult and default completion."
  (when-let* ((entry (get-text-property 0 'luau-browser-entry candidate)))
    (concat "  " (propertize (or (nth 3 entry) "")
                            'face 'luau-browser-path-face))))

(defun luau-browser--affixate (candidates)
  "Supply affixation triples for CANDIDATES."
  (mapcar (lambda (candidate)
            (let* ((entry (get-text-property 0 'luau-browser-entry candidate))
                   (icon (and entry (luau-browser--icon (car entry))))
                   (prefix (if icon
                               (propertize "  " 'display icon)
                             (propertize "◆ " 'face 'luau-browser-kind-face))))
              (list candidate prefix (luau-browser--annotate candidate))))
          candidates))

(defun luau-browser--completion-group (candidate transform)
  "Return grouping for CANDIDATE unless TRANSFORM requests the symbol."
  (if transform candidate
    (if-let* ((entry (get-text-property 0 'luau-browser-entry candidate)))
        (capitalize (car entry))
      (if (string-match " · \\([[:alpha:]]+\\)\\'" candidate)
          (capitalize (match-string 1 candidate))
        "Roblox"))))

(defun luau-browser--completion-table (entries)
  "Return metadata-rich completion table for ENTRIES."
  (let ((candidates (mapcar #'luau-browser--candidate entries)))
    (lambda (string predicate action)
      (if (eq action 'metadata)
          '(metadata (category . luau-roblox-api)
                     (annotation-function . luau-browser--annotate)
                     (affixation-function . luau-browser--affixate)
                     (group-function . luau-browser--completion-group)
                     (display-sort-function . identity)
                     (cycle-sort-function . identity))
        (complete-with-action action candidates string predicate)))))

(defun luau-browser--select (entries &optional prompt)
  "Select one of ENTRIES through completion with PROMPT."
  (let* ((table (luau-browser--completion-table entries))
         (selected (completing-read (or prompt "Roblox API: ") table nil t
                                    nil 'luau-browser-history)))
    (or (get-text-property 0 'luau-browser-entry selected)
        (cl-find-if (lambda (entry)
                      (equal (luau-browser--candidate entry) selected)) entries))))

(defun luau-browser--web-function ()
  "Return the explicitly selected web browser function."
  (pcase luau-browser-web-browser
    ('eww #'eww)
    ('external #'browse-url)
    (_ luau-roblox-docs-browser)))

(defun luau-browser--online (name &optional kind)
  "Open web documentation for NAME in KIND via the selected browser.
Unlike automatic fallback, this explicit command ignores
`luau-browser-online-fallback'."
  (require 'luau-roblox)
  (if kind
      (funcall (luau-browser--web-function)
               (luau-roblox-docs--reference name kind))
    (let ((luau-roblox-docs-browser (luau-browser--web-function)))
      (luau-roblox-doc-at-point name))))

(defun luau-browser--online-entry (entry)
  "Open the web URL for reference ENTRY, including conceptual guides."
  (if (equal (car entry) "guides")
      (let* ((root (luau-browser--markdown-root))
             (file (nth 2 entry))
             (relative (and root (file-in-directory-p file root)
                            (file-relative-name file root))))
        (unless relative (user-error "No valid local guide URL"))
        (setq relative (file-name-sans-extension relative))
        (when (string-suffix-p "/index" relative)
          (setq relative (substring relative 0 -6)))
        (funcall (luau-browser--web-function)
                 (concat "https://create.roblox.com/docs/en-us/" relative)))
    (luau-browser--online (nth 1 entry) (car entry))))

(defun luau-browser--fallback (name &optional kind)
  "Open live documentation for NAME and KIND when locally unavailable."
  (if luau-browser-online-fallback
      (let ((luau-browser-web-browser
             (if (memq luau-browser-document-presentation '(eww external))
                 luau-browser-document-presentation
               luau-browser-web-browser)))
        (luau-browser--online name kind))
    (user-error "Local Roblox docs unavailable; set `luau-browser-assets-root' or enable online fallback")))

(defun luau-browser-open-online ()
  "Open the selected Roblox reference online, even when locally available."
  (interactive)
  (let ((entry (if (derived-mode-p 'luau-browser-mode)
                   (tabulated-list-get-id)
                 luau-browser--entry)))
    (unless entry (user-error "No Roblox API reference selected"))
    (luau-browser--online-entry entry)))

;;;###autoload
(defun luau-browser-search ()
  "Search local Roblox API symbols through native completion.
Consult and Vertico integrate automatically through `completing-read'."
  (interactive)
  (if-let* ((entries (luau-browser--entries)))
      (luau-browser-open (luau-browser--select entries))
    (luau-browser--fallback nil)))

(defun luau-browser--rows ()
  "Return tabulated list rows from the local reference index."
  (cl-loop for entry in (luau-browser--entries)
           for kind = (car entry)
           when (or (null luau-browser--kind-filter)
                    (equal kind luau-browser--kind-filter))
           collect (list entry
                         (vector (propertize (nth 1 entry)
                                             'face 'luau-browser-name-face)
                                 (propertize kind 'face 'luau-browser-kind-face)
                                 (propertize (nth 3 entry)
                                             'face 'luau-browser-description-face)))))

(defun luau-browser-copy-name ()
  "Copy the API symbol on the current browser row."
  (interactive)
  (let ((entry (tabulated-list-get-id)))
    (unless entry (user-error "No Roblox API reference on this row"))
    (kill-new (nth 1 entry))
    (message "Copied Roblox symbol: %s" (nth 1 entry))))

(defun luau-browser-copy-qualified-name ()
  "Copy a kind-qualified API symbol from the browser row."
  (interactive)
  (let ((entry (tabulated-list-get-id)))
    (unless entry (user-error "No Roblox API reference on this row"))
    (let ((qualified
           (concat (pcase (car entry)
                     ("classes" "Class.")
                     ("datatypes" "Datatype.")
                     ("enums" "Enum.")
                     (_ ""))
                   (nth 1 entry))))
      (kill-new qualified)
      (message "Copied Roblox reference: %s" qualified))))

(defun luau-browser-view-source ()
  "Open the original local YAML or Markdown for the current row."
  (interactive)
  (let ((entry (or (and (derived-mode-p 'luau-browser-mode)
                        (tabulated-list-get-id))
                   luau-browser--entry)))
    (unless entry (user-error "No Roblox API reference selected"))
    (if (file-readable-p (nth 2 entry))
        (find-file-other-window (nth 2 entry))
      (luau-browser--fallback (nth 1 entry) (car entry)))))

(defun luau-browser-filter-kind ()
  "Narrow the browser to a category, without changing the underlying index."
  (interactive)
  (let* ((kinds (delete-dups (mapcar #'car (luau-browser--entries))))
         (picked (completing-read "Roblox API kind: "
                                  (cons "All" (sort kinds #'string<)) nil t)))
    (setq-local luau-browser--kind-filter (unless (equal picked "All") picked))
    (luau-browser--refresh-buffer)
    (tabulated-list-print t)))

(defun luau-browser-clear-filter ()
  "Display every indexed Roblox API category."
  (interactive)
  (setq-local luau-browser--kind-filter nil)
  (luau-browser--refresh-buffer)
  (tabulated-list-print t))

(defun luau-browser-describe-bindings ()
  "Show the browser's local keys using Emacs native help."
  (interactive)
  (describe-bindings))

(defvar luau-browser-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'luau-browser-visit)
    (define-key map (kbd "o") #'luau-browser-visit-other-window)
    (define-key map (kbd "/") #'luau-browser-search)
    (define-key map (kbd "s") #'luau-browser-search)
    (define-key map (kbd "a") #'luau-browser-apropos)
    (define-key map (kbd "S") #'luau-browser-search-docs)
    (define-key map (kbd "g") #'luau-browser-revert)
    (define-key map (kbd "f") #'luau-browser-filter-kind)
    (define-key map (kbd "F") #'luau-browser-clear-filter)
    (define-key map (kbd "W") #'luau-browser-open-online)
    (define-key map (kbd "n") #'next-line)
    (define-key map (kbd "p") #'previous-line)
    (define-key map (kbd "j") #'next-line)
    (define-key map (kbd "k") #'previous-line)
    (define-key map (kbd "c") #'luau-browser-copy-name)
    (define-key map (kbd "C") #'luau-browser-copy-qualified-name)
    (define-key map (kbd "v") #'luau-browser-view-source)
    (define-key map (kbd "h") #'luau-browser-describe-bindings)
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "?") #'luau-browser-help)
    map)
  "Keymap for the Dired-like Roblox reference index.")

(define-derived-mode luau-browser-mode tabulated-list-mode "Luau-API"
  "Major mode for the locally indexed Roblox API reference."
  (setq tabulated-list-format
        [("Symbol" 34 t) ("Kind" 12 t) ("Summary" 64 t)])
  (setq tabulated-list-padding 2)
  (setq-local header-line-format
              (propertize "  ◆  ROBLOX API   •   RET read  m members  / search  f filter  W web  ? keys"
                          'face 'luau-browser-heading-face))
  (setq tabulated-list-sort-key (cons "Symbol" nil))
  (add-hook 'tabulated-list-revert-hook #'luau-browser--refresh-buffer nil t)
  (tabulated-list-init-header))

(defun luau-browser--refresh-buffer ()
  "Populate the current API index buffer without changing global state."
  (setq tabulated-list-entries (luau-browser--rows)))

;;;###autoload
(defun luau-browser ()
  "Display a Dired-like API index, falling back online without local docs."
  (interactive)
  (if (not (luau-browser--entries))
      (luau-browser--fallback nil)
    (let ((buffer (get-buffer-create "*Luau API*")))
      (with-current-buffer buffer
        (unless (derived-mode-p 'luau-browser-mode)
          (luau-browser-mode))
        (luau-browser--refresh-buffer)
        (tabulated-list-print t))
      (pop-to-buffer buffer))))

(defun luau-browser-revert ()
  "Refresh the local API index and redisplay the browser."
  (interactive)
  (luau-browser-refresh)
  (revert-buffer))

(defun luau-browser-visit ()
  "Visit the selected API reference entry."
  (interactive)
  (let ((entry (tabulated-list-get-id)))
    (unless entry (user-error "No Roblox API reference on this row"))
    (luau-browser-open entry)))

(defun luau-browser-visit-other-window ()
  "Visit the selected API reference in another window."
  (interactive)
  (let ((entry (tabulated-list-get-id)))
    (unless entry (user-error "No Roblox API reference on this row"))
    (let ((display-buffer-overriding-action
           '((display-buffer-pop-up-window))))
      (luau-browser-open entry))))

(defun luau-browser-help ()
  "Show a concise keymap summary for the native reference browser."
  (interactive)
  (message "RET native · W online/EWW · o window · / search · f/F filter · g refresh · j/k move · c/C copy · v source · q quit"))

;; These documentation commands are intentionally independent of Consult.
;; They use Emacs completion metadata, which Vertico and Consult understand.

(defun luau-browser--search-kind (kind)
  "Select and open a local API reference in category KIND."
  (let ((entries (cl-remove-if-not
                  (lambda (entry) (equal (car entry) kind))
                  (luau-browser--entries))))
    (unless entries
      (user-error "No local Roblox %s references; customize `luau-browser-assets-root'" kind))
    (luau-browser-open
     (luau-browser--select entries (format "Roblox %s: " kind)))))

;;;###autoload
(defun luau-browser-search-classes ()
  "Find a Roblox class through minibuffer completion."
  (interactive)
  (luau-browser--search-kind "classes"))

;;;###autoload
(defun luau-browser-search-enums ()
  "Find a Roblox enum through minibuffer completion."
  (interactive)
  (luau-browser--search-kind "enums"))

;;;###autoload
(defun luau-browser-search-datatypes ()
  "Find a Roblox datatype through minibuffer completion."
  (interactive)
  (luau-browser--search-kind "datatypes"))

;;;###autoload
(defun luau-browser-search-globals ()
  "Find a Roblox global through minibuffer completion."
  (interactive)
  (luau-browser--search-kind "globals"))

;;;###autoload
(defun luau-browser-search-libraries ()
  "Find a Roblox library through minibuffer completion."
  (interactive)
  (luau-browser--search-kind "libraries"))

(defun luau-browser--all-candidates ()
  "Return all indexed API types and members with stable display labels."
  (let (candidates)
    (dolist (entry (luau-browser--require-entries))
      (push (cons (format "%s · %s — %s"
                          (nth 1 entry) (car entry) (nth 3 entry))
                  (cons 'entry entry)) candidates)
      (dolist (member (luau-browser--members entry))
        (push (cons (format "%s.%s · %s — %s"
                            (nth 1 entry)
                            (luau-browser--member-short-name member)
                            (luau-browser-member-kind member)
                            (luau-browser-member-summary member))
                    (cons 'member member)) candidates)))
    (nreverse candidates)))

(defun luau-browser--all-group (candidate transform)
  "Return completion group for CANDIDATE, unless TRANSFORM is non-nil."
  (if transform candidate
    (if (string-match " · \\([^ —]+\\) — " candidate)
        (capitalize (match-string 1 candidate))
      "Roblox API")))

(defun luau-browser--all-affix (candidates)
  "Decorate API CANDIDATES with searchable semantic grouping."
  (mapcar (lambda (candidate)
            (let* ((match (string-match " · \\([^ —]+\\) — " candidate))
                   (kind (and match (match-string 1 candidate)))
                   (icon (and kind (luau-browser--icon kind))))
              (list candidate
                    (if icon (propertize "  " 'display icon)
                      (propertize "◆ " 'face 'luau-browser-kind-face))
                    ""))) candidates))

;;;###autoload
(defun luau-browser-search-all ()
  "Search all local Roblox types, enums, classes and YAML API members.
This uses ordinary `completing-read' metadata for Vertico and Consult;
member declarations have distinct qualified names and semantic groups."
  (interactive)
  (let* ((items (luau-browser--all-candidates))
         (labels (mapcar #'car items))
         (table (lambda (string predicate action)
                  (if (eq action 'metadata)
                      '(metadata (category . luau-roblox-apropos)
                                 (group-function . luau-browser--all-group)
                                 (affixation-function . luau-browser--all-affix))
                    (complete-with-action action labels string predicate))))
         (picked (completing-read "Roblox API or member: " table nil t
                                  nil 'luau-browser-history))
         (target (cdr (assoc picked items))))
    (pcase (car target)
      ('entry (luau-browser-open (cdr target)))
      ('member (luau-browser-member-visit (cdr target)))
      (_ (user-error "No Roblox reference selected")))))

;;;###autoload
(defun luau-browser-apropos ()
  "Apropos-like minibuffer search of all local Roblox API declarations.
For full-text Markdown search, use `luau-browser-search-docs' instead."
  (interactive)
  (luau-browser-search-all))

(defun luau-browser--markdown-root ()
  "Return the local Creator Docs Markdown content directory."
  (when-let* ((checkout (luau-browser--docs-directory))
              (content (expand-file-name "content/en-us" checkout)))
    (when (file-directory-p content) content)))

(defun luau-browser--markdown-files ()
  "Enumerate local Markdown documents without fetching anything online."
  (when-let* ((root (luau-browser--markdown-root)))
    (directory-files-recursively root "\\.md\\'")))

(defun luau-browser--guide-entry (file)
  "Return a native-document entry representing local Markdown FILE."
  (list "guides" (file-name-base file) file ""))

;;;###autoload
(defun luau-browser-search-guides ()
  "Find any local Creator Docs Markdown document by its filename."
  (interactive)
  (let* ((files (luau-browser--markdown-files))
         (root (luau-browser--markdown-root))
         (pairs (mapcar (lambda (file)
                          (cons (file-relative-name file root) file)) files)))
    (unless files
      (user-error "No local Creator Docs Markdown; customize `luau-browser-assets-root'"))
    (let ((picked (completing-read "Creator Docs page: " pairs nil t)))
      (luau-browser-open (luau-browser--guide-entry (cdr (assoc picked pairs)))))))

(defun luau-browser--markdown-hits (query)
  "Find up to the configured limit of Markdown QUERY hits as (FILE LINE TEXT).
Prefer an installed ripgrep executable; otherwise use built-in Elisp."
  (let ((root (luau-browser--markdown-root)) hits)
    (unless root
      (user-error "No local Creator Docs; customize `luau-browser-assets-root'"))
    (when-let* ((rg (executable-find "rg")))
      (with-temp-buffer
        (let ((status (process-file
                       rg nil t nil "--color" "never" "--no-heading" "-n"
                       "--fixed-strings" "--ignore-case" "--max-count" "8" "--max-columns" "240"
                       "--glob" "*.md" "--" query root)))
          (when (eq status 0)
            (goto-char (point-min))
            (while (and (< (length hits) luau-browser-document-search-limit)
                        (re-search-forward
                         "^\\(.+\\):\\([0-9]+\\):\\(.*\\)$" nil t))
              (push (list (match-string-no-properties 1)
                          (string-to-number (match-string 2))
                          (match-string-no-properties 3)) hits))))))
    (unless (executable-find "rg")
      (catch 'done
        (dolist (file (luau-browser--markdown-files))
          (with-temp-buffer
            (insert-file-contents file)
            (goto-char (point-min))
            (let ((case-fold-search t))
              (while (search-forward query nil t)
                (push (list file (line-number-at-pos)
                            (string-trim (buffer-substring-no-properties
                                          (line-beginning-position)
                                          (line-end-position)))) hits)
                (forward-line 1)
                (when (>= (length hits) luau-browser-document-search-limit)
                  (throw 'done nil))))))))
    (nreverse hits)))

(defun luau-browser--hit-candidate (hit root)
  "Format Markdown search HIT relative to ROOT for native completion."
  (format "%s:%d  %s" (file-relative-name (nth 0 hit) root) (nth 1 hit)
          (truncate-string-to-width (string-trim (nth 2 hit)) 130 nil nil t)))

;;;###autoload
(defun luau-browser-search-docs (query)
  "Search the full local Markdown documentation text for literal QUERY.
Results use native minibuffer completion, including Vertico; opening a
hit displays its page in the styled reader, not EWW or a raw source file."
  (interactive (list (read-string "Search Creator Docs text: " nil
                                  'luau-browser-history)))
  (when (string-empty-p query) (user-error "Search text cannot be empty"))
  (let* ((root (luau-browser--markdown-root))
         (hits (luau-browser--markdown-hits query))
         (pairs (mapcar (lambda (hit)
                          (cons (luau-browser--hit-candidate hit root) hit)) hits)))
    (unless hits (user-error "No local Markdown matches for %s" query))
    (let* ((label (completing-read "Documentation match: " pairs nil t))
           (hit (cdr (assoc label pairs)))
           (file (car hit)))
      (luau-browser-open (luau-browser--guide-entry file))
      (when (derived-mode-p 'luau-browser-document-mode)
        (goto-char (point-min))
        (let ((case-fold-search t)
              (text (string-trim (nth 2 hit))))
          (unless (and (not (string-empty-p text))
                       (search-forward text nil t))
            (search-forward query nil t)))))))

;;;###autoload
(defun luau-browser-consult-ripgrep ()
  "Search the docs with optional Consult ripgrep, or native search.
Consult visits matching source files; `luau-browser-search-docs' visits
styled local documentation buffers instead."
  (interactive)
  (unless (luau-browser--markdown-root)
    (user-error "No local Creator Docs checkout configured"))
  (if (and (require 'consult nil t) (fboundp 'consult-ripgrep))
      (consult-ripgrep (luau-browser--markdown-root))
    (call-interactively #'luau-browser-search-docs)))

(defun luau-browser-document--slug (text)
  "Normalize heading TEXT to a Creator Docs-style Markdown fragment."
  (let ((slug (downcase (replace-regexp-in-string
                         "[^[:alnum:] -]" "" text))))
    (replace-regexp-in-string "-+" "-"
                              (string-trim (replace-regexp-in-string " +" "-" slug) "-" "-"))))

(defun luau-browser-document--goto-anchor (anchor)
  "Jump to the Markdown heading denoted by ANCHOR in this document."
  (let ((target (luau-browser-document--slug (url-unhex-string anchor))) found)
    (save-excursion
      (goto-char (point-min))
      (while (and (not found) (re-search-forward "^#+ +\\(.+\\)$" nil t))
        (when (equal (luau-browser-document--slug
                      (match-string-no-properties 1)) target)
          (setq found (line-beginning-position)))))
    (if found (goto-char found)
      (message "No heading matching %s" anchor))
    found))

(defun luau-browser-document--resolve (target)
  "Resolve Markdown TARGET to a local (ENTRY . ANCHOR) when possible.
Never visit filesystem paths outside the configured Creator Docs root."
  (let* ((trimmed (replace-regexp-in-string "[?].*\\'" "" target))
         (components (split-string trimmed "#"))
         (url (car components))
         (anchor (cadr components))
         (path (if (string-match
                    "\\`https?://create\\.roblox\\.com/docs/\\(.*\\)\\'" url)
                   (concat "/" (match-string 1 url)) url))
         (root (luau-browser--markdown-root)))
    (cond
     ((string-empty-p path)
      (and luau-browser--entry (cons luau-browser--entry anchor)))
     ((string-match "\\`/?\\(?:en-us/\\)?reference/engine/\\([^/]+\\)/\\([^/]+\\)\\'" path)
      (let* ((kind (match-string 1 path))
             (name (file-name-sans-extension (match-string 2 path)))
             (entry (cl-find-if
                     (lambda (item) (and (equal (car item) kind)
                                         (equal (nth 1 item) name)))
                     (luau-browser--entries))))
        (when entry (cons entry anchor))))
     ((and root (not (string-match-p "\\`[[:alpha:]]+://" path)))
      (let* ((relative (string-remove-prefix "/" path))
             (base (if (string-prefix-p "/" path) root
                     (file-name-directory
                      (or (luau-browser--documentation-file luau-browser--entry)
                          (nth 2 luau-browser--entry)
                          (expand-file-name "index.md" root)))))
             (candidate (expand-file-name relative base))
             (file (cl-find-if #'file-readable-p
                               (list candidate (concat candidate ".md")
                                     (expand-file-name "index.md" candidate)))))
        (when (and file (file-in-directory-p file root))
          (cons (or (cl-find-if
                     (lambda (entry)
                       (equal (luau-browser--documentation-file entry) file))
                     (luau-browser--entries))
                    (luau-browser--guide-entry file))
                anchor)))))))

(defun luau-browser-document--follow (button)
  "Follow the local Markdown link represented by BUTTON."
  (let* ((target (button-get button 'luau-browser-target))
         (resolved (luau-browser-document--resolve target)))
    (cond
     (resolved
      (if (and (equal (car resolved) luau-browser--entry)
               (cdr resolved))
          (progn
            (luau-browser-document--remember)
            (luau-browser-document--goto-anchor (cdr resolved)))
        (luau-browser-open (car resolved))
        (when (and (cdr resolved) (derived-mode-p 'luau-browser-document-mode))
          (luau-browser-document--goto-anchor (cdr resolved)))))
     ((string-match-p "\\`https?://" target)
      (funcall (luau-browser--web-function) target))
     (t (user-error "No local reference for %s" target)))))

(defun luau-browser-document--linkify ()
  "Turn Markdown links and known API code identifiers into native buttons."
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward "\\[\\([^]]+\\)\\](\\([^)]+\\))" nil t)
      (let ((start (match-beginning 0))
            (end (match-end 0))
            (label (match-string-no-properties 1))
            (target (match-string-no-properties 2)))
        (unless (eq (get-text-property start 'face)
                    'luau-browser-code-block-face)
          (delete-region start end)
          (goto-char start)
          (insert label)
          (make-text-button start (point)
                            'action #'luau-browser-document--follow
                            'luau-browser-target target 'follow-link t
                            'face 'luau-browser-link-face
                            'help-echo (format "Follow %s" target)))))
    (goto-char (point-min))
    (luau-browser--entries)
    (while (re-search-forward "`\\([[:alpha:]_][[:alnum:]_.:]*\\)`" nil t)
      (let* ((begin (match-beginning 1))
             (end (match-end 1))
             (name (match-string-no-properties 1))
             (symbol (car (split-string name "[.:]")))
             (type (if (equal symbol "Enum")
                       (cadr (split-string name "\\.")) symbol))
             (entry (gethash type luau-browser--completion-index)))
        (when (and entry (not (button-at begin))
                   (not (eq (get-text-property begin 'face)
                            'luau-browser-code-block-face)))
          (make-text-button begin end
                            'action #'luau-browser-document--follow
                            'luau-browser-target
                            (format "/reference/engine/%s/%s" (car entry) (nth 1 entry))
                            'follow-link t
                            'face (or (get-text-property begin 'face)
                                      'luau-browser-link-face)
                            'help-echo (format "Read %s" (nth 1 entry))))))))

(defun luau-browser-document-back ()
  "Return to the previous locally viewed documentation page and position."
  (interactive)
  (unless luau-browser--back-stack (user-error "No previous documentation page"))
  (when luau-browser--entry
    (push (cons luau-browser--entry (point)) luau-browser--forward-stack))
  (pcase-let ((`(,entry . ,position) (pop luau-browser--back-stack)))
    (luau-browser-document--show entry position)))

(defun luau-browser-document-forward ()
  "Return to a documentation page visited before going backward."
  (interactive)
  (unless luau-browser--forward-stack (user-error "No forward documentation page"))
  (when luau-browser--entry
    (push (cons luau-browser--entry (point)) luau-browser--back-stack))
  (pcase-let ((`(,entry . ,position) (pop luau-browser--forward-stack)))
    (luau-browser-document--show entry position)))

(defun luau-browser-document-help ()
  "Display the main keys available in the local documentation reader."
  (interactive)
  (message "TAB/S-TAB links · RET follow · l/r history · j/k headings · i TOC · z fold · a API · S text · W web · q quit"))

(defvar luau-browser-document-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "b") #'luau-browser)
    (define-key map (kbd "s") #'luau-browser-search)
    (define-key map (kbd "/") #'luau-browser-search)
    (define-key map (kbd "g") #'luau-browser-document-revert)
    (define-key map (kbd "n") #'outline-next-visible-heading)
    (define-key map (kbd "p") #'outline-previous-visible-heading)
    (define-key map (kbd "TAB") #'forward-button)
    (define-key map (kbd "<backtab>") #'backward-button)
    (define-key map (kbd "RET") #'push-button)
    (define-key map (kbd "z") #'outline-cycle)
    (define-key map (kbd "l") #'luau-browser-document-back)
    (define-key map (kbd "r") #'luau-browser-document-forward)
    (define-key map (kbd "t") #'beginning-of-buffer)
    (define-key map (kbd "a") #'luau-browser-apropos)
    (define-key map (kbd "S") #'luau-browser-search-docs)
    (define-key map (kbd "A") #'luau-browser-search-all)
    (define-key map (kbd "?") #'luau-browser-document-help)
    (define-key map (kbd "v") #'luau-browser-view-source)
    (define-key map (kbd "W") #'luau-browser-open-online)
    (define-key map (kbd "i") #'luau-browser-document-jump-heading)
    (define-key map (kbd "c") #'luau-browser-document-copy-name)
    (define-key map (kbd "j") #'outline-next-visible-heading)
    (define-key map (kbd "k") #'outline-previous-visible-heading)
    (define-key map (kbd "h") #'luau-browser-describe-bindings)
    map)
  "Keymap for native Roblox reference pages.")

(define-derived-mode luau-browser-document-mode special-mode "Luau-Doc"
  "Native, read-only Roblox API documentation mode."
  (setq-local outline-regexp "^\\(#+\\) +")
  (setq-local outline-level (lambda () (length (match-string 1))))
  (setq-local imenu-generic-expression '(("Headings" "^#+ +\\(.+\\)$" 1)))
  (setq-local header-line-format
              (propertize "  ◆  ROBLOX DOCS  •  TAB links  RET follow  l/r history  i headings  S text  a apropos  W web  ? help"
                          'face 'luau-browser-heading-face))
  (outline-minor-mode 1))

(defun luau-browser-document-copy-name ()
  "Copy the currently displayed Roblox reference name."
  (interactive)
  (unless luau-browser--entry (user-error "No Roblox reference displayed"))
  (kill-new (nth 1 luau-browser--entry))
  (message "Copied Roblox symbol: %s" (nth 1 luau-browser--entry)))

(defun luau-browser-document-jump-heading ()
  "Jump to a heading on this page using completion."
  (interactive)
  (let (headings)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "^#+ +\\(.+\\)$" nil t)
        (let ((heading (match-string-no-properties 1))
              (position (line-beginning-position)))
          (push (cons (format "%s  ·  line %d" heading (line-number-at-pos))
                      position)
                headings))))
    (unless headings (user-error "No headings on this reference page"))
    (setq headings (nreverse headings))
    (let* ((choice (completing-read "Heading: " headings nil t))
           (position (cdr (assoc choice headings))))
      (when position
        (goto-char position)
        (when (get-buffer-window) (recenter))))))

(defun luau-browser--render-line (line)
  "Display source documentation LINE in a readable native text form."
  (cond
   ((string-match "^\\(#+\\) +\\(.*\\)" line)
    (let ((face (if (= (length (match-string 1 line)) 1)
                    'luau-browser-heading-face
                  'luau-browser-section-face)))
      (concat (propertize (concat (match-string 1 line) " "
                                  (match-string 2 line) "\n")
                          'face face) "\n")))
   ((string-match "^[[:space:]]*\\(name\\|summary\\|description\\|type\\|returns\\|parameters\\):[[:space:]]*\\(.*\\)" line)
    (concat (propertize (capitalize (match-string 1 line))
                        'face 'luau-browser-kind-face)
            "  " (match-string 2 line) "\n"))
   (t (concat line "\n"))))

(defun luau-browser--yaml-sections (entry)
  "Collect top-level section headings and names from YAML ENTRY.
Only recognized section members are indexed, never nested parameters."
  (let (sections)
    (dolist (item (luau-browser--members entry))
      (let* ((heading (capitalize (luau-browser-member-kind item)))
             (group (assoc heading sections)))
        (if group
            (setcdr group (cons (luau-browser-member-name item) (cdr group)))
          (push (cons heading (list (luau-browser-member-name item)))
                sections))))
    (mapcar (lambda (section)
              (cons (car section) (nreverse (cdr section))))
            (nreverse sections))))

(defun luau-browser--highlight-inline (line)
  "Return a propertized copy of Markdown LINE with code spans emphasized."
  (let ((result (copy-sequence line)) (cursor 0))
    (while (string-match "`\\([^`]+\\)`" result cursor)
      (add-text-properties (match-beginning 0) (match-end 0)
                           '(face luau-browser-inline-code-face) result)
      (setq cursor (match-end 0)))
    result))

(defun luau-browser--render-source (file)
  "Insert local Markdown FILE with styled headings and fenced code.
Code fences are presentation markers, not part of the visible example.
This renderer does not require EWW, a Markdown package or network access."
  (let ((lines (with-temp-buffer
                 (insert-file-contents file)
                 (split-string (buffer-string) "\n")))
        in-code)
    (cl-loop for line in lines
             for index from 0
             while (or (null luau-browser-document-max-lines)
                       (< index luau-browser-document-max-lines))
             do (cond
                 ((string-match "^```\\(.*\\)$" line)
                  (setq in-code (not in-code))
                  (when in-code
                    (let ((language (string-trim (match-string 1 line))))
                      (unless (string-empty-p language)
                        (insert (propertize
                                 (format "  %s\n" (upcase language))
                                 'face 'luau-browser-kind-face))))))
                 (in-code
                  (insert (propertize (concat "    " line "\n")
                                      'face 'luau-browser-code-block-face)))
                 (t (insert (luau-browser--render-line
                             (luau-browser--highlight-inline line))))))))

(defun luau-browser--render (entry)
  "Render ENTRY as a clean, navigable, offline native reference page."
  (let* ((file (nth 2 entry))
         (yaml (string-match-p "\\.ya?ml\\'" file))
         (companion (luau-browser--companion-markdown file))
         (inhibit-read-only t))
    (erase-buffer)
    (insert (propertize (nth 1 entry) 'face 'luau-browser-name-face)
            "   " (propertize (upcase (car entry))
                               'face 'luau-browser-kind-face) "\n")
    (insert (propertize (or (nth 3 entry) "")
                        'face 'luau-browser-description-face) "\n")
    (insert (propertize file 'face 'luau-browser-path-face) "\n\n")
    (if yaml
        (progn
          (dolist (section (luau-browser--yaml-sections entry))
            (insert (propertize (concat "# " (car section) "\n")
                                'face 'luau-browser-heading-face))
            (dolist (member (cdr section))
              (insert "  " (propertize member 'face 'luau-browser-name-face) "\n"))
            (insert "\n"))
          (when companion
            (insert (propertize "# Documentation\n"
                                'face 'luau-browser-heading-face))
            (luau-browser--render-source companion)))
      (luau-browser--render-source file))
    (luau-browser-document--linkify)
    (goto-char (point-min))))

(defun luau-browser-document--show (entry &optional position)
  "Render native ENTRY at POSITION in the current document buffer."
  (setq-local luau-browser--entry entry)
  (luau-browser--render entry)
  (when position (goto-char (min (point-max) position))))

(defun luau-browser-document--remember ()
  "Save the active document location for navigation history."
  (when luau-browser--entry
    (push (cons luau-browser--entry (point)) luau-browser--back-stack)
    (setq luau-browser--forward-stack nil)))

(defun luau-browser-open (entry)
  "Open API ENTRY in the native reader, or a configured web browser.
A single Emacs documentation buffer preserves Info-style navigation history."
  (unless entry (user-error "No Roblox API reference selected"))
  (if (memq luau-browser-document-presentation '(eww external))
      (let ((luau-browser-web-browser luau-browser-document-presentation))
        (luau-browser--online-entry entry))
    (if (not (luau-browser--documentation-file entry))
        (luau-browser--fallback (nth 1 entry) (car entry))
      (let ((buffer (get-buffer-create "*Luau Documentation*")))
        (with-current-buffer buffer
          (unless (derived-mode-p 'luau-browser-document-mode)
            (luau-browser-document-mode))
          (unless (equal luau-browser--entry entry)
            (luau-browser-document--remember))
          (luau-browser-document--show entry))
        (pop-to-buffer buffer)))))

(defun luau-browser-document-revert ()
  "Reload the current native documentation from its local source."
  (interactive)
  (unless luau-browser--entry (user-error "No reference in this buffer"))
  (luau-browser--render luau-browser--entry))

(defun luau-browser--entry-at-point ()
  "Return the indexed type at point, without assuming arbitrary variable types."
  (luau-browser--entries)
  (let* ((name (or (and (fboundp 'luau-roblox-docs--target-at-point)
                         (luau-roblox-docs--target-at-point))
                   (thing-at-point 'symbol t)))
         (qualified (and name
                         (string-match
                          "\\`\\(?:Enum\\|Class\\|Datatype\\)\\.\\([[:alnum:]_]+\\)" name)
                         (match-string 1 name))))
    (or (and qualified (gethash qualified luau-browser--completion-index))
        (and name (gethash name luau-browser--completion-index)))))

(defun luau-browser--member-rows ()
  "Return the current member list's tabulated rows."
  (cl-loop for member in (luau-browser--members luau-browser--member-owner)
           collect
           (list member
                 (vector (propertize (luau-browser--member-short-name member)
                                     'face 'luau-browser-name-face)
                         (propertize (capitalize (luau-browser-member-kind member))
                                     'face 'luau-browser-kind-face)
                         (propertize (luau-browser--member-signature member)
                                     'face 'luau-browser-path-face)
                         (propertize
                          (concat (if (luau-browser-member-deprecated member)
                                      "DEPRECATED  " "")
                                  (luau-browser-member-summary member))
                          'face 'luau-browser-description-face)))))

(defun luau-browser--member-refresh-buffer ()
  "Repopulate only the member browser's tabulated rows."
  (setq tabulated-list-entries (luau-browser--member-rows)))

(defun luau-browser-member-source (&optional member)
  "Visit MEMBER's authoritative YAML declaration at its exact line."
  (interactive)
  (let ((selected (or member (tabulated-list-get-id))))
    (unless selected (user-error "No Roblox member on this row"))
    (find-file-other-window (nth 2 (luau-browser-member-entry selected)))
    (goto-char (point-min))
    (forward-line (1- (luau-browser-member-line selected)))))

(defun luau-browser-document-goto-member (member)
  "Move to MEMBER's heading or summary in a native document buffer."
  (let ((name (luau-browser--member-short-name member))
        (qualified (luau-browser-member-name member))
        found)
    (goto-char (point-min))
    (while (and (not found) (re-search-forward "^#+ +\\(.+\\)$" nil t))
      (let ((heading (match-string-no-properties 1)))
        (when (or (equal heading qualified)
                  (string-match-p
                   (concat "\\`" (regexp-quote name)
                           "\\(?:[[:space:](]\\|$\\)") heading))
          (setq found (line-beginning-position)))))
    (unless found
      (goto-char (point-min))
      (when (search-forward qualified nil t)
        (setq found (line-beginning-position))))
    (when found
      (goto-char found)
      (when (get-buffer-window) (recenter)))
    found))

(defun luau-browser-member-visit (&optional member)
  "Open MEMBER's parent documentation and locate its section if available.
When no companion Markdown exists, use the configured EWW fallback."
  (interactive)
  (let* ((selected (or member (tabulated-list-get-id)))
         (entry (and selected (luau-browser-member-entry selected)))
         (local-doc (and entry (luau-browser--documentation-file entry))))
    (unless selected (user-error "No Roblox member selected"))
    (luau-browser-open entry)
    (when (and local-doc (derived-mode-p 'luau-browser-document-mode))
      (luau-browser-document-goto-member selected))))

(defun luau-browser-member-search (&optional entry)
  "Search members of ENTRY through native Consult/Vertico completion."
  (interactive)
  (let* ((reference (or entry luau-browser--member-owner
                        luau-browser--entry
                        (and (derived-mode-p 'luau-browser-mode)
                             (tabulated-list-get-id))
                        (luau-browser--entry-at-point)))
         (members (luau-browser--members reference)))
    (unless members
      (user-error "No indexed YAML members for this Roblox reference"))
    (luau-browser-member-visit (luau-browser--member-select members))))

(defun luau-browser-member-copy-name ()
  "Copy the selected member name without the owner qualification."
  (interactive)
  (let ((selected (tabulated-list-get-id)))
    (unless selected (user-error "No Roblox member selected"))
    (kill-new (luau-browser--member-short-name selected))
    (message "Copied API member: %s" (luau-browser--member-short-name selected))))

(defun luau-browser-member-copy-qualified-name ()
  "Copy the fully qualified member declaration from the YAML schema."
  (interactive)
  (let ((selected (tabulated-list-get-id)))
    (unless selected (user-error "No Roblox member selected"))
    (kill-new (luau-browser-member-name selected))
    (message "Copied API member: %s" (luau-browser-member-name selected))))

(defun luau-browser-member-online ()
  "Open the owning Roblox API reference online using the configured browser."
  (interactive)
  (let ((entry (or luau-browser--member-owner luau-browser--entry)))
    (unless entry (user-error "No Roblox API reference selected"))
    (luau-browser--online (nth 1 entry) (car entry))))

(defun luau-browser-member-revert ()
  "Reindex local member data and redisplay the current member browser."
  (interactive)
  (luau-browser-refresh)
  (luau-browser--member-refresh-buffer)
  (tabulated-list-print t))

(defvar luau-browser-member-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'luau-browser-member-visit)
    (define-key map (kbd "o") #'luau-browser-member-source)
    (define-key map (kbd "v") #'luau-browser-member-source)
    (define-key map (kbd "s") #'luau-browser-member-search)
    (define-key map (kbd "/") #'luau-browser-member-search)
    (define-key map (kbd "g") #'luau-browser-member-revert)
    (define-key map (kbd "a") #'luau-browser-apropos)
    (define-key map (kbd "S") #'luau-browser-search-docs)
    (define-key map (kbd "W") #'luau-browser-member-online)
    (define-key map (kbd "c") #'luau-browser-member-copy-name)
    (define-key map (kbd "C") #'luau-browser-member-copy-qualified-name)
    (define-key map (kbd "b") #'luau-browser)
    (define-key map (kbd "n") #'next-line)
    (define-key map (kbd "p") #'previous-line)
    (define-key map (kbd "j") #'next-line)
    (define-key map (kbd "k") #'previous-line)
    (define-key map (kbd "h") #'luau-browser-describe-bindings)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Dired-like keymap for structured API member records.")

(define-derived-mode luau-browser-member-mode tabulated-list-mode "Luau-Members"
  "Major mode for native browsing of YAML API members."
  (setq tabulated-list-format
        [("Member" 28 t) ("Kind" 14 t) ("Signature" 45 t)
         ("Summary" 72 t)])
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key (cons "Member" nil))
  (setq-local header-line-format
              (propertize
               "  ◆  API MEMBERS  •  RET read  / search  o YAML  c/C copy  W web  b index  q quit"
               'face 'luau-browser-heading-face))
  (tabulated-list-init-header))

;;;###autoload
(defun luau-browser-members (&optional entry)
  "Open a searchable, categorized member index for the local YAML ENTRY.
When called interactively, use the browser row, documentation page or the
type symbol at point.  No network access occurs while indexing members."
  (interactive)
  (let* ((reference (or entry
                        (and (derived-mode-p 'luau-browser-mode)
                             (tabulated-list-get-id))
                        luau-browser--entry
                        luau-browser--member-owner
                        (luau-browser--entry-at-point)))
         (members (luau-browser--members reference)))
    (unless reference
      (user-error "No Roblox reference at point; select one with `luau-browser'"))
    (unless members
      (user-error "No YAML members indexed for %s" (nth 1 reference)))
    (let ((buffer (get-buffer-create (format "*Luau Members: %s*"
                                              (nth 1 reference)))))
      (with-current-buffer buffer
        (luau-browser-member-mode)
        (setq-local luau-browser--member-owner reference)
        (luau-browser--member-refresh-buffer)
        (tabulated-list-print t))
      (pop-to-buffer buffer))))

;;;###autoload
(defun luau-browser-at-point ()
  "Open local documentation for the Roblox symbol at point.
If the symbol has no local Markdown or YAML source, use the configured
live documentation browser (EWW by default) when fallback is enabled."
  (interactive)
  (require 'luau-roblox)
  (let* ((leaf (thing-at-point 'symbol t))
         (name (or (luau-roblox-docs--target-at-point) leaf))
         (entries (luau-browser--entries))
         (entry (and name (gethash name luau-browser--completion-index))))
    (cond
     ((and entry (or (luau-browser--documentation-file entry)
                     (memq luau-browser-document-presentation '(eww external))))
      (luau-browser-open entry)
      (when (and leaf (not (equal leaf name))
                 (derived-mode-p 'luau-browser-document-mode))
        (when-let* ((member (cl-find-if
                             (lambda (item)
                               (equal (luau-browser--member-short-name item) leaf))
                             (luau-browser--members entry))))
          (luau-browser-document-goto-member member))))
     ((and entry name) (luau-browser--fallback name (car entry)))
     (name (luau-browser--fallback name))
     (entries (luau-browser-open (luau-browser--select entries "Roblox symbol: ")))
     (t (luau-browser--fallback nil)))))

(defun luau-browser--enum-members (entry)
  "Return only the top-level declared item names of enum ENTRY.
Unlike a loose YAML regexp, nested parameter names are not enum items."
  (when (and entry (equal (car entry) "enums"))
    (mapcar #'luau-browser-member-name
            (cl-remove-if-not
             (lambda (item) (equal (luau-browser-member-kind item) "items"))
             (luau-browser--members entry)))))

(defun luau-browser-capf ()
  "Complete API types, enums and known `Enum.TYPE.MEMBER' values.
Candidates include semantic metadata for native completion, Corfu,
Consult, Vertico, and optional documentation previews."
  (when luau-browser-enable-capf
    (let* ((end (point))
           (start (save-excursion (skip-chars-backward "[:alnum:]_.") (point)))
           (prefix (buffer-substring-no-properties start end))
           (entries (luau-browser--entries))
           (enum-path (and (string-match
                            "\\`Enum\\.\\([[:alnum:]_]+\\)\\.\\([[:alnum:]_]*\\)\\'"
                            prefix)
                           (match-string 1 prefix)))
           (enum-type-prefix (and (not enum-path)
                                  (string-match
                                   "\\`Enum\\.\\([[:alnum:]_]*\\)\\'"
                                   prefix)))
           (entry (and enum-path
                       (cl-find-if (lambda (item)
                                     (and (equal (car item) "enums")
                                          (equal (nth 1 item) enum-path))) entries)))
           (members (and entry (luau-browser--enum-members entry))))
      (unless (or (save-excursion (nth 8 (syntax-ppss start)))
                  (not entries))
        (cond
         (members
          (let ((begin (+ start (length "Enum.") (length enum-path) 1)))
            (list begin end (luau-browser--capf-table members "enums")
                  :exclusive 'no
                  :company-kind (lambda (_) 'enum-member)
                  :company-doc-buffer (lambda (_) (luau-browser--capf-doc-buffer entry))
                  :company-location (lambda (_) (cons (nth 2 entry) 1)))))
         (enum-type-prefix
          (let ((types (cl-loop for e in entries
                                when (equal (car e) "enums") collect (cadr e))))
            (when types
              (list (+ start (length "Enum.")) end
                    (luau-browser--capf-table types "enums")
                    :exclusive 'no
                    :company-kind (lambda (_) 'enum)
                    :company-doc-buffer
                    (lambda (name)
                      (luau-browser--capf-doc-buffer
                       (gethash name luau-browser--completion-index)))))))
         ((and (< start end) (not (string-match-p "\\." prefix)))
          (list start end
                (luau-browser--capf-table
                 (delete-dups (mapcar #'cadr entries)) "classes")
                :exclusive 'no
                :company-kind
                (lambda (name)
                  (pcase (car (gethash name luau-browser--completion-index))
                    ("enums" 'enum) ("datatypes" 'struct)
                    (_ 'class)))
                :company-docsig
                (lambda (name)
                  (when-let* ((found (gethash name luau-browser--completion-index)))
                    (nth 3 found)))
                :company-doc-buffer
                (lambda (name)
                  (luau-browser--capf-doc-buffer
                   (gethash name luau-browser--completion-index)))
                :company-location
                (lambda (name)
                  (when-let* ((found (gethash name luau-browser--completion-index)))
                    (cons (nth 2 found) 1))))))))))

(defun luau-browser-flymake (report-fn &rest _args)
  "Report conservative invalid enum member diagnostics to REPORT-FN.
Syntax queries must not move the regexp scanner backwards: `syntax-ppss'
explicitly changes point when passed a position.  Snapshot every match
before parsing and resume at its original end."
  (let ((entries (luau-browser--entries))
        diagnostics)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward
              "\\_<Enum\\.\\([[:alpha:]_][[:alnum:]_]*\\)\\.\\([[:alpha:]_][[:alnum:]_]*\\)\\_>" nil t)
        (let* ((match-start (match-beginning 0))
               (member-start (match-beginning 2))
               (member-end (match-end 2))
               (scan-end (match-end 0))
               (type (match-string-no-properties 1))
               (member (match-string-no-properties 2))
               (entry (cl-find-if (lambda (item)
                                    (and (equal (car item) "enums")
                                         (equal (cadr item) type))) entries))
               (members (and entry (luau-browser--enum-members entry)))
               (in-comment-or-string (save-excursion
                                       (nth 8 (syntax-ppss match-start)))))
          (when (and members (not (member member members))
                     (not in-comment-or-string))
            (push (flymake-make-diagnostic
                   (current-buffer) member-start member-end
                   :warning (format "Unknown Enum.%s.%s in local Roblox API"
                                    type member))
                  diagnostics))
          (goto-char scan-end))))
    (funcall report-fn (nreverse diagnostics))))

(defun luau-browser-corfu-margin-formatter (metadata)
  "Return an official icon formatter for Roblox completion METADATA.
Compatible with Corfu's public margin formatter protocol.  Candidates
from unrelated completion sources are left completely untouched."
  (when (eq (completion-metadata-get metadata 'category) 'luau-roblox-api)
    (let ((kind (or (completion-metadata-get metadata 'luau-browser-kind)
                    "classes")))
      (lambda (_candidate)
        (if-let* ((icon (luau-browser--icon kind)))
            (concat (propertize " " 'display icon) "  ")
          (propertize " ◆ " 'face 'luau-browser-kind-face))))))

(defun luau-browser--capf-table (candidates kind)
  "Return a native completion table for CANDIDATES of API KIND."
  (lambda (string predicate action)
    (if (eq action 'metadata)
        `(metadata (category . luau-roblox-api)
                   (luau-browser-kind . ,kind)
                   (display-sort-function . identity))
      (complete-with-action action candidates string predicate))))

(defun luau-browser--capf-doc-buffer (entry)
  "Return an unobtrusive native documentation preview for API ENTRY."
  (when (and entry (file-readable-p (nth 2 entry)))
    (let ((buffer (get-buffer-create " *Luau CAPF Reference*")))
      (with-current-buffer buffer
        (luau-browser-document-mode)
        (setq-local luau-browser--entry entry)
        (luau-browser--render entry))
      buffer)))

(defun luau-browser-setup ()
  "Enable optional local reference integration in the current Luau buffer."
  (when luau-browser-enable-capf
    (add-hook 'completion-at-point-functions #'luau-browser-capf 90 t))
  (when luau-browser-enable-enum-lint
    (add-hook 'flymake-diagnostic-functions #'luau-browser-flymake nil t))
  (when luau-browser-enable-corfu-icons
    (setq-local corfu-margin-formatters
                (cons #'luau-browser-corfu-margin-formatter
                      (remove #'luau-browser-corfu-margin-formatter
                              corfu-margin-formatters)))))

(define-key luau-browser-mode-map (kbd "m") #'luau-browser-members)
(define-key luau-browser-document-mode-map (kbd "m") #'luau-browser-members)
(define-key luau-browser-document-mode-map (kbd "M") #'luau-browser-member-search)

(defvar luau-browser-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "b") #'luau-browser)
    (define-key map (kbd "s") #'luau-browser-search)
    (define-key map (kbd "/") #'luau-browser-apropos)
    (define-key map (kbd "a") #'luau-browser-apropos)
    (define-key map (kbd "A") #'luau-browser-search-all)
    (define-key map (kbd "t") #'luau-browser-search-docs)
    (define-key map (kbd "R") #'luau-browser-consult-ripgrep)
    (define-key map (kbd "g") #'luau-browser-search-guides)
    (define-key map (kbd "C") #'luau-browser-search-classes)
    (define-key map (kbd "E") #'luau-browser-search-enums)
    (define-key map (kbd "T") #'luau-browser-search-datatypes)
    (define-key map (kbd "G") #'luau-browser-search-globals)
    (define-key map (kbd "L") #'luau-browser-search-libraries)
    (define-key map (kbd "m") #'luau-browser-members)
    (define-key map (kbd "M") #'luau-browser-member-search)
    (define-key map (kbd "o") #'luau-browser-at-point)
    (define-key map (kbd "d") #'luau-browser-at-point)
    (define-key map (kbd "D") #'luau-lsp-diagnose)
    (define-key map (kbd "e") #'luau-roblox-doc-at-point)
    (define-key map (kbd "w") #'luau-roblox-doc-at-point)
    (define-key map (kbd "r") #'luau-browser-refresh)
    (define-key map (kbd "?") #'luau-browser-describe-bindings)
    (define-key map (kbd "v") (lambda () (interactive)
                                    (customize-variable 'luau-browser-web-browser)))
    (define-key map (kbd "c") (lambda () (interactive)
                                    (customize-variable 'luau-browser-assets-root)))
    map)
  "Luau-local API navigation prefix for browsing and documentation.")

(provide 'luau-browser)
;;; luau-browser.el ends here
