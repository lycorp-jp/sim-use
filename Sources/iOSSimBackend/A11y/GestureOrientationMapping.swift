// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

/// Pure decision layer for orientation-aware directional gestures
/// (issue #66). Named presets (`scroll-*`, `swipe-from-*-edge`)
/// describe VISUAL directions, so their stroke math must run in the
/// UI space of the current interface orientation and the resulting
/// endpoints must cross into the native-portrait framebuffer space
/// the HID layer consumes — the same `uiToFramebuffer` mapping tap
/// selectors ride (issue #34). Explicit user coordinates never pass
/// through here.
public enum GestureOrientationMapping {

    /// The legacy preset canvas, kept as the last-resort fallback when
    /// no native screen size is known (identity calibration).
    public static let legacyWidth = 390.0
    public static let legacyHeight = 844.0

    /// The visual-space canvas the preset math runs in. Explicit
    /// `--screen-width` / `--screen-height` flags win per axis (they
    /// describe a visual-space viewport); missing axes come from the
    /// calibrated UI size, or the legacy 390x844 when the native size
    /// is unknown.
    public static func visualSize(
        explicitWidth: Double?,
        explicitHeight: Double?,
        calibration: OrientationCalibration
    ) -> (width: Double, height: Double) {
        let ui = calibration.uiScreenSize()
        return (
            explicitWidth ?? ui?.width ?? legacyWidth,
            explicitHeight ?? ui?.height ?? legacyHeight
        )
    }

    /// Maps one UI-space stroke's endpoints into HID (native-portrait
    /// framebuffer) coordinates. Identity (portrait or no native size)
    /// passes the stroke through bit-for-bit.
    public static func hidStroke(
        _ stroke: GesturePreset.Stroke,
        calibration: OrientationCalibration
    ) -> (startX: Double, startY: Double, endX: Double, endY: Double) {
        let start = calibration.hidCGPoint(CGPoint(x: stroke.startX, y: stroke.startY))
        let end = calibration.hidCGPoint(CGPoint(x: stroke.endX, y: stroke.endY))
        return (Double(start.x), Double(start.y), Double(end.x), Double(end.y))
    }
}

/// Shared calibration loader for standalone verbs whose coordinates
/// run in ui space (directional gesture presets, explicit coordinates).
/// The latest `describe-ui` snapshot calibrates first — a few hit-test
/// probes, no tree fetch. A full tree fetch (~70 ms on a simple screen,
/// more on a heavy one) runs when there is no snapshot or probes cannot
/// confirm it (`OrientationCalibrator.confirmedCalibration`). Degrades to
/// an identity dispatch with an explicit advisory when the simulator
/// cannot be calibrated at all — never silently.
@MainActor
public enum UISpaceCalibrationLoader {
    /// The advisory for explicit UI-space coordinates that could not be
    /// calibrated.
    public static let explicitCoordinatesFallback = "Screen orientation could not be determined; the coordinates were dispatched as native portrait points and may be wrong if the device is rotated. Run `ui` and try again, or pass --coordinate-space native for native points."

    public static func load(
        udid: String,
        fallbackMessage: String,
        logger: SimUseLogger
    ) async -> OrientationCalibration {
        if let snapshot = try? OutlineCache.read(udid: udid), !snapshot.entries.isEmpty {
            if let calibration = await OrientationCalibrator.confirmedCalibration(udid: udid, snapshot: snapshot, logger: logger) {
                return calibration
            }
            logger.info().log("The describe-ui snapshot could not be confirmed; fetching the tree")
        }
        do {
            return try await AccessibilityFetcher.fetchOrientationCalibration(for: udid, logger: logger)
        } catch {
            logger.info().log("Orientation calibration unavailable (\(error.localizedDescription)); dispatching in native portrait axes")
            return .identity(advisory: CommandAdvisory(
                kind: .orientationCalibrationFallback,
                message: fallbackMessage
            ))
        }
    }
}
