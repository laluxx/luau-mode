# Luau Mode — independent Emacs major mode

### Cycle 11 installation / source identity

If your `make check` still displays **16 checks**, you are running Cycle 09,
not this package. Cycle 11 runs **17** checks, including `test-interface`.
The header also prints **Package 0.9.1 | Cycle 11** (actual local source data).

For a complete checkout replacement, run this from your shell after downloading
`luau-mode-cycle-11-full.tar.gz` (do not extract inside `luau-mode/`):

```sh
tar -xzf /path/to/luau-mode-cycle-11-full.tar.gz -C ~/.config/emacs/lisp/
cd ~/.config/emacs/lisp/luau-mode
make check
```

Restart Emacs to clear any previously loaded `.el`/`.elc` definitions. The
archive never erases existing local files or your Emacs init settings.
Existing `.elc` files are cleared by the compilation checks.


**Author:** laluxx  
**License:** GPL-3.0-or-later  
**Emacs:** 31.1+ (Lua core uses Emacs 31 rx forms)  
**Cycle:** 08 (Roblox API syntax and MELPA stabilization)

`luau-mode` is a standalone Luau major mode adapted from the complete GNU Emacs `lua-mode.el` supplied for Cycle 01. It owns its own `luau-` namespace rather than requiring `lua-mode`, and preserves the upstream GNU Lua authors' attribution and license. The former Bloblox Rojo functionality is included directly under canonical `luau-` names.

Cycle 02 added the independent `luau-lsp.el` module, direct **lsp-mode** support, Eglot fallback, an integrated configuration doctor, and a report-producing Make system adapted from the supplied Monad Mode project.

## Installation

Extract the complete archive, then add its directory to Emacs' `load-path`:

```elisp
(add-to-list 'load-path (expand-file-name "~/path/to/luau-mode"))
(require 'luau-mode)
```

To integrate with the existing `use-package lsp-mode` in your `init.el`, leave your current `lsp-mode` declaration as is and add:

```elisp
(use-package luau-mode
  :load-path "~/path/to/luau-mode"
  :mode "\\.luau\\'"
  :custom
  (luau-lsp-backend 'auto)                   ; choose installed lsp-mode first
  (luau-lsp-command '("luau-lsp" "lsp"))      ; use an absolute path if needed
  (luau-lsp-auto-start t)
  (luau-lsp-multi-root t)
  (luau-lsp-idle-delay 0.1)
  (luau-lsp-enable-symbol-highlighting nil)
  (luau-lsp-headerline-breadcrumb-enable nil)
  (luau-lsp-ui-doc-enable nil)
  (luau-lsp-ui-doc-show-with-mouse nil)
  (luau-rojo-automatic-lsp t)
  (luau-rojo-project-file "default.project.json"))
```

**Important:** `luau-lsp` must be installed and discoverable via `PATH`, or set an absolute path as the first item in `luau-lsp-command`. lsp-mode is optional; if absent, Emacs' built-in Eglot is used. Neither the server nor a client is silently installed by this package.

The official Luau LSP command is **`luau-lsp lsp`**, which speaks LSP over standard input/output. `luau-lsp` alone is *not* the stdio server invocation. The client is registered for `luau-mode` with language ID `luau`, supports multiple workspace roots, and respects the configured command at each start. **Cycle 06 fix:** registration happens when a Luau buffer initializes, before its user LSP hook. This avoids the `Unable to calculate the language` warning even if you invoke `lsp` yourself in your existing init file; registration no longer waits for an available server executable.

## LSP backend behavior

- `luau-lsp-backend = auto` (default) chooses `lsp-mode` when found in Emacs' load path; otherwise uses Eglot.
- `luau-lsp-backend = lsp-mode` requires installed `lsp-mode`, without silently switching to Eglot.
- `luau-lsp-backend = eglot` always uses Eglot.
- `luau-lsp-backend = none` disables language servers.
- Automatic startup occurs for file-backed Luau buffers when a server binary and client are available; Rojo buffers also respect `luau-rojo-automatic-lsp`.
- The code never deliberately launches lsp-mode and Eglot simultaneously in the same buffer. If the other client already owns the buffer, a manual start raises a useful error.
- Eglot configuration and server mapping are **buffer-local**; your global Emacs language-server preferences remain unchanged.

