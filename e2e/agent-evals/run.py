#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""sim-use agent-eval runner.

Runs natural-language eval cases through a headless agent (`claude -p`) using
this repo's bundled skill (skills/sim-use/) against the Playground fixture app
on a live device. Deterministic post-condition checks decide PASS/FAIL; the
agent's own success claims are recorded but never trusted.

Usage:
    python3 e2e/agent-evals/run.py --platform ios --tags quick
    python3 e2e/agent-evals/run.py --platform android --device emulator-5554
    python3 e2e/agent-evals/run.py --list

Prereqs: the Playground app must be installed (`scripts/test-runner.sh -b` for
iOS; `scripts/build-playground-android.sh` + adb install for Android) and the
`claude` CLI available.

Exit codes: 0 all PASS · 1 any FAIL/ERROR · 2 usage/environment error.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime
from pathlib import Path

EVALS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(EVALS_DIR))

from framework import agent as agent_mod
from framework import playground as playground_mod
from framework import verify as verify_mod
from framework.device import Sim
from framework.report import RunReport


def load_cases(platform: str, ids: list[str] | None, tags: list[str] | None) -> list[dict]:
    cases = []
    for path in sorted((EVALS_DIR / "cases" / platform).glob("*.json")):
        with open(path, encoding="utf-8") as fh:
            case = json.load(fh)
        case["_path"] = str(path)
        cases.append(case)
    if ids:
        wanted = set(ids)
        cases = [c for c in cases if c["id"] in wanted]
        missing = wanted - {c["id"] for c in cases}
        if missing:
            sys.exit(f"unknown case id(s): {', '.join(sorted(missing))}")
    if tags:
        cases = [c for c in cases if set(tags) & set(c.get("tags", []))]
    if not ids and "fragile" not in (tags or []):
        # fragile-tagged cases document known environment couplings; they
        # never gate a run unless asked for by id or by tag.
        cases = [c for c in cases if "fragile" not in c.get("tags", [])]
    return cases


def install_sim_use_override(binary: str) -> str:
    """Make `binary` the sim-use every layer of this run resolves.

    The runner's device detection, the deterministic verification layer
    (framework/device.py), and the eval agent's subprocesses all invoke
    bare `sim-use` and inherit this process's environment — so one PATH
    prepend pins the binary under test for the whole run. A shim
    directory (with a `sim-use` symlink) keeps resolution working
    whatever the target file is called. Returns the resolved path.
    """
    path = Path(binary).expanduser().resolve()
    if not (path.is_file() and os.access(path, os.X_OK)):
        sys.exit(f"--sim-use: not an executable file: {path}")
    shim = Path(tempfile.mkdtemp(prefix="sim-use-eval-bin-"))
    (shim / "sim-use").symlink_to(path)
    os.environ["PATH"] = f"{shim}{os.pathsep}{os.environ.get('PATH', '')}"
    return str(path)


def sim_use_under_test() -> tuple[str, str]:
    """Resolved path + version of the sim-use this run will exercise.
    Symlinks (the override shim, brew's bin link) are followed so the
    banner names the real binary."""
    which = shutil.which("sim-use")
    resolved = str(Path(which).resolve()) if which else "(not found on PATH)"
    try:
        out = subprocess.run(
            ["sim-use", "--version"], capture_output=True, text=True, timeout=10
        )
        version = out.stdout.strip() or "unknown"
    except FileNotFoundError:
        version = "unknown"
    return resolved, version


def resolve_device(platform: str, cli_device: str) -> str:
    if cli_device:
        return cli_device
    out = subprocess.run(
        ["sim-use", "devices", "--json"], capture_output=True, text=True, timeout=30
    )
    try:
        devices = json.loads(out.stdout).get("data", {}).get("devices", [])
    except json.JSONDecodeError:
        devices = []
    candidates = [
        d for d in devices
        if d.get("platform") == platform
        and d.get("state", "").lower() in ("booted", "device")
    ]
    # `deviceId` is the canonical key in `devices --json` (the legacy `udid`
    # key was dropped in 0.10.0).
    ids = [d.get("deviceId") for d in candidates if d.get("deviceId")]
    if len(ids) == 1:
        return ids[0]
    if not ids:
        sys.exit(f"no reachable {platform} device found; boot one or pass --device")
    sys.exit(
        f"cannot auto-resolve a single {platform} device — "
        f"{len(ids)} candidates: {', '.join(ids)}. Pass --device <id>."
    )


