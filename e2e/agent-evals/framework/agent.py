# SPDX-License-Identifier: Apache-2.0
"""Headless agent invocation for OSS skill evals.

Each case runs `claude -p` in a throwaway workdir with this repo's
`skills/sim-use/` installed at `.claude/skills/sim-use` — the same bytes
`sim-use init` ships to users. The agent gets one natural-language
instruction; verb choice, pitfall handling, and observe→act→verify discipline
are the skill's job, which is what is being evaluated.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent.parent
_SKILL_DIR = _REPO_ROOT / "skills" / "sim-use"

_ALLOWED_TOOLS = [
    "Bash(sim-use *)",
    "Bash(xcrun simctl *)",
    "Bash(adb *)",
    "Bash(ls*)",
    "Bash(cat *)",
    "Read",
    "Glob",
    "Grep",
]

_PROMPT_TEMPLATE = """\
You are operating a {platform} device with the sim-use CLI.

Device id: {udid}
Skill: read .claude/skills/sim-use/SKILL.md first and follow it. The
sim-use Playground app is already installed on the device; do not build or
install anything.

Task:
{instruction}

When done, print a single line starting with `RESULT: ` summarising what you
did and whether you believe you succeeded.
"""


@dataclass
class AgentRun:
    exit_code: int
    duration_s: float
    result_text: str
    transcript_path: str
    workdir: str
    num_turns: int | None = None
    total_cost_usd: float | None = None


class _Tolerant(dict):
    def __missing__(self, key: str) -> str:
        return "{" + key + "}"


def make_workdir(base_dir: str | None = None) -> str:
    if not (_SKILL_DIR / "SKILL.md").exists():
        raise RuntimeError(f"skill not found at {_SKILL_DIR}")
    workdir = tempfile.mkdtemp(prefix="sim-use-agent-eval-", dir=base_dir)
    shutil.copytree(_SKILL_DIR, Path(workdir) / ".claude" / "skills" / "sim-use")
    return workdir


def run_agent(
    instruction: str,
    platform: str,
    udid: str,
    transcript_path: str,
    timeout_s: int = 600,
    model: str | None = None,
    keep_workdir: bool = False,
    artifacts_dir: str = "",
) -> AgentRun:
    workdir = make_workdir()
    instruction_vars = _Tolerant(device=udid, artifacts=artifacts_dir)
    prompt = _PROMPT_TEMPLATE.format_map(
        _Tolerant(
            platform=platform,
            udid=udid,
            instruction=instruction.format_map(instruction_vars),
        )
    )

    cmd = [
        "claude",
        "-p", prompt,
        "--output-format", "stream-json",
        "--verbose",
        "--allowedTools", ",".join(_ALLOWED_TOOLS),
    ]
    if model:
        cmd += ["--model", model]

    env = {k: v for k, v in os.environ.items() if not k.startswith("CLAUDE")}
    env["SIM_USE_DEVICE"] = udid

    start = time.monotonic()
    result_text = ""
    num_turns = None
    total_cost = None
    with open(transcript_path, "w", encoding="utf-8") as transcript:
        proc = subprocess.Popen(
            cmd,
            cwd=workdir,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        try:
            assert proc.stdout is not None
            for line in proc.stdout:
                transcript.write(line)
                event = _maybe_json(line)
                if event and event.get("type") == "result":
                    result_text = event.get("result") or ""
                    num_turns = event.get("num_turns")
                    total_cost = event.get("total_cost_usd")
                if time.monotonic() - start > timeout_s:
                    proc.kill()
                    result_text = result_text or "(killed: case timeout)"
                    break
            exit_code = proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            proc.kill()
            exit_code = -9

    if not keep_workdir:
        shutil.rmtree(workdir, ignore_errors=True)

    return AgentRun(
        exit_code=exit_code,
        duration_s=round(time.monotonic() - start, 1),
        result_text=result_text,
        transcript_path=transcript_path,
        workdir=workdir,
        num_turns=num_turns,
        total_cost_usd=total_cost,
    )


def _maybe_json(line: str) -> dict | None:
    line = line.strip()
    if not line.startswith("{"):
        return None
    try:
        return json.loads(line)
    except json.JSONDecodeError:
        return None
