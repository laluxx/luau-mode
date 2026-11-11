# MELPA readiness — Luau Mode by laluxx

Status: **candidate**, not yet verified for submission. The package is
independent from `lua-mode`, and honors the original Lua code's GPL license
and attribution. No upstream source URL has been supplied, so the recipe
cannot be submitted until the maintainer publishes the code on a supported
public Git forge.

## Entry point

Run **`make check`** in the package directory after every cycle. This performs
all non-destructive quality gates. It attempts to install `package-lint` into
`.packages/` on first use. It includes strict byte compilation, all ERT
regressions, individual focused suites, recursive Checkdoc for all `.el` files and package-lint for distributed
package modules (not benchmark or test entrypoints),
Python tooling checks, source/package audits, and benchmarks. A failing gate
does not stop subsequent gates. In all cases it writes
`.build/luau-make-report-*-check.tar.gz`; return status is nonzero on failure.

## Required release gates

- [x] Cycle 08: GNU Emacs 32.0.50 `make check` passed all 15 gates, zero compiler warnings
- [ ] Cycle 09: new 16-gate `make check` including real installed-package smoke test
- [ ] `package-lint` full PASS for all distributed package modules;
      Checkdoc + byte compilation must pass for all auxiliary `.el` files
- [ ] ERT confirms `.server.luau` auto-mode activation and all custom faces
- [ ] Installed `lsp-mode` recognizes `luau-mode` as language `luau`
- [ ] Handshake with the installed `luau-lsp lsp` executable on a Rojo project
- [ ] No duplicate LSP startup when another client manages a buffer
- [ ] Manual smoke test of indentation, strings, type declarations, and Imenu
- [ ] Verify all published files are licensed consistently and attribute GNU Lua
- [ ] Verify isolated `package-install-file` from the generated multi-file archive
- [ ] Publish a canonical repository and source URL, then submit MELPA recipe

MELPA's official instructions: https://github.com/melpa/melpa/blob/master/CONTRIBUTING.org
LSP integration guidance: https://emacs-lsp.github.io/lsp-mode/page/adding-new-language/

The user-reported Cycle 02 errors guide Cycle 03's new tests; passing static
checks alone is not sufficient to mark these release gates complete.

## Cycle 07 — Roblox API cache (optional)

`luau-roblox.el` is a distributed library and therefore included in
package-lint.  Its official API assets are downloaded only by the explicit
interactive command, into a user cache outside this package.  The standard
15-target `make check` matrix remains the single quality entry point.
The external live LSP connection and asset download are separate integration
checks which require the user's machine and network, respectively.

## Cycle 09: archive and isolated installation smoke

GNU Emacs documents multi-file package archives as `NAME-VERSION.tar` with
`NAME-pkg.el` inside a versioned root. `tools/build_release.py` constructs
that deterministic archive from the public source allowlist, then
`test/batch-package-install.el` installs it into a disposable `-Q` profile.
This is a new `test-install` gate under the canonical `make check` command.
The green Cycle 08 baseline is preserved as the most recent **native verified**
run until the Cycle 09 report is returned.

No official MELPA release can occur without the actual project repository
and a recipe built and tested using MELPA's own package-build machinery.
