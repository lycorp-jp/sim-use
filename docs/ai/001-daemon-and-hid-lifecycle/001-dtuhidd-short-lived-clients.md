# 001.001 — HID from short-lived processes is lost on the dtuhidd transport

> Updated 2026-11-20. Explicit no-daemon input now fails before a DTUHID send. See [002](002-no-daemon-dtuhid-refusal.md).

| | |
| --- | --- |
| **Date** | 2026-10-14 |
| **Refs** | #154 (fix), #152 (found during the same release gate), issue #153 (related, open) |
| **Shipped in** | 0.15.0 |

> **2026-10-20 follow-up:** [011 Device Hub paste](../011-device-hub-paste/000-investigation.md)
> isolates the clipboard failure mentioned below. CoreSimulatorBridge rejects
> legacy snapshots while the CoreDevice pasteboard stack is active; the earlier
> description of host text overwriting the write describes the observed result,
> not the full mechanism. CoreDevice copy/readback plus targeted menu Paste was
> verified. That clipboard issue is separate from this shipped HID-lifetime fix.

## Context

The 0.15.0 release gate ran `make e2e-matrix`. On the x27-hub leg (Xcode 27.1
RC, Device Hub open at boot, iOS 27.0 simulator, `dtuhidd` attached), the
`BatchTests` case "Batch reads steps from stdin" failed on every run in the
suite: `ios batch --stdin` exited 0 and the Playground tap count stayed at 0.
The same case passed alone, passed on the Hub-closed legs, and failed the same
way with the 0.14.0 binary. The fault is present since the DTUHID transport
came in with the idb migration (0.12.0, see
[006-xcode27-support](../006-xcode27-support/000-investigation.md)).

`batch --stdin`, `batch --file`, `type --stdin` and `paste --stdin` set
`daemonBypass`, because the daemon runs with stdin on `/dev/null` and in its
own working directory. These commands therefore opened their own HID
connection in the CLI process.

## Evidence

All on the x27-hub setup, Playground `tap-test` screen.

| Probe | Result |
| --- | --- |
| In-process taps (`SIM_USE_NO_DAEMON=1 sim-use tap …`), no daemon running, 3 separate processes | 0 of 3 counted |
| Daemon tap, then 2 in-process taps, then a daemon tap | daemon taps counted, in-process taps not |
| `ios batch --file` with `tap,tap` / `sleep 1,tap,tap` / `tap,tap,sleep 1` / `tap,sleep 1,tap,sleep 1`, 4 runs each, in-process | 0 of 2 counted in all 16 runs |
| In-process taps with `--post-delay` 0 / 0.1 / 0.3 / 1 s | 0/3, 0/3, 3/3, 1/3 |
| Daemon and in-process SimulatorKit load path | identical (both from the xcode-select Xcode), so not the cause |

The `dtuhidd` log inside the simulator
(`xcrun simctl spawn <udid> log show --predicate 'process == "dtuhidd"'`) for
one in-process tap:

| Time | `dtuhidd` |
| --- | --- |
| 25.892 | receives the new peer connection |
| 25.892–26.289 | no activity |
| 26.289–26.299 | creates and activates 6 virtual HID services for this peer (`mainScreenButtons`, `avpCustom`, `mainKeyboard`, `mainTouchscreen`, `touchscreen`, `touchscreenGesture`) |
| 26.299 | `activating connection` — the first point at which it reads the peer's messages |
| 26.300 | `invalidated because the client process … either cancelled the connection or exited`; `Cancelled all 6 services` |

## Root cause

`dtuhidd` builds a set of virtual HID services for each new host peer, and it
reads the peer's messages only after that setup. The setup took about 0.4 s
here. The client sent its events, waited for upstream's 80 ms drain
(`FBSimulatorDTUHIDTransport.flush()`, comment: "dtuhidd resets its virtual
services … the instant the host peer disconnects") plus the 25 ms
stabilization delay, and exited. When `dtuhidd` activated the connection, the
peer was gone, and it dropped the queued events. The command still reported
success, because the XPC send barrier only confirms that the bytes reached
the connection.

The daemon keeps its connection open, so its queued events are read once the
services exist.

## Decision

**Every command that sends HID goes through the per-device daemon.** A short-lived
process must not open its own HID connection on the DTUHID transport.

| Decision | Options considered | Chosen because |
| --- | --- | --- |
| Inline caller-side input into the forwarded argv | (a) longer drain in short-lived processes; (b) wait for an acknowledgement from `dtuhidd`; (c) send stdin or file contents to the daemon over a new wire field; (d) read the input in the client and rewrite argv | (a) is a timing guess and the measurements do not support it (`--post-delay 1` still lost 2 of 3). (b) is not possible: `dtuhidd` does not reply to events or barriers. (c) changes the daemon wire. (d) needs no wire change and reuses the existing `--step` and positional parse paths |
| `batch` steps become `--step=<line>` | `--step <line>` | The `=` form keeps a step from being parsed as an option |
| `type` / `paste` text becomes the positional after `--` | positional without a terminator | Text that starts with `-` stays text |
| `injectingDeviceIfNeeded` inserts `--device` before `--` and ignores tokens after it | append at the end | An appended `--device` after `--` would be a positional, and inlined text that reads `--device` would suppress the injection |
| `SIM_USE_NO_DAEMON=1` stays in-process | route it through the daemon too | It exists to run without a daemon; its limitation is documented in `CHANGELOG.md` |

## Change

- `SimUseExecutableCommand.daemonArguments(from:)`
  (`Sources/SimUseCore/Types/SimUseExecutableCommand.swift`): a hook that
  returns the argv tail the daemon parses. The default returns it unchanged.
  It runs only on the daemon path.
- `DaemonInlineInput` (`Sources/SimUseCore/Daemon/DaemonInlineInput.swift`):
  pure argv rewriting that stops at a `--` terminator.
- `IOSSimBatchCommand`, `IOSSimTypeCommand`, `IOSSimPasteCommand` and the
  top-level `Type` / `Paste` forwarders implement the hook and no longer set
  `daemonBypass`.
- Side effect: a relative `type --file` / `paste --file` path now resolves
  against the caller's directory. Before, the daemon resolved it against its
  own directory.

## Verification (2026-10-14)

- `make test`: 1552 passed.
- x27-hub, live: a daemon tap and then `ios batch --stdin` → 3 of 3 counted;
  `ios batch --file rel.steps` from another directory → 2 of 2; empty stdin →
  `Error: No executable steps found.` (exit 1).
- x27-hub suites: `BatchTests` 14/14 (was 13/14), `TypeTests` 15/15. Hub
  closed: `BatchTests`, `TypeTests`, `PasteTests`, `KeyboardStateTests` pass.
- Full `make e2e-matrix` and `make e2e` on the merged code: green, except the
  hub-leg cases broken by issue #153.

## Open questions

- Why `--post-delay 1` registered only 1 of 3 taps. A drain-time explanation
  alone predicts 3 of 3. The daemon route makes the question moot for the
  shipped verbs, but it matters if a short-lived HID client is ever needed.
- Issue #153: with Device Hub open, the host pasteboard overwrites what
  `simctl pbcopy` writes, so `paste` delivers the wrong text. It is a different
  Device Hub fault and is not fixed by this change.
