.PHONY: help build test e2e e2e-ios e2e-android eval clean viewer sync-skills

# pipefail below needs bash; macOS /bin/sh is bash-in-posix-mode but
# being explicit costs nothing.
SHELL := /bin/bash

# Pipe a swift invocation through xcsift (condensed, agent-friendly
# TOON output) when it is installed; fall back to swift's own output
# otherwise, so contributors are never required to install it. $(2)
# passes extra xcsift flags (e.g. --coverage). Knobs:
#   SIM_USE_XCSIFT=0        force plain swift output even with xcsift
#   SIM_USE_RAW_LOG=<path>  also save the raw swift output to <path>
#                           before condensing (CI keeps it as a
#                           failure artifact). Expanded unquoted on
#                           purpose: empty means tee has no file
#                           operand and acts as a plain passthrough.
# pipefail keeps swift's exit code authoritative either way.
define run_swift
	if [ "$${SIM_USE_XCSIFT:-1}" != "0" ] && command -v xcsift >/dev/null 2>&1; then \
		set -o pipefail; $(1) 2>&1 | tee $${SIM_USE_RAW_LOG} | xcsift $(2) -w -f toon; \
	else \
		$(1); \
	fi
endef

help:
	@echo "Common sim-use commands"
	@echo "  make build   Build sim-use"
	@echo "  make viewer  Rebuild the Viewer SPA into Sources/SimUse/Resources/viewer/"
	@echo "  make test    Run unit tests (no simulator needed)"
	@echo "  make e2e     Run BOTH iOS + Android E2E suites in sequence (~15 min iOS alone)"
	@echo "  make e2e-ios      Run iOS E2E tests on a booted simulator (~15 min for a full green run)"
	@echo "  make e2e-android  Run Android E2E tests on a connected device/emulator"
	@echo "  make eval    Run agent evals (real \`claude -p\` cost; prompts first)"
	@echo "  make clean   Clean Swift build artifacts"

# The bundled skill lives in skills/sim-use (source of truth) and is
# synced into the gitignored SwiftPM resource path. Both build and
# test need it — SwiftPM refuses to build the SimUse target when the
# declared resource directory is missing.
sync-skills:
	@rsync -a --delete skills/sim-use/ Sources/SimUse/Resources/skills/sim-use/

build: sync-skills
	@./scripts/stage-fb-frameworks.sh
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
test: sync-skills
	@./scripts/stage-fb-frameworks.sh
	@$(call run_swift,swift test --enable-code-coverage,--coverage)

# Run both platforms in sequence (iOS then Android), continuing past a
# platform failure so you get the full picture, and failing if either did.
# Needs both a booted iOS simulator and a reachable Android device/emulator;
# for one platform only, use e2e-ios / e2e-android. A full green iOS pass
# alone is ~15 min, so budget ~20+ min for the combined run.
e2e:
	@fail=0; \
	echo "== iOS E2E =="; ./scripts/test-runner.sh || fail=1; \
	echo "== Android E2E =="; ./scripts/test-runner-android.sh || fail=1; \
	if [ $$fail -ne 0 ]; then echo "❌ e2e: one or more platforms failed"; exit 1; fi; \
	echo "✅ e2e: iOS + Android green"

# iOS simulator E2E: builds the CLI + Playground fixture, installs it on the
# booted simulator, and runs the iOS suites. A full green run is ~15 min
# (each HID-driven suite waits on real simulator gestures/animations).
e2e-ios:
	./scripts/test-runner.sh

# Android device E2E: builds the CLI + playground fixture, installs it on
# ANDROID_SERIAL (default emulator-5554), and runs the Android suites.
e2e-android:
	./scripts/test-runner-android.sh

# Agent evals: a headless `claude -p` drives the bundled skill against the
# Playground apps. Each case makes real API calls, so the wrapper checks the
# environment and prompts for confirmation before spending anything. Pass
# options through env vars, e.g. `make eval PLATFORM=ios TAGS=release`, or
# `make eval ARGS="-p android -- --cases oss-android-tap-three-times"`.
eval:
	@./scripts/eval.sh $(ARGS)

clean:
	swift package clean