LSP configurations expose `luau-lsp.platform.type`, Rojo sourcemap generation, project filename, sourcemap filename, inclusion of non-scripts, Rojo path, and FFlag synchronization. Extra custom definitions are passed as CLI flags (`--definitions:@label=FILE`). Pinned checkout types remain optional because modern Luau LSP bundles Roblox API types by default. Changing a setting generally requires restarting the language-server workspace.


## Cycle 07: Roblox Studio API definitions and documentation

`luau-lsp` may report `Unknown type 'Vector3'`, `Unknown type 'CFrame'`,
`Unknown type 'Camera'`, or `Unknown global 'workspace'` when its current
workspace has no Roblox declarations.  This is separate from Rojo sourcemaps:
**definitions define engine classes and globals**, while **sourcemaps map
source files to instances inside the game's DataModel**.  A sourcemap alone
cannot supply the `Vector3` type.

Official upstream luau-lsp versions can provide Roblox types out of the
box.  For servers where that is not working, Cycle 07 adds the
`luau-roblox.el` module.  It can use official API assets directly from a
local, managed cache, adding `--definitions:@roblox=<file>` and
`--docs=<file>` to the actual LSP command.

**One-time editor setup**, in a Luau source buffer:

```text
M-x luau-roblox-api-install
M-x luau-lsp-restart
```

