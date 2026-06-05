// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Inspects the frontmost app's accessibility tree for signals that an
/// on-screen software keyboard is currently visible.
///
/// The simulator does not expose the keyboard as a discrete AX node
/// (no `AXKeyboard` role, no dedicated subrole), so detection relies on
/// four independent signals on characteristic descendant Buttons.
///
///   1. **AXIdentifier chrome count (primary)** — Apple's system keyboard
///      tags chrome keys with locale-independent `AXIdentifier` values
///      (`delete`, `emoji`, `dictation`, `Search`, `space`, `shift`,
///      `more`, `return`). These remain English even on Japanese / Korean /
///      Chinese keyboards, so a single set covers every layout. ≥ 2 hits
///      is diagnostic — picked to accommodate the emoji picker, which
///      exposes only `#delete` and `#dictation`.
///   2. **Globe label (secondary)** — the 🌐 Next Keyboard button has
///      *no* AXIdentifier on iOS 26.x, so we fall back to a small label
///      whitelist (`Next Keyboard` / `次のキーボード` / `下一个键盘` /
///      `下一個鍵盤` / `다음 키보드`). Any single hit is diagnostic — the
///      button only exists when more than one input source is enabled,
///      but in the common case it's the cheapest signal.
///   3. **Latin letter count (fallback A)** — QWERTY exposes 26
///      single-character Buttons; ≥ 10 covers every Latin layout.
///   4. **Localized chrome label whitelist (fallback B)** — the original
///      heuristic, kept narrow on purpose. ≥ 3 distinct hits is
///      diagnostic and covers older iOS or layouts where AXIdentifiers
///      are missing.
///
/// Any single signal is enough; the four are computed together in one
/// flat-tree pass and surfaced individually so a misfire is debuggable
/// directly from `keyboard-state --json` without re-running describe-ui.
public enum SoftKeyboardDetector {
    public struct State: Codable {
        public let visible: Bool
        public let chromeKeyCount: Int
        public let letterKeyCount: Int
        // New diagnostic fields — surface every detection signal so a
        // misfire is debuggable from `keyboard-state --json` alone
        // without re-running describe-ui.
        public let idChromeCount: Int
        public let globeSeen: Bool
    }

    // Labels that the iOS keyboard exposes via VoiceOver for chrome keys.
    // Kept narrow on purpose — a wider net would catch app-level buttons
    // (e.g. a "Return" button in a form) and produce false positives.
    // A count of ≥ `chromeKeyThreshold` clears the noise floor.
    private static let chromeKeyLabels: Set<String> = [
        // English / locale-independent system labels
        "shift",
        "delete",
        "return",
        "space",
        "numbers",
        "more",
        "Emoji",
        "Dictation",
        "Next Keyboard",
        // Chinese
        "下一个键盘",
        "听写",
        "换行",
        "空格",
        // Japanese
        "改行",
        "スペース",
        "次のキーボード",
        // Korean
        "다음 키보드",
        "받아쓰기",
    ]

    public static let chromeKeyThreshold = 3

    // Locale-independent AXIdentifier tags Apple's system keyboard
    // attaches to chrome keys. Verified on iOS 26.x across kana / QWERTY
    // / Hangul / emoji-picker layouts: ids stay English even when labels
    // are localized (`削除` / `이모지` / `絵文字` etc.).
    private static let chromeAXIdentifiers: Set<String> = [
        "shift",
        "delete",
        "return",
        "Search",
        "more",
        "emoji",
        "dictation",
        "space",
    ]

    public static let idChromeThreshold = 2

    // Labels for the 🌐 Next Keyboard button. The button has no
    // AXIdentifier in iOS 26.x, so label is the only signal — but the
    // set is small and unlikely to collide with app UI.
    private static let globeLabels: Set<String> = [
        "Next Keyboard",
        "次のキーボード",
        "下一个键盘",
        "下一個鍵盤",
        "다음 키보드",
    ]

    @MainActor
    public static func detect(
        for simulatorUDID: String,
        logger: SimUseLogger
    ) async throws -> State {
        // maxProbes=0 skips CollapsedChildrenRecovery; the keyboard's key
        // rows live in the base tree as direct Buttons and never need
        // empty-AXGroup probing. Keeps detection cheap (~50-150 ms).
        let jsonData = try await AccessibilityFetcher.fetchAccessibilityInfoJSONData(
            for: simulatorUDID,
            point: nil,
            logger: logger,
            maxProbes: 0
        )

        let elements: [AccessibilityElement]
        let decoder = JSONDecoder()
        do {
            elements = try decoder.decode([AccessibilityElement].self, from: jsonData)
        } catch let DecodingError.typeMismatch(_, context) where context.codingPath.isEmpty {
            elements = [try decoder.decode(AccessibilityElement.self, from: jsonData)]
        }
        return classify(elements: elements)
    }

    /// Pure entry point: counts the four characteristic signals across
    /// the flattened tree and returns the diagnosed state. Exists so
    /// fixture-based unit tests can drive detection without booting a
    /// simulator.
    public static func classify(elements: [AccessibilityElement]) -> State {
        let flat = elements.flatMap { $0.flattened() }

        var idChrome = 0
        var globeSeen = false
        var chrome = 0
        var letters = 0
        for element in flat {
            guard element.type == "Button" else { continue }
            if let id = element.normalizedUniqueId, chromeAXIdentifiers.contains(id) {
                idChrome += 1
            }
            guard let label = element.normalizedLabel else { continue }
            if globeLabels.contains(label) {
                globeSeen = true
            }
            if chromeKeyLabels.contains(label) {
                chrome += 1
            } else if label.count == 1,
                      let scalar = label.unicodeScalars.first,
                      isLatinLetter(scalar) {
                letters += 1
            }
        }

        let visible = idChrome >= idChromeThreshold
            || globeSeen
            || letters >= 10
            || chrome >= chromeKeyThreshold
        return State(
            visible: visible,
            chromeKeyCount: chrome,
            letterKeyCount: letters,
            idChromeCount: idChrome,
            globeSeen: globeSeen
        )
    }

    private static func isLatinLetter(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 0x41 && scalar.value <= 0x5A) ||
        (scalar.value >= 0x61 && scalar.value <= 0x7A)
    }
}