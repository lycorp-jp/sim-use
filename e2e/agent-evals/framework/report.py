# SPDX-License-Identifier: Apache-2.0
"""Run reports: verdicts.jsonl (machine) + report.md (human).

The markdown format follows the shape of the original autonomous eval session
report (env header → task table → issue details) so results stay comparable
across releases.
"""

from __future__ import annotations

import json
import platform as host_platform
import subprocess
from datetime import datetime
from pathlib import Path


def _sim_use_version() -> str:
    try:
        out = subprocess.run(
            ["sim-use", "--version"], capture_output=True, text=True, timeout=10
        )
        return out.stdout.strip() or "unknown"
    except FileNotFoundError:
        return "not installed"


class RunReport:
    def __init__(self, out_dir: Path, platform: str, udid: str, meta: dict | None = None):
        self.out_dir = out_dir
        self.out_dir.mkdir(parents=True, exist_ok=True)
        self.platform = platform
        self.udid = udid
        self.meta = meta or {}
        self.verdicts: list[dict] = []
        self.started = datetime.now()

    def record(self, verdict: dict) -> None:
        self.verdicts.append(verdict)
        with open(self.out_dir / "verdicts.jsonl", "a", encoding="utf-8") as fh:
            fh.write(json.dumps(verdict, ensure_ascii=False) + "\n")
        # Refresh the human report after every case so an interrupted run
        # still leaves a readable snapshot (checkpoint behaviour).
        self.write_markdown()

    def write_markdown(self) -> None:
        lines = [
            f"# sim-use agent-eval report — {self.started.strftime('%Y-%m-%d %H:%M')}",
            "",
            f"Env: sim-use {_sim_use_version()}, platform={self.platform}, "
            f"device={self.udid}, host={host_platform.platform()}",
        ]
        for key, value in self.meta.items():
            lines.append(f"{key}: {value}")
        passed = sum(1 for v in self.verdicts if v["status"] == "PASS")
        failed = sum(1 for v in self.verdicts if v["status"] == "FAIL")
        errored = sum(1 for v in self.verdicts if v["status"] == "ERROR")
        lines += [
            "",
            f"**{passed} PASS / {failed} FAIL / {errored} ERROR** "
            f"({len(self.verdicts)} cases)",
            "",
            "## Cases",
            "| # | Case | Status | Time | Turns | Notes |",
            "|---|------|--------|------|-------|-------|",
        ]
        for i, v in enumerate(self.verdicts, 1):
            notes = v.get("notes", "")
            lines.append(
                f"| {i} | {v['case_id']} | {v['status']} | {v.get('duration_s', '?')}s "
                f"| {v.get('num_turns', '?')} | {notes} |"
            )

        failures = [v for v in self.verdicts if v["status"] != "PASS"]
        if failures:
            lines += ["", "## Failures"]
            for v in failures:
                lines += [f"### {v['case_id']} — {v['status']}", ""]
                for check in v.get("checks", []):
                    mark = "✓" if check["passed"] else "✗"
                    lines.append(f"- {mark} `{check['check'].get('type')}` — {check['evidence']}")
                if v.get("error"):
                    lines.append(f"- runner error: {v['error']}")
                if v.get("result_text"):
                    lines += ["", f"Agent result: {v['result_text'][:500]}", ""]

        lines += [
            "",
            "## Classification guide",
            "Failures indicate a regression in the sim-use CLI or the bundled "
            "skill unless the notes say otherwise; the Playground fixture is "
            "repo-controlled, so fixture-side flakiness should be fixed in the "
            "fixture, not tolerated in the case.",
            "",
        ]
        (self.out_dir / "report.md").write_text("\n".join(lines), encoding="utf-8")
