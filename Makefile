.PHONY: help build test e2e clean viewer

help:
	@echo "Common sim-use commands"
	@echo "  make build   Build sim-use"
	@echo "  make viewer  Rebuild the Viewer SPA into Sources/SimUse/Resources/viewer/"
	@echo "  make test    Run default tests"
	@echo "  make e2e     Run simulator end-to-end tests"
	@echo "  make clean   Clean Swift build artifacts"

build:
	@rsync -a --delete skills/sim-use/ Sources/SimUse/Resources/skills/sim-use/
	swift build

# Refresh the Viewer SPA resource bundle. The output is committed so
# end users never need Node — only contributors editing Tools/Viewer
# need to re-run this and commit the diff. Release scripts should run
# this before `swift build` to ensure tarballs ship the latest SPA.
viewer:
	./scripts/build-viewer.sh

test:
	swift test

e2e:
	./scripts/test-runner.sh

clean:
	swift package clean
