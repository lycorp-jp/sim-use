---
name: release
description: Cut a sim-use release end-to-end. Use when the user runs `/release` or asks to "ship a release", "publish a version", "cut a release", or "release to homebrew". Drives scripts/local-release.sh; never reimplement its build/sign/tarball logic.
---

This skill ships a new version of sim-use. The human types `/release` and you handle everything: version, CHANGELOG, one confirmation, then drive every command through to the homebrew-tap commit.

Run from the sim-use repo root (`git rev-parse --show-toplevel`).

The build/sign/tarball/formula logic lives in `scripts/local-release.sh`. Do not duplicate it. Your job is orchestration: state checks, version arithmetic, CHANGELOG rendering, user confirmation, git/tap operations, error recovery.

## Step 1: Pre-flight

Run these checks. Abort with a clear error if any fails.

1. Current branch is `main`.
2. Working tree is clean (`git status --porcelain` returns nothing).
3. Local main is in sync with origin (`git fetch origin main` then compare HEADs). If local is ahead, ask to push first; if behind, abort.
4. `gh auth status` succeeds (github.com).
5. `build_products/Frameworks/` exists. If missing, run `scripts/build.sh dev` to build them.
6. The homebrew-tap clone exists at `../lycorp-jp-homebrew-tap`. If missing:
   ```bash
   git clone git@github.com:lycorp-jp/homebrew-tap.git ../lycorp-jp-homebrew-tap
   ```
   If it exists, verify it's clean and pull latest.
7. Android bridge toolchain: `scripts/build-bridge.sh --check` succeeds.
8. Signing + notarization readiness:
   ```bash
   security find-identity -v -p codesigning | grep -F "NAVER Japan K.K. (GFPYJQXRSN)"
   xcrun notarytool history --keychain-profile sim-use-notary >/dev/null 2>&1
   ```
   If either fails, surface the gap at Step 3 — don't silently switch to ad-hoc.

## Step 2: Determine version and draft CHANGELOG

1. Find latest tag: `git tag --list 'v*' --sort=-v:refname | head -1`.
2. Read commits since last tag: `git log <last-tag>..HEAD --pretty=format:'%h %s'`.
3. Auto-bump based on conventional commits:
   - `feat!:` / `BREAKING CHANGE` → major
   - `feat:` → minor
   - Only `fix:` / `chore:` / `docs:` → patch
4. Draft CHANGELOG entry from commits. Group by: `### Added` / `### Changed` / `### Fixed` / `### Removed`. Omit pure refactor/chore/test commits. Match existing CHANGELOG style.
5. **Backlink every entry to its pull request(s) and thank external contributors.** This is part of how the project builds its contributor community — never skip it.
   - Append the PR reference(s) at the end of each entry: ` (#NN)`. When the work arrived through an original PR plus an internal hardening/follow-up PR, reference both: ` (#NN, #MM)`.
   - When any referenced PR was authored by an external contributor (not the maintainer), turn the reference into thanks: ` (#NN — thanks @user!)`. Entries whose PRs involve only the maintainer keep the bare number.
   - Mapping technique: `git blame` the `[Unreleased]` lines, then `git log --merges --ancestry-path <sha>..main` — the earliest merge is the introducing PR. Watch for externally-authored PRs that GitHub marked merged because their commits landed via an internal branch (no own merge commit); credit the original PR alongside the one that carried it.
   - Cross-check the reverse direction: every merged PR with user-facing impact should have an entry. A contributor's fix missing from the CHANGELOG means missing credit — add the entry.
6. Also prepare the `bridge/app/build.gradle.kts` version bump: `versionName` → new version, `versionCode` += 1.

If the user specified a version (e.g. `/release 0.10.0`), use that verbatim.

## Step 3: Confirm with the user (single gate)

Show:
- Previous tag → next version
- Commit list (one line each)
- Proposed CHANGELOG diff (entries must carry their PR backlinks and contributor thanks from Step 2.5)
- Release shape: notarized (default) or ad-hoc fallback (if Step 1.8 failed)

Ask: **"Ship vX.Y.Z with this CHANGELOG?"**

Accept: yes / no / version override / CHANGELOG edit / "use ad-hoc fallback".

## Step 4: Apply changes and commit

1. Edit `CHANGELOG.md`: leave `## [Unreleased]` empty, insert `## [X.Y.Z] - YYYY-MM-DD` below it.
2. Edit `bridge/app/build.gradle.kts`: bump `versionName` and `versionCode`.
3. Commit:
   ```bash
   git add CHANGELOG.md bridge/app/build.gradle.kts
   git commit -m "chore(release): vX.Y.Z"
   git push origin main
   ```

## Step 5: Tag

```bash
git tag vX.Y.Z
git push origin vX.Y.Z
```

## Step 6: Run the release pipeline

**Notarized (default):**
```bash
scripts/local-release.sh \
  --version X.Y.Z \
  --codesign-identity "Developer ID Application: NAVER Japan K.K. (GFPYJQXRSN)" \
  --notarize \
  --notary-profile sim-use-notary \
  --gh-release \
  --tap-dir ../lycorp-jp-homebrew-tap
```

**Ad-hoc fallback** (only if user explicitly opted in):
```bash
scripts/local-release.sh \
  --version X.Y.Z \
  --gh-release \
  --tap-dir ../lycorp-jp-homebrew-tap
```

If the script fails midway:
- Bridge build failed → `scripts/build-bridge.sh --check`, see AGENTS.md Android pitfalls
- Notarization rejected → check `dist/notary-vX.Y.Z.log`
- GHE release create failed → re-run (script falls back to `gh release upload --clobber`)
- Smoke test failed → surface exact error, don't paper over

## Step 7: Commit and push the tap

```bash
cd ../lycorp-jp-homebrew-tap
git add Formula/sim-use.rb
git commit -m "sim-use vX.Y.Z"
git push origin main
cd -
```

## Step 8: Report

Show:
- Version released
- GitHub release URL: `https://github.com/lycorp-jp/sim-use/releases/tag/vX.Y.Z`
- Tap commit
- Install command:
  ```
  brew tap lycorp-jp/tap
  brew install sim-use
  ```

## Dry-run mode

If the user passes `dry-run` or "preview", run Steps 1-3 only. Show what would happen, then stop.

## Things to NOT do

- Don't modify build scripts as part of a release run — build behavior changes go through their own commit.
- Don't auto-resolve git conflicts on CHANGELOG.md.
- Don't force-push tags.
- Don't `brew install` the fresh formula on the developer machine.
