# Luau Mode — Monad-style source inventory, quality gates and reports.
# Every public target is wrapped by tools/make_ui.py; private recipes do work.
EMACS ?= emacs
EMACS_BATCH = $(EMACS) -Q --batch --eval '(setq load-prefer-newer t)' -L . -L test -L tests
PACKAGE_DIR ?= $(CURDIR)/.packages
PYTHON ?= python3
LUAU_MAKE ?= make
MAKE_UI = $(PYTHON) tools/make_ui.py
ELISP = $(shell find . -type f -name '*.el' ! -path './.git/*' ! -path './.packages/*' ! -path './test/*' ! -path './tests/*' ! -path './bench/*' ! -path './.build/*' | sort)
TASKS = dependencies test-install test test-core test-lsp test-font-lock test-interface test-tools test-static package-audit verify-delta compile compile-strict doctor checkdoc package-lint lint bootstrap clean clean-bytecode benchmark-font-lock benchmark-navigation
BENCHMARKS = benchmark-font-lock benchmark-navigation
DIAGNOSTICS = dependencies compile compile-strict test-install test test-core test-lsp test-font-lock test-interface doctor checkdoc package-lint test-tools test-static package-audit $(BENCHMARKS)
.DEFAULT_GOAL := check
.PHONY: all check quickcheck triage failures dashboard history trend status benchmark diagnostics diagnostics-bundle bundle help clean-reports $(TASKS) $(addprefix __raw-,$(TASKS))

$(TASKS):
	@$(MAKE_UI) run "$@" --make "$(LUAU_MAKE)"

all: check

check:
	@$(MAKE_UI) suite check $(DIAGNOSTICS) --make "$(LUAU_MAKE)"; status=$$?; \
	  $(MAKE_UI) bundle; bundled=$$?; \
	  if test $$bundled -ne 0; then exit $$bundled; fi; exit $$status

quickcheck:
	@$(MAKE_UI) suite quickcheck compile-strict test-core test-lsp doctor test-tools test-static --make "$(LUAU_MAKE)"

triage:
	@$(MAKE_UI) triage --make "$(LUAU_MAKE)"

failures dashboard history trend status bundle help:
	@$(MAKE_UI) "$@"

benchmark:
	@$(MAKE_UI) suite benchmark $(BENCHMARKS) --make "$(LUAU_MAKE)"

diagnostics:
	@$(MAKE_UI) suite diagnostics $(DIAGNOSTICS) --make "$(LUAU_MAKE)"

diagnostics-bundle: check

clean-reports:
	@rm -rf .build/reports

# Private targets: raw logs are owned by one instrumented public target.
__raw-test-install:
	@$(PYTHON) tools/build_release.py
	@LUAU_RELEASE_TAR="$$($(PYTHON) tools/build_release.py --print-path)" $(EMACS) -Q --batch -l test/batch-package-install.el

__raw-test:
	@EMACS='$(EMACS)' $(PYTHON) tools/ert_runner.py

__raw-test-core:
	@LUAU_TEST_SELECTOR='^luau-test-' EMACS='$(EMACS)' $(PYTHON) tools/ert_runner.py

__raw-test-font-lock:
	@LUAU_TEST_SELECTOR='^luau-font-test-' EMACS='$(EMACS)' $(PYTHON) tools/ert_runner.py

__raw-test-lsp:
	@LUAU_TEST_SELECTOR='^luau-lsp-test-' EMACS='$(EMACS)' $(PYTHON) tools/ert_runner.py

__raw-test-interface:
	@LUAU_TEST_SELECTOR='^luau-interface-test-' EMACS='$(EMACS)' $(PYTHON) tools/ert_runner.py

__raw-test-tools:
	@$(PYTHON) -m unittest discover -s tools -p 'test_*.py' -v

__raw-package-audit:
	@$(PYTHON) tools/package_audit.py

__raw-dependencies:
	@$(LUAU_MAKE) --no-print-directory __raw-bootstrap

__raw-test-static:
	@$(PYTHON) tests/static_check.py

__raw-verify-delta:
	@test -n "$(DELTA)" || (printf 'Specify DELTA=/path/to/cycle.tar.gz\n' >&2; exit 2)
	@$(PYTHON) tools/verify_delta.py "$(DELTA)" $(if $(BASELINE),--baseline "$(BASELINE)")

__raw-compile: __raw-clean-bytecode
	@$(EMACS_BATCH) -f batch-byte-compile $(ELISP)

__raw-compile-strict: __raw-clean-bytecode
	@$(EMACS_BATCH) --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile $(ELISP)

__raw-doctor:
	@$(EMACS_BATCH) --eval '(require (quote package))' \
	  --eval '(setq package-user-dir "$(PACKAGE_DIR)")' \
	  --eval '(package-initialize)' -l test/batch-doctor.el

__raw-checkdoc:
	@LUAU_DOCTOR_CHECKS=checkdoc $(EMACS_BATCH) -l test/batch-doctor.el

__raw-package-lint:
	@LUAU_DOCTOR_CHECKS=package-lint $(EMACS_BATCH) \
	  --eval '(require (quote package))' \
	  --eval '(setq package-user-dir "$(PACKAGE_DIR)")' \
	  --eval '(package-initialize)' -l test/batch-doctor.el

__raw-lint: __raw-doctor

__raw-bootstrap:
	@$(EMACS_BATCH) --eval '(require (quote package))' \
	  --eval '(setq package-user-dir "$(PACKAGE_DIR)")' \
	  --eval '(add-to-list (quote package-archives) (quote ("melpa" . "https://melpa.org/packages/")) t)' \
	  --eval '(package-initialize)' \
	  --eval '(unless (package-installed-p (quote package-lint)) (package-refresh-contents) (package-install (quote package-lint)))'

__raw-benchmark-font-lock:
	@$(EMACS_BATCH) -l bench/font-lock-perf.el

__raw-benchmark-navigation:
	@$(EMACS_BATCH) -l bench/navigation-perf.el

__raw-clean-bytecode:
	@find . -name '*.elc' ! -path './.packages/*' -delete

__raw-clean: __raw-clean-bytecode
	@rm -rf .packages
