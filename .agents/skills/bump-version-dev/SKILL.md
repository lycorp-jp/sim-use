---
name: bump-version-dev
description: Build a release-shaped sim-use binary and install it locally for testing. Use when the user runs `/bump-version-dev` or asks to "build a dev release", "test the release build locally", "install a release build for testing", or "prepare a release candidate without publishing". Builds APK + CLI, stages, ad-hoc signs, and repoints the PATH binary. Does NOT commit, tag, push, create releases, or update homebrew. After local validation, run `/release` to ship for real.
---

This skill builds and locally installs a release-shaped sim-use binary so the user can validate it before publishing. It delegates the heavy lifting to `scripts/dev-install.sh` and handles version determination + user confirmation.

Run from the sim-use repo root (`git rev-parse --show-toplevel`).

## Restore flow

If the user passes `restore` as an argument (e.g. `/bump-version-dev restore`), skip everything and run:

```bash
scripts/dev-install.sh --restore
```

Report success or failure and stop.

## Step 1: Pre-flight

Run these checks. Abort with a clear error if any fails.

1. Current directory is the sim-use repo root.
2. `build_products/Frameworks/` exists. If missing, tell the user to run `scripts/build.sh dev` (~30 min). Do NOT run it automatically.
3. Android bridge toolchain: `scripts/build-bridge.sh --check` succeeds. If not, surface the missing tool.

Unlike `/release`, this skill does NOT require:
- Clean working tree (local modifications are fine — this is a dev build)
- GitHub auth
- Homebrew tap clone
- Codesign identity or notary profile

## Step 2: Determine the next version

1. Find the latest sim-use tag: `git tag --list 'v*' --sort=-v:refname | head -1`.
2. If a prior tag exists, read commits since it: `git log <last-tag>..HEAD --pretty=format:'%h %s'`.
3. Pick bump type from conventional commit prefixes:
   - `feat!:` / `BREAKING CHANGE` → **major**
   - `feat:` → **minor**
   - Only `fix:` / `chore:` / `docs:` / `refactor:` / `test:` → **patch**
4. Compute the next version.

If the user specified a version (e.g. `/bump-version-dev 0.9.1`), use that verbatim instead of auto-bumping.

## Step 3: Confirm with the user

Show:
- The current tag and the target version.
- The commit list since the last tag (one line each).
- What will happen: "Build APK + CLI as vX.Y.Z, stage, ad-hoc sign, and replace the PATH binary."

Ask: **"Build and install vX.Y.Z locally?"** Wait for explicit yes/no/version override.

## Step 4: Run the dev-install script

```bash
scripts/dev-install.sh --version X.Y.Z
```

This script handles:
1. Rebuilding the Android bridge APK (`scripts/build-bridge.sh`)
2. Building the universal CLI with `SIM_USE_VERSION=X.Y.Z` (`scripts/build.sh executable`)
3. Staging the payload (`scripts/release-artifacts.sh stage-build-output` + `verify-stage`)
4. Ad-hoc codesigning the staged payload
5. Backing up the current PATH binary target
6. Symlinking the PATH binary to the staged build
7. Verifying `sim-use --version`

The script typically takes 2-5 minutes. Stream the output so the user sees progress. If the script fails, diagnose:

- Bridge build failed → JDK/SDK issue, see CLAUDE.md Android pitfalls
- `verify-stage` failed → missing resource bundle, re-check build output
- Codesign failed → unlikely for ad-hoc; check macOS version
- Symlink failed → permission issue on the install path

## Step 5: Report

After the script succeeds, report:
- The installed version (`sim-use --version`)
- The symlink target
- Reminder: test the build, then run `/release` to ship for real
- Reminder: run `scripts/dev-install.sh --restore` (or `/bump-version-dev restore`) to go back

## Things to NOT do

- Don't modify `CHANGELOG.md`, `bridge/app/build.gradle.kts`, or any tracked file.
- Don't commit, tag, or push anything.
- Don't run `--build-frameworks` — that's a slow path requiring explicit user opt-in.
- Don't codesign with Developer ID — ad-hoc is sufficient for local testing.
- Don't create tarballs, formulas, or releases.
- Don't attempt notarization.
