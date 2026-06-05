// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

/// Thin AndroidBackend-side accessors for UDID-shape classification.
/// The canonical implementation lives in `SimUseCore.PlatformRouter`;
/// this enum exists so AndroidBackend callsites read naturally
/// (`AndroidUDID.looksLikeAndroid(…)`) without forcing a SimUseCore
/// import on every Android verb. New code should prefer
/// `PlatformRouter.resolve(udid:)` for the structured platform answer.
public enum AndroidUDID {

    /// `true` when the UDID looks like an Android serial.
    ///
    /// Heuristic, in order:
    ///   1. `emulator-…` prefix → always Android (no digit / length
    ///      requirement, since emulator names are caller-controllable
    ///      and may carry a non-numeric suffix).
    ///   2. iOS UUID `8-4-4-4-12` → never Android.
    ///   3. ASCII-only, length 4–32, allowed characters
    ///      `[A-Za-z0-9._:_-]`, AND at least one digit → Android.
    ///
    /// Rule 3 is tighter than V1's "anything short and ascii": a typo
    /// like `--udid foo` (3 chars) or `--udid mycoolphone` (no
    /// digits) previously got classified Android and reached
    /// `adb -s <typo> ...` 5+ seconds later. Now those route through
    /// the iOS resolver and surface the friendlier "Simulator not
    /// found." message immediately. Real adb serials we ship against
    /// (`R5CT1ABCD12`, `7CKDU16C09042428`, `0123456789ABCDEF`,
    /// Wi-Fi adb's `192.168.1.5:5555`) all clear both bars.
    public static func looksLikeAndroid(_ udid: String) -> Bool {
        PlatformRouter.looksLikeAndroid(udid)
    }

    /// iOS Simulator UDID shape. Delegates to PlatformRouter so the
    /// classifier stays single-source-of-truth.
    public static func looksLikeIOSUDID(_ udid: String) -> Bool {
        PlatformRouter.looksLikeIOSSim(udid)
    }
}