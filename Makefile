# Makefile for a6s.el — A6s extension for Emacs

EMACS ?= emacs
CASK ?= cask
BATCH = $(EMACS) -Q --batch

PACKAGE_NAME = a6s
PACKAGE_VERSION = 1.0.0

ELISP_FILES = a6s.el a6s-api.el a6s-ui.el a6s-commands.el a6s-compat.el
TEST_FILES = test/a6s-api-test.el test/a6s-commands-test.el test/a6s-ui-test.el test/test-helper.el

.PHONY: all clean compile test lint package install coverage help

all: compile lint test

# Remove build artifacts
clean:
	rm -f *.elc test/*.elc coverage-final.json .cask-compile-log

# Byte compile with warnings treated as errors
compile:
	$(CASK) build
	$(CASK) exec $(BATCH) \
		--eval "(setq byte-compile-error-on-warn t)" \
		-L . -f batch-byte-compile $(ELISP_FILES)

# Run package-lint (on main file only, multi-file package convention) and checkdoc
lint:
	$(CASK) exec $(BATCH) -L . \
		--eval "(require 'package)" \
		--eval "(add-to-list 'package-archives '(\"melpa\" . \"https://melpa.org/packages/\") t)" \
		--eval "(package-initialize)" \
		--eval "(unless package-archive-contents (package-refresh-contents))" \
		--eval "(require 'package-lint)" \
		-f package-lint-batch-and-exit a6s.el
	$(CASK) exec $(BATCH) -L . \
		--eval "(setq checkdoc-arguments-in-order-flag nil)" \
		--eval "(checkdoc-file \"a6s.el\")" \
		--eval "(checkdoc-file \"a6s-api.el\")" \
		--eval "(checkdoc-file \"a6s-ui.el\")" \
		--eval "(checkdoc-file \"a6s-commands.el\")"

# Run ERT tests with undercover coverage
test:
	UNDERCOVER_CONFIG='("*.el" (:report-format :text) (:send-report nil))' \
	$(CASK) exec $(BATCH) -L . -L test \
		-l test/test-helper.el \
		-l test/a6s-api-test.el \
		-l test/a6s-commands-test.el \
		-l test/a6s-ui-test.el \
		-f ert-run-tests-batch-and-exit

# Coverage report (threshold enforced in test-helper.el)
coverage: test

help:
	@echo "Targets: all clean compile lint test coverage"
