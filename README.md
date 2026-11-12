<div align="center">

# Luau Mode

**Luau and Roblox development in Emacs**

A standalone major mode with structured editing, optional Luau LSP,
Rojo project tools, and an offline-first Roblox API reader.

</div>

---

## What you get

| Area | Included |
| --- | --- |
| Editing | Luau syntax highlighting, indentation, block navigation, Imenu and Eldoc |
| Language server | Optional `lsp-mode` or Eglot integration with `luau-lsp` |
| Roblox | Local API browsing, completion, member lookup and opt-in enum diagnostics |
| Rojo | Project-root discovery, per-project serve processes and LSP sourcemaps |
| Tooling | StyLua formatting, analysis commands and a complete `make check` quality suite |

`luau-mode` is independent of `lua-mode`. It supports `.luau` files by
 default; `.lua` association is optional. Complex Luau types and nested
interpolations are not a full semantic parser—use `luau-lsp` for semantic
analysis.

## Install

**Requirements:** GNU Emacs 31.1 or newer. A language server, Rojo, StyLua,
and Roblox documentation assets are optional and are not installed by this
package.

Clone the source and add it to your Emacs configuration:

```sh
git clone https://github.com/laluxx/luau-mode.git ~/.emacs.d/site-lisp/luau-mode
```

```elisp
(use-package luau-mode
  :load-path "~/.emacs.d/site-lisp/luau-mode"
  :mode "\\.luau\\'")
```

Without `use-package`:

```elisp
(add-to-list 'load-path "~/.emacs.d/site-lisp/luau-mode")
(require 'luau-mode)
```

For ordinary Lua files, enable association explicitly:

```elisp
(setq luau-associate-lua-files t)
```

## Language server

