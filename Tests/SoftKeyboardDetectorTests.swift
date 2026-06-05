// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
import Foundation
import Testing

// MARK: - Fixture loading

/// Minimal envelope for the JSON written by `sim-use describe-ui --json`.
/// Only the `raw` field is needed — that is the array of
/// `AccessibilityElement` values the live detector consumes after the
/// daemon's network hop. Fixtures are checked in under
/// `Tests/Fixtures/SoftKeyboard/<layout>.json` so the algorithm can be
/// regressed across layouts without booting a simulator.
private struct DescribeUIFixture: Decodable {
    let data: Payload

    struct Payload: Decodable {
        let raw: [AccessibilityElement]
    }
}

private func loadFixture(_ name: String) throws -> [AccessibilityElement] {
    let url = try #require(
        Bundle.module.url(forResource: "Fixtures/SoftKeyboard/\(name)", withExtension: "json"),
        "Fixture '\(name)' not bundled. Add the file under Tests/Fixtures/SoftKeyboard/ and re-run."
    )
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(DescribeUIFixture.self, from: data).data.raw
}

// MARK: - Detector tests

@Suite("SoftKeyboardDetector — fixture-based regression")
struct SoftKeyboardDetectorTests {
    // Layout: 9-key Japanese kana keyboard (ja_JP locale).
    // Pre-fix observation: chrome=1, letters=0 → false-negative (hidden).
    // Post-fix expectation: idChromeCount=4 (#delete, #emoji, #dictation,
    // #Search) and globeSeen=true (次のキーボード) — primary path alone
    // already clears the threshold of 2.
    @Test("kana 9-key keyboard is reported visible")
    func visibleOnKana() throws {
        let elements = try loadFixture("kana")
        let state = SoftKeyboardDetector.classify(elements: elements)

        #expect(state.visible == true,
                "kana keyboard must be detected as visible. Counts: chrome=\(state.chromeKeyCount) letters=\(state.letterKeyCount) idChrome=\(state.idChromeCount) globe=\(state.globeSeen)")
        #expect(state.idChromeCount >= 2,
                "AXIdentifier-based primary signal must clear threshold (>=2) on kana — actual \(state.idChromeCount)")
        #expect(state.globeSeen == true,
                "Globe / Next Keyboard label must be detected on kana")
    }

    // Layout: Latin QWERTY (English keyboard with ja_JP system locale).
    // Pre-fix observation: passed via the existing `letters >= 10` path,
    // chrome=2 already below threshold; no regression risk.
    // Post-fix expectation: every signal fires simultaneously
    // (idChromeCount=7, globeSeen=true, letterKeyCount=26).
    @Test("QWERTY keyboard is reported visible")
    func visibleOnQwerty() throws {
        let elements = try loadFixture("qwerty")
        let state = SoftKeyboardDetector.classify(elements: elements)

        #expect(state.visible == true,
                "QWERTY keyboard must be detected as visible. Counts: chrome=\(state.chromeKeyCount) letters=\(state.letterKeyCount) idChrome=\(state.idChromeCount) globe=\(state.globeSeen)")
        #expect(state.idChromeCount >= 2)
        #expect(state.letterKeyCount >= 10,
                "Latin letter fallback must still fire on QWERTY — actual \(state.letterKeyCount)")
    }

    // Layout: Hangul 한글 9-key (Korean keyboard added on top of ja_JP).
    // Pre-fix observation: chrome=1, letters=0 → false-negative (hidden)
    // — jamo characters like ㄱ / ㅏ are not Latin so the letter path
    // can never fire on Hangul.
    // Post-fix expectation: idChromeCount=5 (#delete, #Search, #emoji,
    // #space, #dictation) plus globeSeen=true.
    @Test("Hangul keyboard is reported visible")
    func visibleOnHangul() throws {
        let elements = try loadFixture("hangul")
        let state = SoftKeyboardDetector.classify(elements: elements)

        #expect(state.visible == true,
                "Hangul keyboard must be detected as visible. Counts: chrome=\(state.chromeKeyCount) letters=\(state.letterKeyCount) idChrome=\(state.idChromeCount) globe=\(state.globeSeen)")
        #expect(state.idChromeCount >= 2)
        #expect(state.globeSeen == true)
    }

    // Layout: iOS Emoji picker.
    // Pre-fix observation: chrome=2, letters=0 → false-negative (hidden).
    // Post-fix expectation: idChromeCount=2 (#delete, #dictation) — the
    // weakest id signal across the four supported layouts, which is why
    // the primary threshold is exactly 2. globeLabel also fires.
    @Test("emoji picker is reported visible")
    func visibleOnEmojiPicker() throws {
        let elements = try loadFixture("emoji")
        let state = SoftKeyboardDetector.classify(elements: elements)

        #expect(state.visible == true,
                "emoji picker must be detected as visible. Counts: chrome=\(state.chromeKeyCount) letters=\(state.letterKeyCount) idChrome=\(state.idChromeCount) globe=\(state.globeSeen)")
        #expect(state.idChromeCount >= 2,
                "AXIdentifier-based primary signal must clear threshold (>=2) on emoji picker — actual \(state.idChromeCount)")
    }

    // Baseline: app is foregrounded but no software keyboard is up.
    // Guards against false-positives from any of the four paths.
    @Test("no keyboard is reported hidden")
    func hiddenWithoutKeyboard() throws {
        let elements = try loadFixture("no-keyboard")
        let state = SoftKeyboardDetector.classify(elements: elements)

        #expect(state.visible == false,
                "Bare app screen must be detected as hidden. Counts: chrome=\(state.chromeKeyCount) letters=\(state.letterKeyCount) idChrome=\(state.idChromeCount) globe=\(state.globeSeen)")
        #expect(state.idChromeCount == 0)
        #expect(state.globeSeen == false)
    }
}