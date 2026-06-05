// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Shared error-message factory for the HID-keyed verbs (`key`,
/// `key-sequence`, `key-combo`) when invoked against an Android UDID.
///
/// These verbs are intrinsically iOS-only: they speak USB HID Usage IDs
/// (e.g. `0x04` = A), which a third-party Android APK cannot inject into
/// the system event stream without the `INJECT_EVENTS` permission, and
/// which would not be semantically meaningful even if we could (Android
/// uses a separate `KeyEvent.KEYCODE_*` table). We surface the user back
/// to the Android-native equivalents instead of trying to bridge an
/// impedance mismatch.
///
/// The iOS-only HID verbs are reached exclusively through
/// `sim-use ios key` / `sim-use ios key-sequence` /
/// `sim-use ios key-combo`. The redirect message below explicitly
/// includes the `ios` namespace in the suggestions so a misdirected
/// caller learns the canonical form.
public enum HIDKeyCommandHelp {
    public static func androidUnsupportedMessage(verb: String, udid: String) -> String {
        """
        `\(verb)` is not supported on Android (\(udid)). The iOS implementation \
        injects USB HID keycodes, which third-party Android apps cannot do. \
        On Android, use:
          sim-use button {home,back,recents,power} --udid \(udid)   # navigation keys
          sim-use type "..." --udid \(udid)                          # arbitrary text (UTF-8, multi-line)
          sim-use paste "..." --replace --udid \(udid)               # clipboard-driven input
        For Enter, embed "\\n" in the text passed to `type`.
        """
    }
}