def run_case(case: dict, sim: Sim, args, out_dir: Path) -> dict:
    case_id = case["id"]
    verdict: dict = {"case_id": case_id, "status": "ERROR", "checks": []}
    transcript_path = str(out_dir / f"{case_id}.transcript.jsonl")

    precondition = case.get("precondition", {})
    try:
        playground_mod.reset(
            case["platform"], sim.udid, precondition.get("screen")
        )
    except playground_mod.ResetError as exc:
        verdict["error"] = f"reset failed: {exc}"
        return verdict

    try:
        run = agent_mod.run_agent(
            instruction=case["instruction"],
            platform=case["platform"],
            udid=sim.udid,
            transcript_path=transcript_path,
            timeout_s=case.get("timeout_s", 600),
            model=args.model,
            artifacts_dir=str(out_dir),
        )
        verdict.update(
            duration_s=run.duration_s,
            num_turns=run.num_turns,
            result_text=run.result_text,
            agent_exit=run.exit_code,
        )
    except FileNotFoundError:
        verdict["error"] = "`claude` CLI not found on PATH"
        return verdict

    checks = verify_mod.run_checks(
        case.get("verify", []), sim, transcript_path=transcript_path,
        workdir=str(out_dir),
    )
    verdict["checks"] = checks
    all_passed = all(c["passed"] for c in checks)
    verdict["status"] = "PASS" if (all_passed and run.exit_code == 0) else "FAIL"
    if run.exit_code != 0 and all_passed:
        verdict["notes"] = f"checks green but agent exited {run.exit_code}"
    return verdict


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--platform", choices=("ios", "android"))
    parser.add_argument("--device", default="", help="UDID / adb serial")
    parser.add_argument("--cases", default="", help="comma-separated case ids")
    parser.add_argument("--tags", default="", help="comma-separated tag filter (e.g. quick)")
    parser.add_argument("--model", default="", help="model override for the eval agent")
    parser.add_argument("--sim-use", default="", metavar="PATH", dest="sim_use",
                        help="sim-use binary to evaluate (default: whatever "
                             "`sim-use` resolves to on PATH) — e.g. a debug "
                             "build under .build/")
    parser.add_argument("--retries", type=int, default=0,
                        help="retry a FAILed case N times (flake control; default 0)")
    parser.add_argument("--list", action="store_true", help="list cases and exit")
    parser.add_argument("--count", action="store_true",
                        help="print the number of cases the filters select and exit")
    args = parser.parse_args()

    if args.list:
        for platform in ("ios", "android"):
            for case in load_cases(platform, None, None):
                tags = ",".join(case.get("tags", []))
                screen = case.get("precondition", {}).get("screen", "-")
                print(f"{case['id']:44s} screen={screen:16s} [{tags}]")
        return 0

    if not args.platform:
        parser.error("--platform is required (or use --list)")

    cases = load_cases(
        args.platform,
        [c for c in args.cases.split(",") if c] or None,
        [t for t in args.tags.split(",") if t] or None,
    )

    if args.count:
        print(len(cases))
        return 0

    if not cases:
        sys.exit("no cases matched")

    # Pin and announce the binary under test BEFORE anything touches a
    # device, so a run never silently exercises the wrong sim-use.
    if args.sim_use:
        install_sim_use_override(args.sim_use)
    binary_path, binary_version = sim_use_under_test()
    if binary_path.startswith("(") :
        sys.exit("sim-use not found on PATH; build one or pass --sim-use <path>")

    device = resolve_device(args.platform, args.device)
    sim = Sim(udid=device)

    out_dir = EVALS_DIR / "reports" / datetime.now().strftime("%Y%m%d-%H%M%S")
    report = RunReport(
        out_dir, args.platform, device,
        meta={"sim-use under test": f"{binary_path} ({binary_version})"},
    )
    print(f"[eval] sim-use under test: {binary_path} ({binary_version})")
    print(f"[eval] {len(cases)} case(s) on {args.platform} device {device}")
    print(f"[eval] report dir: {out_dir}")

    for case in cases:
        print(f"[eval] ── {case['id']} …")
        verdict = run_case(case, sim, args, out_dir)
        attempt = 0
        while verdict["status"] == "FAIL" and attempt < args.retries:
            attempt += 1
            print(f"[eval]    retry {attempt}/{args.retries}")
            verdict = run_case(case, sim, args, out_dir)
            if verdict["status"] == "PASS":
                verdict["notes"] = (
                    verdict.get("notes", "") + f" (passed on retry {attempt})"
                ).strip()
        report.record(verdict)
        print(f"[eval]    {verdict['status']}"
              + (f" — {verdict.get('error', '')}" if verdict.get("error") else ""))

    failed = [v for v in report.verdicts if v["status"] != "PASS"]
    print(f"\n[eval] done: {len(report.verdicts) - len(failed)}/{len(report.verdicts)} PASS")
    print(f"[eval] report: {out_dir / 'report.md'}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