Install [`luau-lsp`](https://github.com/JohnnyMorganz/luau-lsp) separately
and make sure it is on `PATH`. The default command is **`luau-lsp lsp`**;
`luau-lsp` without the `lsp` subcommand is not the stdio server command.
The mode does not install or download a client or server.

By default, `luau-lsp-backend` is `auto`: it uses `lsp-mode` when installed
and otherwise uses Emacs' built-in Eglot. You can select a backend or disable
language services:

```elisp
(use-package luau-mode
  :load-path "~/.emacs.d/site-lisp/luau-mode"
  :mode "\\.luau\\'"
  :custom
  (luau-lsp-backend 'auto) ; auto, lsp-mode, eglot, or none
  (luau-lsp-command '("luau-lsp" "lsp")))
```

File-backed Luau buffers start the configured client automatically when the
server is available. Rojo buffers also follow `luau-rojo-automatic-lsp`.
Only one of `lsp-mode` and Eglot manages a buffer at a time. LSP settings,
including platform, Rojo sourcemap generation, and extra definition files,
are available in `M-x customize-group RET luau-lsp RET`.

- `C-c C-s` — start or ensure the configured language server.
- `C-c C-k` — request live LSP hover documentation.
- `C-c C-b D` — diagnose the current LSP setup.

## Roblox API references

The native API browser reads a local Creator Docs checkout. The assets are
not bundled. Set `luau-browser-assets-root` to a directory containing
`roblox-creator-docs/` (and optionally `engine-reference-svg-icons/`), or
place the checkout where the mode can discover it from the project. Opening a
Luau file does not download Creator Docs assets or Roblox definitions.

```elisp
(setq luau-browser-assets-root "/path/to/roblox-docs-assets")
```

`C-c C-d` opens documentation for the Roblox symbol or member at point;
`C-c C-o` is an alias. Local Markdown opens in a native, link-following
reader. If local content is unavailable, an explicit documentation request
uses the configured online fallback. Customize `luau-browser-online-fallback`,
`luau-browser-document-presentation` (`native`, `eww`, or `external`), and
`luau-browser-web-browser` to change that behavior.

The browser indexes local API YAML and Markdown for completion, API search,
member navigation and documentation. It can provide metadata and previews to
Emacs completion frameworks; optional Corfu icons remain buffer-local. Enum
member linting is opt-in with `luau-browser-enable-enum-lint`.

Roblox type definitions for the language server are separate from the local
browser corpus: definitions describe engine types, while Rojo sourcemaps map
files to DataModel instances. Modern `luau-lsp` releases bundle Roblox types
by default. To explicitly install or inspect cached official definitions:

1. Run `M-x luau-roblox-api-install` in a Luau buffer.
2. Run `M-x luau-lsp-restart` so the server reloads its configuration.
3. Run `M-x luau-roblox-api-status` or press `C-c C-u` to inspect the active source.

Downloads happen only when the install command is explicitly invoked. The
cache is outside the project tree; downloaded files are validated and replaced
atomically.

### API navigation keys

`C-c C-b` is a Luau-local prefix. The main entry points are:

| Key | Action |
| --- | --- |
| `b` | Open the local API index |
| `s` | Search API symbols |
| `a` or `/` | Search all indexed API declarations and members |
| `C`, `E`, `T`, `G`, `L` | Search classes, enums, datatypes, globals or libraries |
| `m` / `M` | Browse members of the type at point / search members |
| `t` / `g` | Search local Markdown text / find guide pages by path |
| `R` | Search the local docs with Consult ripgrep, when available |
| `o` | Open documentation at point |
| `e` or `w` | Open live Roblox documentation explicitly |
| `r` | Refresh local API caches |
| `c` | Customize the documentation asset root |
| `?` | Describe browser bindings |

In the native reader, `TAB` and `S-TAB` move between links, `RET` follows a
link, `l` and `r` move through page history, `i` selects a heading, `j`/`k`
move between headings, `z` folds a section, and `W` opens the page online.

## Editing and navigation

The mode provides syntax-aware indentation, Luau and Roblox font-lock,
comment handling, defun navigation, Imenu, hide/show support, electric
indentation, and an optional `luacheck` Flymake backend. Use `M-x
customize-group RET luau RET` for core editing settings; additional groups
include `luau-lsp`, `luau-interface`, `luau-browser`, `luau-rojo`, and
`luau-tools`.

The structural interface adds cached source declarations to Imenu, local
function signatures to Eldoc, and matching overlays for Luau block keywords.
When point is on a highlighted keyword:

| Key | Destination |
| --- | --- |
| `M-n` | Matching end of the highlighted pair |
| `M-p` | Matching beginning of the highlighted pair |
| `C-c C-j` | Declaration picker / Imenu |

The keymap is buffer-local. The matching scanner ignores strings and comments
and handles nested blocks.

## Rojo and project tools

In a project identified by `default.project.json`, the mode discovers the
project root and keeps Rojo serve processes separate by root. Language-server
sourcemap generation is configurable. Project commands are available from
Luau buffers:

| Key | Action |
| --- | --- |
| `C-c C-z` | Start Rojo serve |
| `C-c C-x` | Stop this project's Rojo process |
| `C-c C-i` | Inspect saved `Workspace.Camera` properties |
| `C-h v` | Browse source symbols through the active LSP client |

The source-symbol browser reports declarations in the workspace; it does not
inspect live Studio state.

## Other commands

| Key | Command |
| --- | --- |
| `C-c C-f` | Format the buffer with StyLua |
| `C-c C-a` | Analyze the saved file with the configured Luau CLI |
| `C-c C-r` | Refontify after changing font-lock options |
| `C-c C-t` | Run the package quality checks from Emacs |

Formatting and analysis require their corresponding external executables.
The formatter leaves the buffer unchanged if the external formatter fails.

## Development checks

Run the complete suite from the repository root:

```sh
make check
```

The suite includes strict and ordinary byte compilation, isolated package
installation, ERT regressions, Checkdoc, package-lint, Python tooling tests,
static and package audits, and editor benchmarks. It continues through the
gates after failures, writes detailed logs under `.build/reports/`, creates a
shareable diagnostic archive, and exits nonzero if any required gate fails.
`make help` lists focused targets such as `make test-interface` and
`make compile-strict`.

## Project contents

| Path | Purpose |
| --- | --- |
| `luau-mode.el` | Major mode, editing behavior and Rojo commands |
| `luau-lsp.el` | Optional `lsp-mode` and Eglot integration |
| `luau-interface.el` | Imenu, Eldoc and matching block navigation |
| `luau-browser.el` | Local Roblox API browser and documentation reader |
| `luau-roblox.el` | Explicit Roblox definition and documentation cache |
| `luau-make.el` | Emacs interface to the quality checks |
| `test/`, `tests/` | Regression suites |
| `tools/`, `bench/` | Build, diagnostics, audits and benchmarks |

## License and attribution

GPL-3.0-or-later. The standalone editing engine is adapted from GNU Emacs'
`lua-mode.el`; its original authors and license notices are retained in the
source. Luau-specific code and the Roblox/Rojo integrations are maintained in
this project.
