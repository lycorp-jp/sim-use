# SPDX-License-Identifier: Apache-2.0
"""Deterministic post-condition checks for eval cases.

Each check is a JSON object with a `type` plus type-specific fields; `run_checks`
executes them against a live device AFTER the agent finished and returns
(passed, evidence) per check. Checks observe end state only — they never drive
the UI (beyond describe-ui / screenshot / read-only shell probes), so a failure
means the agent did not leave the world in the expected state, not that the
verifier disturbed it.

Check types:
  element_exists      {"id": ...} or {"label_contains": ...} or {"outline_regex": ...}
  element_absent      same selectors, expects no match
  element_selected    {"id": ..., "expect": true|false}
  label_of            {"id": ..., "contains"/"equals"/"regex": ...}
  app_foreground      {"name": "<App: header value>"}
  file_exists         {"path": ..., "min_bytes": N}   (agent-produced artifact)
  transcript_regex    {"pattern": ..., "expect": true|false}  (agent transcript scan)
  shell               {"cmd": [...], "expect_exit": 0, "stdout_regex": ...}  (read-only probes)
"""

from __future__ import annotations

import os
import re
import subprocess

from .device import Sim, SimUseError


def run_checks(
    checks: list[dict],
    sim: Sim,
    transcript_path: str | None = None,
    workdir: str | None = None,
) -> list[dict]:
    """Returns one result dict per check: {check, passed, evidence}."""
    ui = None
    needs_ui = any(
        c.get("type")
        in ("element_exists", "element_absent", "element_selected", "label_of", "app_foreground")
        for c in checks
    )
    ui_error: str | None = None
    if needs_ui:
        try:
            ui = sim.describe_json_healed()
        except SimUseError as exc:  # verification itself hit a CLI failure
            ui_error = str(exc)

    transcript = ""
    if transcript_path and os.path.exists(transcript_path):
        with open(transcript_path, encoding="utf-8", errors="replace") as fh:
            transcript = fh.read()

    results = []
    for check in checks:
        if ui is None and check.get("type") in (
            "element_exists",
            "element_absent",
            "element_selected",
            "label_of",
            "app_foreground",
        ):
            results.append(
                {"check": check, "passed": False, "evidence": f"describe-ui failed: {ui_error}"}
            )
            continue
        passed, evidence = _run_one(check, ui, transcript, workdir, sim)
        results.append({"check": check, "passed": passed, "evidence": evidence})
    return results


def _find(check: dict, ui) -> tuple[object | None, str]:
    if "id" in check:
        return ui.find_id(check["id"]), f"#{check['id']}"
    if "label_contains" in check:
        return ui.find_label(check["label_contains"]), f"label*={check['label_contains']!r}"
    if "outline_regex" in check:
        m = re.search(check["outline_regex"], ui.outline)
        return (m, f"outline~/{check['outline_regex']}/")
    raise ValueError(f"element check needs id/label_contains/outline_regex: {check}")


def _run_one(
    check: dict, ui, transcript: str, workdir: str | None, sim: Sim
) -> tuple[bool, str]:
    ctype = check["type"]

    if ctype == "element_exists":
        found, desc = _find(check, ui)
        return (found is not None, f"{desc} {'found' if found else 'NOT found'}")

    if ctype == "element_absent":
        found, desc = _find(check, ui)
        return (found is None, f"{desc} {'absent' if found is None else 'unexpectedly present'}")

    if ctype == "element_selected":
        expect = check.get("expect", True)
        state = ui.is_selected(check["id"])
        if state is None:
            return (False, f"#{check['id']} not found")
        return (state == expect, f"#{check['id']} selected={state}, expected {expect}")

    if ctype == "label_of":
        element = ui.find_id(check["id"])
        if element is None:
            return (False, f"#{check['id']} not found")
        label = element.get("label") or ""
        if "equals" in check:
            ok = label == check["equals"]
            return (ok, f"label={label!r}, expected =={check['equals']!r}")
        if "contains" in check:
            ok = check["contains"] in label
            return (ok, f"label={label!r}, expected *{check['contains']!r}")
        if "regex" in check:
            ok = re.search(check["regex"], label) is not None
            return (ok, f"label={label!r}, expected ~/{check['regex']}/")
        raise ValueError(f"label_of needs equals/contains/regex: {check}")

    if ctype == "app_foreground":
        ok = ui.app_name == check["name"]
        return (ok, f"foreground app={ui.app_name!r}, expected {check['name']!r}")

    if ctype == "file_exists":
        path = check["path"]
        if workdir and not os.path.isabs(path):
            path = os.path.join(workdir, path)
        if not os.path.exists(path):
            return (False, f"{path} does not exist")
        size = os.path.getsize(path)
        min_bytes = check.get("min_bytes", 1)
        return (size >= min_bytes, f"{path} is {size} bytes (min {min_bytes})")

    if ctype == "transcript_regex":
        expect = check.get("expect", True)
        found = re.search(check["pattern"], transcript) is not None
        return (
            found == expect,
            f"transcript {'matches' if found else 'does not match'} /{check['pattern']}/"
            f", expected match={expect}",
        )

    if ctype == "shell":
        cmd = [part.replace("{device}", sim.udid) for part in check["cmd"]]
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        expect_exit = check.get("expect_exit", 0)
        if proc.returncode != expect_exit:
            return (False, f"exit {proc.returncode}, expected {expect_exit}: {proc.stderr[:200]}")
        if "stdout_regex" in check:
            ok = re.search(check["stdout_regex"], proc.stdout) is not None
            return (ok, f"stdout {'matches' if ok else 'does not match'} /{check['stdout_regex']}/")
        return (True, f"exit {proc.returncode}")

    raise ValueError(f"unknown check type: {ctype}")
