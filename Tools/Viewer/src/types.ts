// SPDX-License-Identifier: Apache-2.0
export interface Frame {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface ListAlias {
  scope: number;
  index: number;
}

/**
 * Render a `ListAlias` as the user-facing token: bare `#N` for the
 * dominant list (scope=1) or scoped `#N@M` otherwise. Mirrors
 * `OutlineFormatter.elementLine` in the Swift CLI so the viewer's
 * badges and outline lines stay byte-consistent.
 */
export function formatListAlias(list: ListAlias): string {
  return list.scope <= 1 ? `#${list.index}` : `#${list.index}@${list.scope}`;
}

export interface Aliases {
  at: number;
  list?: ListAlias;
}

export interface ListSummary {
  scope: number;
  cellCount: number;
  cellHeight: number;
  containerRole: string;
  containerLabel?: string | null;
  bbox: Frame;
  score: number;
}

export interface Region {
  kind: string;
  label?: string | null;
}

export interface Entry {
  aliases: Aliases;
  role: string;
  label: string;
  frame: Frame;
  region: Region;
  states: string[];
  uniqueId?: string | null;
  depth?: number;
}

export interface Screen {
  appLabel: string;
  width: number;
  height: number;
}

export interface Snapshot {
  capturedAt: string;
  deviceId: string;
  /// `"ios"` and `"android"` are the only values sim-use emits
  /// today; treat anything else as a forward-compat hint and
  /// fall back to iOS-style rendering in the UI (the geometric
  /// conventions iOS uses — points, ~120pt status bar — are the
  /// safer default for an unknown platform).
  platform?: "ios" | "android";
  screen: Screen | null;
  outline: string;
  entries: Entry[];
  lists?: ListSummary[];
}

export interface Device {
  deviceId: string;
  name: string;
  // Widened to allow future platforms (web, etc.); the strict
  // union was forcing every consumer to `unknown`-cast on
  // mismatches. UI code should pattern-match on the canonical
  // values explicitly via `=== "android"` / `=== "ios"`.
  platform: "ios" | "android" | string;
  runtime: string;
}
