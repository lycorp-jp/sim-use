// SPDX-License-Identifier: Apache-2.0
import ArgumentParser

/// Coordinate space for explicit iOS coordinates.
///
/// `ui` (the default) — visual space, the space every frame printed by
/// `describe-ui` uses. Points are transformed through a per-command
/// orientation calibration before dispatch, so coordinates lifted from
/// the outline stay correct on a rotated device, a display-downscaled
/// device and a display other than the main one.
///
/// `native` — the routing display's native portrait points: the HID
/// layer's own space and the contract before 0.16.0. No calibration.
///
/// Work record: docs/ai/010-display-routing/000-plan.md (S3).
public enum CoordinateSpace: String, CaseIterable, ExpressibleByArgument, Sendable {
    case native
    case ui
}
