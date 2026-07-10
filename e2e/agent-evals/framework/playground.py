# SPDX-License-Identifier: Apache-2.0
"""Playground fixture reset for agent evals.

Relaunches the Playground app fresh before a case, optionally deep-linked to a
screen (`precondition.screen`). Screen presets keep cases cheap and focused on
the verb under evaluation; navigation-capability cases omit the screen and let
the agent find its way from the main menu.
"""

from __future__ import annotations

import os
import subprocess
import time

IOS_BUNDLE_ID = "com.cameroncooke.SimUsePlayground"
ANDROID_APP_ID = "com.linecorp.simuse.playground"
ANDROID_ACTIVITY = f"{ANDROID_APP_ID}/.MainActivity"


class ResetError(RuntimeError):
    pass


def _discover_adb() -> str:
    for candidate in (
        os.environ.get("ADB", ""),
        "adb",
        os.path.expanduser("~/Library/Android/sdk/platform-tools/adb"),
    ):
        if not candidate:
            continue
        try:
            subprocess.run([candidate, "version"], capture_output=True, timeout=10)
            return candidate
        except (FileNotFoundError, subprocess.TimeoutExpired):
            continue
    raise ResetError("adb not found; set $ADB")


def reset(platform: str, udid: str, screen: str | None, log=print) -> None:
    if platform == "ios":
        _reset_ios(udid, screen, log)
    elif platform == "android":
        _reset_android(udid, screen, log)
    else:
        raise ResetError(f"unknown platform {platform!r}")


def _reset_ios(udid: str, screen: str | None, log) -> None:
    subprocess.run(
        ["xcrun", "simctl", "terminate", udid, IOS_BUNDLE_ID],
        capture_output=True,
        timeout=30,
    )
    cmd = ["xcrun", "simctl", "launch", udid, IOS_BUNDLE_ID]
    if screen:
        cmd += ["--launch-arg", f"screen={screen}"]
    log(f"[reset] launching playground{f' at {screen}' if screen else ''}")
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    if proc.returncode != 0:
        raise ResetError(
            f"simctl launch failed (is the playground installed? "
            f"run scripts/test-runner.sh -b): {proc.stderr.strip()}"
        )
    time.sleep(2)


def _reset_android(udid: str, screen: str | None, log) -> None:
    adb = [_discover_adb(), "-s", udid]
    subprocess.run(adb + ["shell", "am", "force-stop", ANDROID_APP_ID], timeout=30)
    cmd = adb + ["shell", "am", "start", "-n", ANDROID_ACTIVITY]
    if screen:
        cmd += ["-e", "screen", screen]
    log(f"[reset] launching playground{f' at {screen}' if screen else ''}")
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    if proc.returncode != 0 or "Error" in proc.stdout:
        raise ResetError(
            f"am start failed (is the playground installed? run "
            f"scripts/build-playground-android.sh + adb install): "
            f"{(proc.stdout + proc.stderr).strip()[:300]}"
        )
    time.sleep(2)
