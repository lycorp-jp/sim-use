# Contributing to sim-use

Thanks for your interest in improving sim-use! This guide explains how to set
up a development environment, the conventions we follow, and the legal sign-off
every contribution needs.

By participating in this project you agree to abide by our
[Code of Conduct](CODE_OF_CONDUCT.md).

## Developer Certificate of Origin (DCO)

This project requires a [Developer Certificate of Origin](https://developercertificate.org/)
sign-off on every commit. The DCO is a lightweight way for contributors to
certify that they wrote, or otherwise have the right to submit, the code they
are contributing under the project's license (Apache License 2.0).

To sign off, add a `Signed-off-by` line to each commit message with your real
name and email address:

```
Signed-off-by: Jane Doe <jane.doe@example.com>
```

Git can add this automatically with the `-s` flag:

```bash
git commit -s -m "Fix tap selector disambiguation"
```

Pull requests are checked by a DCO bot; commits missing a valid sign-off will
be flagged and must be amended (`git commit --amend -s`, or `git rebase
--signoff` for a series) before they can be merged.

All contributions are accepted under the terms of the [Apache License,
Version 2.0](LICENSE). You retain the copyright to your contribution; the
sign-off only certifies your right to submit it.

## Development environment

sim-use is a Swift package (`swift-tools-version:5.10`) targeting **macOS 14+**
and built with the **latest Xcode** toolchain. It drives the iOS Simulator
through XCFrameworks built from [Meta's idb](https://github.com/facebook/idb),
and includes an optional Android backend whose device bridge is a separate
Gradle project under `bridge/`.

```bash
# Clone, then build the required idb XCFrameworks (~1 GB under build_products/,
# not checked in; first build takes roughly 30 minutes).
./scripts/build.sh dev

# Or use the Makefile shortcuts:
make build      # build the sim-use executable
make viewer     # build the bundled Viewer SPA (Tools/Viewer)
```

The Android bridge APK and the Viewer SPA are build outputs, not source
artifacts — regenerate them locally with `scripts/build-bridge.sh` and
`scripts/build-viewer.sh` (or `make viewer`) when working on those surfaces.
`swift build` succeeds without them; the relevant commands print an actionable
"build it first" error if the artifact is missing.

See [`AGENTS.md`](AGENTS.md) for an architecture map and module-by-module
orientation.

## Testing

```bash
make test       # unit tests via swift test
make e2e        # end-to-end tests against a booted simulator
```

For the full build-and-test harness (simulator setup, the SimUsePlayground app,
test-plan execution), use `./test-runner.sh` (run with `--help` for options
such as build-only / test-only modes and verbose output).

Please add or update tests for any behavior change, and make sure the suite
passes locally before opening a pull request.

## Coding conventions

- Match the style of the surrounding code; keep changes minimal and focused.
- Every new source file must carry an SPDX license header at the very top:
  ```swift
  // SPDX-License-Identifier: Apache-2.0
  ```
  (`#` comment form for shell/Gradle files, `//` for Swift/Kotlin/TypeScript.)
- Write clear commit messages. Use [Conventional Commits](https://www.conventionalcommits.org/)
  prefixes (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`) where they fit.
- Keep cross-platform parity in mind: iOS and Android verbs aim to be
  behaviorally symmetric and share the same `--json` envelope shape.

## Submitting a pull request

1. Fork the repository and create a topic branch.
2. Make your change with tests, signed off per the DCO section above.
3. Run `make test` (and `make e2e` if your change touches device behavior).
4. Open a pull request describing the motivation and the change. Link any
   related issue.

A maintainer will review your PR. Thanks for contributing!
