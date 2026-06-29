#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
sim-use preflight check.

Verifies that sim-use is installed, the target device is reachable,
and the daemon is healthy. Run before first interaction with a device.

Usage:
    python3 preflight.py --device <UDID>
    python3 preflight.py                    # auto-resolve single device
"""

import argparse
import json
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from typing import Callable, Optional


# ---------------------------------------------------------------------------
# Check framework
# ---------------------------------------------------------------------------

@dataclass
class Check:
    id: str
    description: str
    run: Callable[["Ctx"], bool]
    on_fail: str = "abort"  # abort | auto | prompt
    autofix: Optional[Callable[["Ctx"], bool]] = None
    fix_hint: str = ""


@dataclass
class Ctx:
    device: Optional[str] = None
    sim_use_bin: str = "sim-use"
    platform: Optional[str] = None  # "ios" or "android", detected
    errors: list = field(default_factory=list)

    def run_sim_use(self, *args: str, check: bool = False) -> subprocess.CompletedProcess:
        cmd = [self.sim_use_bin] + list(args)
        if self.device:
            cmd.extend(["--device", self.device])
        return subprocess.run(cmd, capture_output=True, text=True, check=check)

    def run_sim_use_json(self, *args: str) -> Optional[dict]:
        result = self.run_sim_use(*args, "--json")
        if result.returncode != 0:
            return None
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError:
            return None


def run_checks(checks: list[Check], ctx: Ctx) -> bool:
    all_passed = True
    for c in checks:
        passed = c.run(ctx)
        if passed:
            print(f"  PASS  {c.description}")
            continue

        if c.on_fail == "auto" and c.autofix:
            print(f"  FIX   {c.description} -- attempting autofix...")
            if c.autofix(ctx) and c.run(ctx):
                print(f"  PASS  {c.description} (after autofix)")
                continue

        print(f"  FAIL  {c.description}")
        if c.fix_hint:
            print(f"        hint: {c.fix_hint}")
        ctx.errors.append(c.id)
        all_passed = False

        if c.on_fail == "abort":
            print("\n  Aborting -- later checks depend on this one.")
            break

    return all_passed


# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

def check_sim_use_installed(ctx: Ctx) -> bool:
    return shutil.which(ctx.sim_use_bin) is not None


def check_device_listed(ctx: Ctx) -> bool:
    result = subprocess.run(
        [ctx.sim_use_bin, "devices", "--json"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        return False
    try:
        data = json.loads(result.stdout)
        devices = data.get("data", {}).get("devices", [])
    except (json.JSONDecodeError, AttributeError):
        return False

    if not ctx.device:
        booted = [d for d in devices if d.get("state", "").lower() in ("booted", "device")]
        if len(booted) == 1:
            ctx.device = booted[0].get("udid") or booted[0].get("deviceId")
            ctx.platform = booted[0].get("platform")
            return True
        if len(booted) > 1:
            names = [f"{d.get('name')} ({d.get('udid') or d.get('deviceId')})" for d in booted]
            print(f"        Multiple devices found: {', '.join(names)}")
            print("        Re-run with --device <UDID> to pick one.")
        return False

    for d in devices:
        did = d.get("udid") or d.get("deviceId", "")
        if did == ctx.device:
            ctx.platform = d.get("platform")
            return True
    return False


def autofix_boot_simulator(ctx: Ctx) -> bool:
    if not ctx.device:
        return False
    result = subprocess.run(
        ["xcrun", "simctl", "boot", ctx.device],
        capture_output=True, text=True,
    )
    if result.returncode == 0:
        import time
        time.sleep(2)
    return result.returncode == 0


def check_ui_responds(ctx: Ctx) -> bool:
    envelope = ctx.run_sim_use_json("ui")
    return envelope is not None and envelope.get("ok") is True


def autofix_daemon_restart(ctx: Ctx) -> bool:
    ctx.run_sim_use("daemon", "stop", "--all")
    return True


def shared_checks() -> list[Check]:
    return [
        Check(
            id="sim_use_installed",
            description="sim-use is on PATH",
            run=check_sim_use_installed,
            on_fail="abort",
            fix_hint="Install sim-use: see README.md",
        ),
        Check(
            id="device_listed",
            description="target device is listed and reachable",
            run=check_device_listed,
            on_fail="abort",
            fix_hint="Boot a simulator or connect an Android device, then retry.",
        ),
        Check(
            id="ui_responds",
            description="sim-use ui returns a valid response",
            run=check_ui_responds,
            on_fail="auto",
            autofix=autofix_daemon_restart,
            fix_hint="Try: sim-use daemon stop --all, then retry.",
        ),
    ]


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="sim-use preflight check")
    parser.add_argument("--device", help="Device UDID or serial (auto-detected if omitted)")
    parser.add_argument("--sim-use-bin", default="sim-use", help="Path to sim-use binary")
    args = parser.parse_args()

    ctx = Ctx(device=args.device, sim_use_bin=args.sim_use_bin)

    print("sim-use preflight\n")
    passed = run_checks(shared_checks(), ctx)
    print()

    if passed:
        device_label = ctx.device or "(auto-resolved)"
        platform_label = ctx.platform or "unknown"
        print(f"All checks passed. Device: {device_label} ({platform_label})")
        sys.exit(0)
    else:
        print(f"Preflight failed: {', '.join(ctx.errors)}")
        sys.exit(1)


if __name__ == "__main__":
    main()
