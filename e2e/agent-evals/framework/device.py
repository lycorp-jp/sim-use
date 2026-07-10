# SPDX-License-Identifier: Apache-2.0
"""Thin sim-use CLI wrapper + describe-ui JSON accessors for eval verification.

Adapted from the proven Sim/Ui classes in the upstream eval framework
trimmed to what deterministic
post-condition verification needs. Framework code — never shipped in a bundle.
"""

from __future__ import annotations

import json
import re
import subprocess
from dataclasses import dataclass


class SimUseError(RuntimeError):
    """sim-use exited non-zero."""


@dataclass
class Sim:
    """Runs sim-use subcommands against one device."""

    udid: str = ""
    verbose: bool = False

    def run(self, *args: str, timeout: float = 60.0) -> str:
        cmd = ["sim-use", args[0]]
        if self.udid:
            cmd += ["--device", self.udid]
        cmd += list(args[1:])
        if self.verbose:
            print(f"  $ {' '.join(cmd)}")
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        if proc.returncode != 0:
            raise SimUseError(
                f"{' '.join(cmd)} -> exit {proc.returncode}\n{proc.stderr.strip()}"
            )
        return proc.stdout

    def describe_json(self) -> "Ui":
        out = self.run("describe-ui", "--json", timeout=90.0)
        return Ui(json.loads(out))

    def screenshot(self, path: str) -> None:
        self.run("screenshot", "--output", path)

    def daemon_stop(self) -> None:
        subprocess.run(
            ["sim-use", "daemon", "stop", "--device", self.udid],
            capture_output=True,
            text=True,
        )

    def describe_json_healed(self) -> "Ui":
        """describe-ui with one daemon-restart retry (known transient after idle)."""
        try:
            return self.describe_json()
        except SimUseError:
            self.daemon_stop()
            return self.describe_json()


class Ui:
    """Accessors over `describe-ui --json` output.

    Entry fields (both platforms): `uniqueId` (AX unique id), `resource_id`
    (Android resource id short name), `label`, `role`, `states` (e.g.
    ["selected"]), `frame`, `aliases`. Top-level `appLabel` names the
    foreground app.
    """

    def __init__(self, payload: dict):
        self.payload = payload
        data = payload.get("data", payload)
        self.data = data
        self.outline: str = data.get("outline", "")
        self.entries: list[dict] = data.get("entries", [])

    @property
    def app_name(self) -> str:
        if label := self.data.get("appLabel"):
            return label
        m = re.search(r"App:\s+(.+?)\s+\d+x\d+", self.outline)
        return m.group(1) if m else ""

    def _iter(self):
        yield from self.entries

    def find_id(self, element_id: str) -> dict | None:
        """Match by AX uniqueId first, then Android resource_id."""
        for e in self._iter():
            if e.get("uniqueId") == element_id:
                return e
        for e in self._iter():
            if e.get("resource_id") == element_id:
                return e
        return None

    def find_label(self, needle: str, exact: bool = False) -> dict | None:
        for e in self._iter():
            label = e.get("label") or ""
            if (label == needle) if exact else (needle in label):
                return e
        return None

    def has_id(self, unique_id: str) -> bool:
        return self.find_id(unique_id) is not None

    def has_label(self, needle: str) -> bool:
        return self.find_label(needle) is not None

    def outline_contains(self, needle: str) -> bool:
        return needle in self.outline

    def outline_matches(self, pattern: str) -> bool:
        return re.search(pattern, self.outline) is not None

    def is_selected(self, element_id: str) -> bool | None:
        """True/False when the element is found, None when missing."""
        e = self.find_id(element_id)
        if e is None:
            return None
        return "selected" in (e.get("states") or [])
