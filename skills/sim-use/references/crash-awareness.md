# Crash Awareness Protocol

sim-use automatically tracks the target app's process liveness while the daemon is running. When the tracked process disappears between commands, sim-use surfaces a banner on the next `ui` call.

## Signals

### Process liveness (iOS + Android)

```
================ PROCESS DISAPPEARED ================
com.example.app (pid 12345) was alive at the previous command and is GONE now.
Likely crash or termination, not a backgrounding. Verify before trusting subsequent actions.
=====================================================
App: SpringBoard  402x874
```

The signal is process liveness — a PID that was alive and is now gone. Backgrounding (permission dialogs, share sheets, app switcher) does **not** trip it.

### Crash dialog (Android only)

```
=============== CRASH DIALOG DETECTED ===============
An Android system app-crash dialog is on screen ("MyApp keeps stopping").
=====================================================
```

Detected directly from the accessibility tree via the AOSP framework resource IDs (`android:id/aerr_close` / `aerr_app_info`). Works without the daemon, locale-independent, and fires while the dialog is visible — even before the process fully exits.

Either signal alone is a sufficient crash hint.

## Mandatory response

1. **STOP** all automation. Do not silently relaunch or continue tapping.
2. **Report** the crash to the user, including the banner text and context (what action preceded the crash).
3. **Wait** for user instructions before proceeding.

Never assume you can recover from a crash by relaunching the app — the user may need to inspect crash logs, capture state, or change strategy.

## Confidence and idle gaps

Deaths observed after a long idle gap (default 120s, tunable with `SIM_USE_CRASH_WINDOW`) are downgraded to a quiet `[i]` line and the baseline is reset. This prevents false alarms from out-of-band kills while the agent was idle.

## Resetting the baseline

After intentionally relaunching the app or accepting a known crash:

```bash
sim-use app-state --reset --device <UDID>
```

This clears pending signals so subsequent commands don't re-surface a stale death.

## Disabling detection

```bash
SIM_USE_NO_CRASH_DETECT=1 sim-use ui --device <UDID>
```

Detection is on by default in daemon mode.
