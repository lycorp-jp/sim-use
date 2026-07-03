.PHONY: help build test e2e clean viewer

# pipefail below needs bash; macOS /bin/sh is bash-in-posix-mode but
# being explicit costs nothing.
SHELL := /bin/bash

# Pipe a swift invocation through xcsift (condensed, agent-friendly
# TOON output) when it is installed; fall back to swift's own output
# otherwise, so contributors are never required to install it. $(2)
# passes extra xcsift flags (e.g. --coverage). Set SIM_USE_XCSIFT=0
# to force plain output even with xcsift present (CI does this to tee
# the raw log before condensing). pipefail keeps swift's exit code
# authoritative either way.
define run_swift
	if [ "$${SIM_USE_XCSIFT:-1}" != "0" ] && command -v xcsift >/dev/null 2>&1; then \
		set -o pipefail; $(1) 2>&1 | xcsift $(2) -f toon; \
	else \
		$(1); \
	fi
endef

help:
	@echo "Common sim-use commands"
	@echo "  make build   Build sim-use"
	@echo "  make viewer  Rebuild the Viewer SPA into Sources/SimUse/Resources/viewer/"
	@echo "  make test    Run unit tests (no simulator needed)"
	@echo "  make e2e     Run end-to-end tests on a booted simulator"
	@echo "  make clean   Clean Swift build artifacts"

build:
	@rsync -a --delete skills/sim-use/ Sources/SimUse/Resources/skills/sim-use/
	@$(call run_swift,swift build)

# Refresh the Viewer SPA resource bundle. The output is committed so
# end users never need Node — only contributors editing Tools/Viewer
# need to re-run this and commit the diff. Release scripts should run
# this before `swift build` to ensure tarballs ship the latest SPA.
viewer:
	./scripts/build-viewer.sh

# Coverage is always collected so the command behaves identically
# with and without xcsift; the report only renders when xcsift is
# there to read it.
test:
	@$(call run_swift,swift test --enable-code-coverage,--coverage)

e2e:
	./scripts/test-runner.sh

clean:
	swift package clean