The first command explicitly downloads the official Roblox API declaration
and documentation files from the endpoints documented in upstream
[editor-client setup](https://github.com/JohnnyMorganz/luau-lsp/blob/main/editors/README.md).
The second restarts `lsp-mode` or Eglot so the **server actually reloads**
them.  No download occurs simply because you opened a `.luau` file.

Use `M-x luau-roblox-api-status` (or `C-c C-u`) to see the active source,
security level and cache paths.  `M-x luau-lsp-diagnose` now also reports
whether it is using the built-in API or explicit definitions.  `C-c C-k`
continues to show hover documentation from the live language server.

Customize via `M-x customize-group RET luau-roblox RET`:

- `luau-roblox-api-source`: `auto` (cached if installed), `bundled` (the
  server's own types), or `cached` (error when definitions are missing).
- `luau-roblox-api-security`: `None` for ordinary games (default), or
  `PluginSecurity`, `LocalUserSecurity`, `RobloxScriptSecurity` as required.
- `luau-roblox-api-cache-directory`, `luau-roblox-api-definition-override`,
  `luau-roblox-api-documentation-override`, and the documentation toggle.
- CDN endpoints and download timeout, if your setup needs them changed.

API files are stored **outside** your Rojo project under Emacs' user
configuration directory.  Every download uses HTTPS, validates the content,
and replaces the corresponding cached file atomically.  No Roblox API
stubs are fabricated.  Restart the server after changing sources or the
security level.  The complete `make check` suite tests the configuration
logic and cache handling without requiring network access.

If the errors persist *after* installing and restarting, inspect the actual
client with `M-x luau-lsp-diagnose` and the `luau-lsp` executable/version.
Make sure `luau-lsp-command` points to the server you expect, that another
LSP client has not taken over the buffer, and that the workspace is rooted
where your `default.project.json` lives.  A fresh local build may differ
from the documented upstream server.

## Cycle 08: Roblox API green-gate repairs

Cycle 07's native `make check` on GNU Emacs 32.0.50 ran **45/45 ERT
regressions**, but strict byte-compilation, Checkdoc, and package-lint
reported errors in the new `luau-roblox.el` file.  Cycle 08 corrects:

- Emacs' `?[` reader warning by writing explicit escaped punctuation
  character literals (`?\[` and `?\{`) in the JSON payload validator.
  The same reader issue broke `check-parens` as used by Checkdoc.
- An ineffective `Package-Requires` header in a non-main package source.
  The package requirements are declared exclusively in `luau-mode.el`.
- An undeclared `luau-roblox-api-status` call target, reported by the
  native compiler when compiling the main major-mode source.

Two additional ERT tests validate source readability and the
`C-c C-u` status-command binding.  The offline package audit now flags
these three regressions before native compilation.  No new user-facing
features have been added.

The command to run remains **`make check`**.  Its report TAR.GZ is the
source of truth for whether a cycle passes all 15 native gates; an
offline source audit alone is not a replacement for native Emacs checks.

## Key bindings

| Key | Command | Scope |
| --- | --- | --- |
| `C-c C-s` | `luau-setup-language-server` / `luau-lsp-ensure` | Luau |
| `C-c C-k` | `luau-lsp-show-doc` (lsp-ui when available, or client fallback) | Luau |
| `C-c C-d` | `luau-lsp-diagnose` | Luau |
| `C-c C-u` | `luau-roblox-api-status` | Luau |
| `C-c C-a` | `luau-analyze-file` | Luau |
| `C-c C-f` | `luau-format-buffer` (StyLua) | Luau |
| `C-c C-z` | `luau-rojo-serve` | Rojo |
| `C-c C-x` | `luau-rojo-stop` | Rojo |
| `C-c C-i` | `luau-inspect-camera` | Rojo |
| `C-h v` / `C-c C-v` | `luau-project-variables` | Rojo |

`C-c C-k` is a **local key**, so there is no need for a global `global-set-key` binding to the optional `lsp-ui-doc-show` command. Outside Luau buffers, Emacs keeps its other bindings.

Workspace variable browsing works with either client. This is LSP source symbol navigation, **not** live Roblox game state. Rojo serve processes and log buffers are isolated by canonical project root.

## Editing features from the original standalone port

The complete baseline Lua engine remains owned by the `luau-` namespace: syntax propertization, long bracket strings and comments, indentation, matching Lua blocks, defun navigation, Imenu, hide-show, paragraph filling, electric indentation, comint process commands, optional `luacheck` Flymake, and online documentation lookup. Luau extensions include type declarations, generics, Roblox globals, directives, interpolations, and Luau operators. Complex type parsing and nested interpolations are not yet parser-complete; use LSP for semantic accuracy.

Custom options live under `M-x customize-group RET luau RET`, `luau-lsp`, `luau-font-lock`, `luau-rojo`, and `luau-tools`. Cycle 04 retains **91 defcustom options and 69 defface definitions**, including configuration doctor statuses.

## Make development workflow (ported from Monad Mode)

**The one and only local command to run at the end of every cycle is:**

```bash
cd ~/path/to/luau-mode
make check
```

This runs the *complete* non-destructive quality matrix (16 independent tasks, including dependency bootstrap, both compilation modes, all ERT suites, Checkdoc, package-lint, offline audits and benchmarks), continues after individual failures, and **always** creates one shareable archive under `.build/luau-make-report-*.tar.gz`. The archive contains complete logs, machine info, a JSON/JUnit report and hashes of the current source so the next development cycle can match results to code exactly. The command deliberately exits nonzero if any check failed. Upload the TAR.GZ for the next cycle; the logs are complete and no results are falsely marked as passed.

Other useful commands:

```bash
make help                 # discover targets and output controls
make quickcheck           # strict compile, ERT, doctor, Python and static checks
make check                # ONE command: all gates and diagnostic TAR.GZ
make test-install         # isolated package.el install, autoload and face smoke test
make test                 # all recursive ERT tests
make test-lsp             # lsp-mode and Eglot regression tests only
make compile-strict       # byte-compile; warnings fail the build
make doctor               # recursive Checkdoc and package-lint (both required)
make bootstrap            # optional manual package-lint installer (automated by check)
make failures             # inspect latest unresolved failures
make triage               # rerun only failed targets
make dashboard            # full overview of tested vs untested targets
make history              # recorded runs
make bundle               # archive latest saved diagnostic report
make verify-delta DELTA=../luau-mode-cycle-03-delta.tar.gz
```

**Cycle 04 hang protection:** test targets discover and execute each ERT test in a
fresh batch Emacs process. Each test has an independent timeout (default eight
seconds); the runner terminates the whole process group when a test hangs and
logs its exact name. This prevents the four 600-second stalls in the Cycle 03
report from hiding their originating tests. Benchmarks are capped at twenty
seconds per target and general tasks at seventy-five seconds by default.
`LUAU_ERT_TIMEOUT` and `LUAU_TIMEOUT` can be overridden. Timeout results are
failures and remain in the archived report, never converted to skips.

The Make runner uses the same styled, color-consistent stdout/stderr conventions as Monad Mode and preserves source `file:line` errors. ANSI colors are emitted for terminals by default; `M-x luau-make-check` enables a color-aware Emacs compilation buffer. Set `LUAU_COLOR=always` to force colors or `LUAU_ASCII=1` for plain status glyphs; full per-step logs, a JSON report, and JUnit XML remain under `.build/reports/`.

**Package-lint is mandatory for `make doctor`.** `make check` first bootstraps package-lint into the isolated `.packages` directory when missing (network access on the first run), then runs the doctor. If the installation fails (for example offline), the failure is included in the final bundle, and no check is falsely marked as passed. `make doctor` alone still fails closed if package-lint is unavailable. No network is needed for `make test-tools` or `make test-static`.

### Cycle 09 — installed-package validation

This cycle adds a real `package.el` multi-file archive as a local **test
fixture**, using Emacs' documented `NAME-VERSION.tar` layout. The archive
includes `luau-mode-pkg.el`, the four public modules, README, and GPL license;
it deliberately excludes ERT tests, developer tools, benchmarks, caches,
bytecode and Rojo source files.

`make check` runs `test-install` after strict compilation: the command builds
`.build/release/luau-mode-0.9.0.tar` from the source Version and
Package-Requires headers, installs it using `package-install-file` into an
isolated temporary Emacs profile, and validates generated `.luau` autoloads,
module loading from the installed directory, syntax faces and key bindings.
The test performs no network requests, and cleans its temporary profile.
If installation fails, **the whole quality matrix fails**; it is not
silently skipped. Offline Python tests also validate deterministic archives
and reject missing files, symlinks or malformed package metadata.

The builder is a local package smoke fixture, *not* a replacement for MELPA's
own package-build process. The existing `URL: https://luau.org` header refers
to the Luau language site, **not an owner-controlled repository**. Replace it
with the actual project homepage before submitting a MELPA recipe.

### Validation status of this archive

In the authoring environment, there was **no Emacs executable**. The standalone Python diagnostics/archiving and ERT-supervisor test suite (37 tests), a 15-point package audit, and static Elisp structure checks ran successfully. Emacs byte compilation, Checkdoc, package-lint, ERT, and actual live server handshakes **have not been executed here**; they require the local run above. A passed Python test must not be interpreted as a passed Emacs test.

## Cycle layout

```text
luau-mode/
  luau-mode.el                standalone major mode and Rojo integration
  luau-lsp.el                 optional lsp-mode and Eglot clients
  Makefile                    public quality targets + private raw recipes
  tools/                     styled runner, reports, delta verifier, Python tests
  test/                      headless ERT and strict doctor runners, LSP tests
  tests/                     original Cycle 01 baseline tests
  bench/                     observational editor benchmarks
  docs/                      cycle notes and incremental archive manifest
  examples/                  sample typed Luau
  COPYING                    original GNU GPL license
```

### Reference documentation

- [luau-lsp editor protocol and `lsp` command](https://github.com/JohnnyMorganz/luau-lsp/blob/main/editors/README.md)
- [luau-lsp Rojo and settings](https://github.com/JohnnyMorganz/luau-lsp)
- [lsp-mode: adding a language](https://emacs-lsp.github.io/lsp-mode/page/adding-new-language/)
- [Luau syntax](https://luau.org/syntax/)

## Next work

Future cycles should harden parsing for generic types, typed function parameters, nested interpolated strings and `if` expressions; add LSP integration tests against a real `luau-lsp` binary and real Emacs, and use the submitted diagnostics bundle to fix every Checkdoc, package-lint, byte-compiler and ERT regression before claiming quality-gate parity.

## Cycle 03: resolved diagnostic root causes

The reported `void-variable luau-constant-face` / `luau-keyword-face` failure was caused by font-lock match rules evaluating unquoted custom face symbols as variables. The affected rules now use quoted face symbols. `luau-enable-legacy-luacheck` is declared before the derived mode references it, preventing the previously reported free-variable warning. Benchmark files now explicitly load the option definitions before lexical bindings. Eglot stub variable defaults have been added for isolated tests. Rojo process IDs are canonicalized independent of trailing root separators.

Files ending in **`.luau`** (including `.server.luau` and `.client.luau`) are automatically associated with `luau-mode` via a package autoload. To avoid interfering with another Lua editor, **`.lua` is now opt-in** through `luau-associate-lua-files`. Activate `M-x luau-refontify-buffer` (`C-c C-r`) after changing font-lock options. The custom faces inherit their appearance from the current theme's standard Emacs `font-lock-*`, `error`, `warning`, and `success` faces rather than fixed RGB colors.

### Publishing preparation

A new offline package audit verifies metadata, author attribution, source-mode autoloads, unique faces/custom options, LSP registration, and absence of the unquoted-face regression. This is **not** a replacement for Checkdoc or package-lint: those must pass in a real Emacs before submitting a recipe to MELPA. See `docs/MELPA-READINESS.md` for the remaining release gates.

**Cycle 05 input:** run `make check` on the final extracted Cycle 04 archive, then upload `.build/luau-make-report-*-check.tar.gz`. No additional command is needed.

## Cycle 04: November 10, 2026 local diagnostics

The uploaded **text summary** of Cycle 03 (not its complete report TAR.GZ)
showed 4/15 steps each stuck for 600 seconds, plus strict compilation, LSP,
checkdoc, package-lint, and tooling-test failures. Because only the summary
was available, exact ERT backtraces and the 171 lint messages remain unknown.

Cycle 04 corrects `luau-process-init-code` declaration ordering, preserves
font-lock match-data during syntax inspection, uses a bounded per-test ERT
supervisor, reduces the font-lock benchmark workload, adjusts LSP registration
mock expectations, and marks auxiliary `.el` files as secondary package files.
The remaining native quality gates must be verified on GNU Emacs; no MELPA
release claim is made. The source package's true repository URL must be added
once the author has published the upstream repository.

## Cycle 05: semantic CLI styling and targeted regressions

The diagnostics UI now applies one consistent design to **every** Make check:
cyan `› RUN`, green `✓ PASS`, red `✗ FAIL`, and yellow `! TIMEOUT`.
ANSI styling is added **after** field padding, so different status lengths
never shift the timing, metric, or target columns. The source logs, JSON and
JUnit XML remain uncolored and machine-readable. `NO_COLOR=1` disables ANSI;
`LUAU_COLOR=always` forces it in an ANSI-capable terminal.

To launch the **same** `make check` matrix directly from Emacs and see genuine
colorized status faces in a `*Luau Make Check*` compilation buffer, use:

```text
M-x luau-make-check
```

Or run `make check` from any terminal in the package root. `C-c C-t` is bound
to `luau-make-check` in Luau buffers. Both routes produce the same uploadable
`.build/luau-make-report-*-check.tar.gz`. This command changes neither the
user's global `compilation-filter-hook` nor the user's global LSP settings.
The Emacs command can be customized via `M-x customize-group RET luau-make RET`.

The root-level mode uses a version-sensitive buffer replacement API to avoid
Emacs 31.1's obsolete-function warning without dropping Emacs 30 support.
Roblox global fontification now preserves regexp match data during syntactic
checks, addressing the reported pathological font-lock runtime. Tests now
also bind optional `lsp-mode` / Eglot globals as special variables so compiled
ERT tests do not accidentally shadow them lexically.

`make doctor` checks every project-owned `.el` with Checkdoc, but
**package-lint is restricted to shipped package files** (`luau-mode.el`,
`luau-lsp.el`, `luau-make.el`). Test runners and benchmark scripts are not
installable packages; package-lint on them previously produced spurious
`No such file .../bench/luau-mode.el` errors. They remain checked through
Checkdoc, strict byte compilation and tests. The uploadable archive is still
created after failures, and real GNU Emacs validation is required before
MELPA publication. A verified public repository URL is still needed.

## Cycle 06 quality and compatibility notes

- The minimum Emacs version is **31.1** because the GNU Emacs Lua base
  uses `rx` forms reported as 31.1+ by the current package-lint. This package
  does not claim Emacs 30 compatibility.
- Legacy `bloblox/` aliases and `run-luau` were removed from the distributed
  source to meet MELPA naming conventions. Use `luau-rojo-serve`,
  `luau-rojo-stop`, `luau-inspect-camera`, `luau-project-variables`,
  and `luau-run` respectively.
- `luau--eglot-project-variables` uses public `jsonrpc-request` and
  `eglot-current-server` instead of Eglot's internal workspace-symbol cache.
- The metadata `URL` currently links to upstream Luau language documentation,
  **not a repository for this package**. Replace it with the actual published
  package repository URL before MELPA submission.
- Each font-lock matcher performs syntax lookups without changing the search
  cursor or regexp match data. `make check` is still the only full native gate.

## Cycle 10 — Structural UI and Roblox reference

The standalone `luau-interface.el` module adapts the best isolated interaction
ideas from laluxx's Monad Mode without using its parser or depending on Monad.
Its cached Imenu index lists functions, exported types and `require` bindings in
source order.  Use `C-c C-j` for the colored declaration picker; ordinary
`M-x imenu` also uses the index.  Annotations include the type signature and
the immediately preceding `---` documentation comment when available.
`completion-extra-properties` supplies the standard annotation function, so
Vertico and Marginalia can present the metadata without either being required.

When the cursor is inside a call to a locally indexed function, Eldoc shows its
parameter list and emphasizes the current parameter.  This fallback coexists
with server-provided LSP hovers (`C-c C-k`).  Matching control-flow keywords
(`function`/`if`/`for`/`while`/`do`/`repeat` and `end`/`until`) use the
`luau-interface-match-face` (inherits `region`) and
`luau-interface-match-current-face`.  Both services can be disabled using
`M-x customize-group RET luau-interface RET`.

`C-c C-o` opens the **live Roblox Creator Hub** reference for the symbol at
point.  The default `luau-roblox-docs-browser` is `eww`, keeping the reference
inside Emacs; customize it to `browse-url` for full JavaScript rendering.
Known Roblox types (`Vector3`, `CFrame`), services (`Workspace`) and enums
resolve to their documented category; unknown symbols require a user-selected
reference category rather than guessing a possibly invalid URL.  This
on-demand browser command does **not** download or update API definition files.
Use `M-x luau-roblox-api-install` for explicit cached type definitions and
`M-x luau-lsp-restart` to apply them to the external language server.

`C-h v` is a buffer-local Luau source-symbol browser while in Luau Mode.  It
shows **workspace source declarations**, not live Studio variables, and
requires a connected LSP.  Its completion candidates and annotations use
standard Emacs minibuffer APIs; installing Marginalia is optional.

This cycle adds `test-interface` to the canonical `make check` suite.  The
Roblox/LSP integration still requires a live Studio/Rojo project to verify
server-specific API availability; passing mock tests alone is not proof of a
working server connection.
