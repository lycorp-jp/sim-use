// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AndroidBackend
import SimUseCore

final class AndroidSelectorTests: XCTestCase {

    private func makeEntries() -> [Outline.Entry] {
        [
            Outline.Entry(
                aliases: .init(at: 1),
                role: "Button",
                label: "Log in",
                frame: .init(x: 100, y: 200, width: 300, height: 80),
                region: .init(kind: "Content"),
                states: [],
                uniqueId: "login_button",
                value: nil,
                resourceId: "login_button",
                hint: nil
            ),
            Outline.Entry(
                aliases: .init(at: 2),
                role: "TextView",
                label: "Tap Log in to continue",
                frame: .init(x: 100, y: 100, width: 800, height: 40),
                region: .init(kind: "Content"),
                states: [],
                uniqueId: nil,
                value: nil,
                resourceId: nil,
                hint: nil
            ),
            Outline.Entry(
                aliases: .init(at: 3),
                role: "TextField",
                label: "",
                frame: .init(x: 100, y: 300, width: 800, height: 60),
                region: .init(kind: "Content"),
                states: [],
                uniqueId: nil,
                value: "wei.wang@example.com",
                resourceId: "email_field",
                hint: "Email"
            ),
        ]
    }

    func testResolvesByUniqueId() throws {
        let entries = makeEntries()
        let match = try AndroidSelectorResolver.resolve(
            selector: AndroidSelector(id: "login_button"),
            entries: entries
        )
        XCTAssertEqual(match.aliases.at, 1)
    }

    func testResolvesByResourceIdViaIdFlag() throws {
        let entries = makeEntries()
        let match = try AndroidSelectorResolver.resolve(
            selector: AndroidSelector(id: "email_field"),
            entries: entries
        )
        XCTAssertEqual(match.aliases.at, 3)
    }

    func testResolvesByLabelExact() throws {
        let entries = makeEntries()
        let match = try AndroidSelectorResolver.resolve(
            selector: AndroidSelector(label: "Log in"),
            entries: entries
        )
        XCTAssertEqual(match.aliases.at, 1)
    }

    func testLabelContainsPrefersActionableOnAmbiguity() throws {
        // Two entries match "Log in": the Button and the TextView blurb.
        // The resolver narrows ambiguous matches to the actionable subset
        // before raising; here the Button uniquely survives and is
        // returned without forcing the caller to add --element-type.
        let entries = makeEntries()
        let match = try AndroidSelectorResolver.resolve(
            selector: AndroidSelector(labelContains: "Log in"),
            entries: entries
        )
        XCTAssertEqual(match.aliases.at, 1)
        XCTAssertEqual(match.role, "Button")
    }

    func testLabelContainsStillAmbiguousWhenMultipleActionable() {
        // Two Buttons both match — the actionable-narrow filter cannot
        // pick a winner and the original ambiguity error is preserved so
        // the caller adds further disambiguation.
        let entries: [Outline.Entry] = [
            Outline.Entry(
                aliases: .init(at: 1),
                role: "Button",
                label: "Save changes",
                frame: .init(x: 0, y: 0, width: 100, height: 50),
                region: .init(kind: "Content"),
                states: []
            ),
            Outline.Entry(
                aliases: .init(at: 2),
                role: "Button",
                label: "Save draft",
                frame: .init(x: 0, y: 60, width: 100, height: 50),
                region: .init(kind: "Content"),
                states: []
            ),
        ]
        XCTAssertThrowsError(try AndroidSelectorResolver.resolve(
            selector: AndroidSelector(labelContains: "Save"),
            entries: entries
        )) { error in
            switch error as? AndroidSelectorError {
            case .ambiguous(_, let count, _):
                XCTAssertEqual(count, 2)
            default:
                XCTFail("Expected ambiguous error, got \(error)")
            }
        }
    }

    func testLabelContainsStillAmbiguousWhenNoActionableMatch() {
        // No interactive candidate among the matches — fall back to the
        // original ambiguity error rather than guessing a non-actionable.
        let entries: [Outline.Entry] = [
            Outline.Entry(
                aliases: .init(at: 1),
                role: "TextView",
                label: "Welcome back",
                frame: .init(x: 0, y: 0, width: 100, height: 50),
                region: .init(kind: "Content"),
                states: []
            ),
            Outline.Entry(
                aliases: .init(at: 2),
                role: "TextView",
                label: "Welcome to LINE",
                frame: .init(x: 0, y: 60, width: 100, height: 50),
                region: .init(kind: "Content"),
                states: []
            ),
        ]
        XCTAssertThrowsError(try AndroidSelectorResolver.resolve(
            selector: AndroidSelector(labelContains: "Welcome"),
            entries: entries
        )) { error in
            switch error as? AndroidSelectorError {
            case .ambiguous(_, let count, _):
                XCTAssertEqual(count, 2)
            default:
                XCTFail("Expected ambiguous error, got \(error)")
            }
        }
    }

    func testElementTypeNarrowsSelector() throws {
        let entries = makeEntries()
        let match = try AndroidSelectorResolver.resolve(
            selector: AndroidSelector(labelContains: "Log in", elementType: "Button"),
            entries: entries
        )
        XCTAssertEqual(match.aliases.at, 1)
    }

    func testValueContains() throws {
        let entries = makeEntries()
        let match = try AndroidSelectorResolver.resolve(
            selector: AndroidSelector(valueContains: "example.com"),
            entries: entries
        )
        XCTAssertEqual(match.aliases.at, 3)
    }

    func testLabelContainsIsCaseSensitive() {
        // Mirrors iOS `--label-contains` semantics (and the documented
        // help text). Before this guard the Android resolver used
        // `localizedCaseInsensitiveContains`, so "log in" lowercase
        // matched the "Log in" Button on Android but missed it on iOS —
        // a silent cross-platform behaviour gap. The selector must now
        // miss on a case mismatch; agents wanting case-insensitive
        // matching pass a `(?i)…` regex via `--label-regex`.
        let entries = makeEntries()
        XCTAssertThrowsError(try AndroidSelectorResolver.resolve(
            selector: AndroidSelector(labelContains: "log in"),
            entries: entries
        )) { error in
            switch error as? AndroidSelectorError {
            case .noMatch: break
            default: XCTFail("Expected noMatch, got \(error)")
            }
        }
    }

    func testValueContainsIsCaseSensitive() {
        // Symmetric with labelContains: case mismatch must miss.
        let entries = makeEntries()
        XCTAssertThrowsError(try AndroidSelectorResolver.resolve(
            selector: AndroidSelector(valueContains: "EXAMPLE.COM"),
            entries: entries
        )) { error in
            switch error as? AndroidSelectorError {
            case .noMatch: break
            default: XCTFail("Expected noMatch, got \(error)")
            }
        }
    }

    func testNoMatchRaises() {
        let entries = makeEntries()
        XCTAssertThrowsError(try AndroidSelectorResolver.resolve(
            selector: AndroidSelector(id: "nonexistent"),
            entries: entries
        ))
    }

    /// `tap --id 5` is the classic agent confusion: the user means the
    /// outline alias `@5` but reaches for `--id`. When the resolver
    /// fails on a small-integer id, the error message must include the
    /// `Did you mean @N?` hint — and it must fire **regardless of
    /// whether other selector flags are set**. iOS's
    /// `AccessibilityTargetResolver.swift:25` triggers the hint solely
    /// on `kind == "id"` + small-int parse; Android should mirror that
    /// (a combo like `tap --id 5 --element-type Button` is still the
    /// same confused-with-alias intent).
    func testNoMatchHintForSmallIntId() {
        let entries = makeEntries()
        // Bare --id 5 — must include the alias hint.
        XCTAssertThrowsError(try AndroidSelectorResolver.resolve(
            selector: AndroidSelector(id: "5"),
            entries: entries
        )) { error in
            let message = (error as? AndroidSelectorError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("@5"),
                          "expected `@5` alias hint in error, got: \(message)")
        }
    }

    func testNoMatchHintForSmallIntIdWithExtraFlags() {
        let entries = makeEntries()
        // Combo — hint must still fire, mirroring iOS.
        XCTAssertThrowsError(try AndroidSelectorResolver.resolve(
            selector: AndroidSelector(id: "5", elementType: "Button"),
            entries: entries
        )) { error in
            let message = (error as? AndroidSelectorError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("@5"),
                          "expected `@5` alias hint to fire even with --element-type set; got: \(message)")
        }
    }

    /// Negative regression: when `--id` is not a small positive integer
    /// the hint must not fire (the user actually has a literal id).
    func testNoMatchHintSuppressedForNonAliasId() {
        let entries = makeEntries()
        XCTAssertThrowsError(try AndroidSelectorResolver.resolve(
            selector: AndroidSelector(id: "feed_button"),
            entries: entries
        )) { error in
            let message = (error as? AndroidSelectorError)?.errorDescription ?? ""
            XCTAssertFalse(message.contains("Did you mean"),
                           "alias hint must not fire for non-integer ids; got: \(message)")
        }
    }

    func testEmptySelectorRaises() {
        let entries = makeEntries()
        XCTAssertThrowsError(try AndroidSelectorResolver.resolve(
            selector: AndroidSelector(),
            entries: entries
        ))
    }

    /// `--id` is a stability contract: the user is asking for the
    /// element whose AXUniqueId / resource_id matches literally.
    /// When several entries collide on the same id (typically several
    /// `RecyclerView` cells sharing a `:id/...` resource id), the
    /// agent reaches for `tap --id chat_row` expecting to be told the
    /// id isn't unique — not for the resolver to silently pick the
    /// one that happens to be actionable. Mirrors iOS:
    /// `AccessibilityTargetResolver.selectUniqueMatch` doesn't do
    /// actionable narrowing for `--id`; only
    /// `selectBestLabelMatch` (the label/value paths) does.
    func testIdAmbiguousDoesNotNarrowToActionable() {
        let entries: [Outline.Entry] = [
            Outline.Entry(
                aliases: .init(at: 1),
                role: "View",
                label: "Chat 1",
                frame: .init(x: 0, y: 0, width: 1080, height: 200),
                region: .init(kind: "Content"),
                states: [],
                uniqueId: nil, value: nil,
                resourceId: "chat_row", hint: nil
            ),
            Outline.Entry(
                aliases: .init(at: 2),
                role: "View",
                label: "Chat 2",
                frame: .init(x: 0, y: 200, width: 1080, height: 200),
                region: .init(kind: "Content"),
                states: [],
                uniqueId: nil, value: nil,
                resourceId: "chat_row", hint: nil
            ),
            Outline.Entry(
                aliases: .init(at: 3),
                role: "View",
                label: "Chat 3",
                frame: .init(x: 0, y: 400, width: 1080, height: 200),
                region: .init(kind: "Content"),
                states: [],
                uniqueId: nil, value: nil,
                resourceId: "chat_row", hint: nil
            ),
            // The fold-promoted single Button that the resolver
            // previously snapped to silently.
            Outline.Entry(
                aliases: .init(at: 4),
                role: "Button",
                label: "Decoy",
                frame: .init(x: 0, y: 600, width: 100, height: 100),
                region: .init(kind: "Content"),
                states: [],
                uniqueId: nil, value: nil,
                resourceId: "chat_row", hint: nil
            ),
        ]
        XCTAssertThrowsError(try AndroidSelectorResolver.resolve(
            selector: AndroidSelector(id: "chat_row"),
            entries: entries
        )) { error in
            switch error as? AndroidSelectorError {
            case .ambiguous(_, let count, _):
                XCTAssertEqual(
                    count, 4,
                    "All four entries must surface as ambiguous; actionable-narrow must not silently pick the Button."
                )
            default:
                XCTFail("Expected .ambiguous, got \(error)")
            }
        }
    }

    /// Regression guard: `--id` with a unique match still returns
    /// the single entry. The narrowing change must not affect the
    /// happy path.
    func testIdUniqueMatchStillReturns() throws {
        let entries = makeEntries()
        let match = try AndroidSelectorResolver.resolve(
            selector: AndroidSelector(id: "login_button"),
            entries: entries
        )
        XCTAssertEqual(match.aliases.at, 1)
    }

    /// Collision priority: when two entries hit the same `--id` value
    /// — one via `uniqueId`, the other via `resourceId` — the
    /// `uniqueId` match wins outright. Mirrors the resolution priority
    /// documented above `resolve(selector:)`: AXUniqueId is the
    /// developer-set, higher-stability identifier, so it dominates
    /// the resource-id namespace on collision. Without this, the
    /// actionable narrowing further down silently picked one of the
    /// two and the agent had no way to tell which identifier won.
    func testIdUniqueIdWinsOverResourceIdOnCollision() throws {
        let entries: [Outline.Entry] = [
            Outline.Entry(
                aliases: .init(at: 1),
                role: "View",
                label: "Outer container",
                frame: .init(x: 0, y: 0, width: 1080, height: 200),
                region: .init(kind: "Content"),
                states: [],
                uniqueId: "shared_id", value: nil,
                resourceId: nil, hint: nil
            ),
            Outline.Entry(
                aliases: .init(at: 2),
                role: "Button",
                label: "Inner button",
                frame: .init(x: 0, y: 200, width: 200, height: 80),
                region: .init(kind: "Content"),
                states: [],
                uniqueId: nil, value: nil,
                resourceId: "shared_id", hint: nil
            ),
        ]
        let match = try AndroidSelectorResolver.resolve(
            selector: AndroidSelector(id: "shared_id"),
            entries: entries
        )
        XCTAssertEqual(match.aliases.at, 1, "uniqueId match must win over a colliding resourceId match")
    }

    /// AND-combine guard: a multi-match `--id` PLUS a label-bearing
    /// flag is allowed to narrow via actionable (the label path
    /// signals the user's "find me the right one" intent).
    func testIdPlusLabelStillNarrows() throws {
        let entries: [Outline.Entry] = [
            Outline.Entry(
                aliases: .init(at: 1),
                role: "View",
                label: "Banner",
                frame: .init(x: 0, y: 0, width: 1080, height: 200),
                region: .init(kind: "Content"),
                states: [],
                uniqueId: nil, value: nil,
                resourceId: "shared", hint: nil
            ),
            Outline.Entry(
                aliases: .init(at: 2),
                role: "Button",
                label: "Banner action",
                frame: .init(x: 0, y: 200, width: 200, height: 100),
                region: .init(kind: "Content"),
                states: [],
                uniqueId: nil, value: nil,
                resourceId: "shared", hint: nil
            ),
        ]
        let match = try AndroidSelectorResolver.resolve(
            selector: AndroidSelector(id: "shared", labelContains: "Banner"),
            entries: entries
        )
        XCTAssertEqual(match.role, "Button")
    }

    // MARK: - frame filter

    /// `--frame minY=…` narrows ambiguous selector hits to the
    /// half of the screen the user actually meant. Mirrors iOS's
    /// `AccessibilityTargetResolver.FrameFilter` semantics — bound
    /// checks compare against the entry's top-left corner so
    /// `minY=500` means "entries that start at or below y=500".
    func testFrameFilterDropsOutOfBandCandidates() throws {
        let topRow = Outline.Entry(
            aliases: .init(at: 1),
            role: "Button",
            label: "Notifications",
            frame: .init(x: 0, y: 100, width: 200, height: 80),
            region: .init(kind: "Top"),
            states: []
        )
        let bottomRow = Outline.Entry(
            aliases: .init(at: 2),
            role: "Button",
            label: "Notifications",
            frame: .init(x: 0, y: 1500, width: 200, height: 80),
            region: .init(kind: "Bottom"),
            states: []
        )
        let selector = AndroidSelector(
            label: "Notifications",
            frame: SelectorFrameFilter(minY: 1000)
        )
        let match = try AndroidSelectorResolver.resolve(
            selector: selector,
            entries: [topRow, bottomRow],
            screen: Outline.Frame(x: 0, y: 0, width: 1080, height: 2400)
        )
        XCTAssertEqual(match.frame.y, 1500, "Only the bottom-row entry should survive minY=1000")
    }

    /// Relative bounds need the screen to resolve. `minY=0.5r` on a
    /// 2400-tall screen should keep entries starting at y >= 1200.
    func testFrameFilterResolvesRelativeAgainstScreen() throws {
        let topRow = Outline.Entry(
            aliases: .init(at: 1),
            role: "Button",
            label: "Save",
            frame: .init(x: 0, y: 1000, width: 200, height: 80),
            region: .init(kind: "Content"),
            states: []
        )
        let bottomRow = Outline.Entry(
            aliases: .init(at: 2),
            role: "Button",
            label: "Save",
            frame: .init(x: 0, y: 1500, width: 200, height: 80),
            region: .init(kind: "Content"),
            states: []
        )
        let selector = AndroidSelector(
            label: "Save",
            frame: try SelectorFrameFilter(specs: ["minY=0.5r"])
        )
        let match = try AndroidSelectorResolver.resolve(
            selector: selector,
            entries: [topRow, bottomRow],
            screen: Outline.Frame(x: 0, y: 0, width: 1080, height: 2400)
        )
        XCTAssertEqual(match.frame.y, 1500)
    }

    /// Empty frame filter must be a no-op — selector matches behave
    /// exactly as if no `frame` field were set. Regression guard so
    /// the new field doesn't accidentally over-filter.
    func testEmptyFrameFilterIsNoOp() throws {
        let entries = makeEntries()
        let selector = AndroidSelector(id: "login_button", frame: SelectorFrameFilter())
        let match = try AndroidSelectorResolver.resolve(
            selector: selector,
            entries: entries,
            screen: Outline.Frame(x: 0, y: 0, width: 1080, height: 2400)
        )
        XCTAssertEqual(match.aliases.at, 1)
    }

    /// Frame filter applied with no matching entry surfaces as the
    /// normal `noMatch` error — same shape as label/id no-matches so
    /// callers don't have to special-case.
    func testFrameFilterNoMatchRaisesNoMatch() {
        let entries: [Outline.Entry] = [
            Outline.Entry(
                aliases: .init(at: 1),
                role: "Button",
                label: "Save",
                frame: .init(x: 0, y: 100, width: 200, height: 80),
                region: .init(kind: "Top"),
                states: []
            ),
        ]
        let selector = AndroidSelector(
            label: "Save",
            frame: SelectorFrameFilter(minY: 1000)
        )
        XCTAssertThrowsError(try AndroidSelectorResolver.resolve(
            selector: selector,
            entries: entries,
            screen: Outline.Frame(x: 0, y: 0, width: 1080, height: 2400)
        )) { error in
            switch error as? AndroidSelectorError {
            case .noMatch:
                break
            default:
                XCTFail("expected .noMatch, got \(error)")
            }
        }
    }

    /// `actionableRoles` defines which roles count as "interactable"
    /// when narrowing an ambiguous selector match. The canonical
    /// vocabulary entry for a checkbox is `Checkbox` (see
    /// `ElementVocabulary.canonicalForAndroidClass`), so the role
    /// name an Android-classified node ever carries is `Checkbox`.
    /// The previous code hedged with both `"CheckBox"` and
    /// `"Checkbox"`, leaving dead string state that drifts when the
    /// canonical name is the source of truth. Pin to the canonical
    /// spelling.
    func testActionableRolesUsesCanonicalCheckbox() {
        XCTAssertTrue(
            AndroidSelectorResolver.actionableRoles.contains("Checkbox"),
            "Canonical role `Checkbox` must remain in actionableRoles"
        )
        XCTAssertFalse(
            AndroidSelectorResolver.actionableRoles.contains("CheckBox"),
            "Legacy iOS-style spelling `CheckBox` should not appear in Android actionableRoles"
        )
    }

    // MARK: - Error message hints

    /// Verifies the ambiguous-error payload surfaces match descriptors
    /// (role + label + id + frame) and that the prose recommends the
    /// available disambiguators. The previous shape was just
    /// `"Selector matched N elements; disambiguate with additional
    /// flags."` — no candidate list, no flag suggestion — which gave
    /// agents nothing actionable to retry with.
    func testAmbiguousErrorCarriesMatchDescriptors() throws {
        let entries: [Outline.Entry] = [
            Outline.Entry(
                aliases: .init(at: 1),
                role: "View",
                label: "Home tab",
                frame: .init(x: 24, y: 2190, width: 168, height: 147),
                region: .init(kind: "Bottom"),
                states: [],
                uniqueId: nil, value: nil,
                resourceId: "bnb_button_clickable_area", hint: nil
            ),
            Outline.Entry(
                aliases: .init(at: 2),
                role: "View",
                label: "Chats tab Selected",
                frame: .init(x: 240, y: 2190, width: 168, height: 147),
                region: .init(kind: "Bottom"),
                states: [],
                uniqueId: nil, value: nil,
                resourceId: "bnb_button_clickable_area", hint: nil
            ),
        ]
        XCTAssertThrowsError(try AndroidSelectorResolver.resolve(
            selector: AndroidSelector(id: "bnb_button_clickable_area"),
            entries: entries
        )) { error in
            guard case let .ambiguous(_, count, matches) = (error as? AndroidSelectorError) else {
                XCTFail("Expected .ambiguous, got \(error)")
                return
            }
            XCTAssertEqual(count, 2)
            XCTAssertEqual(matches.count, 2)
            XCTAssertTrue(matches[0].contains("Home tab"), "Match 0 should carry the label: \(matches[0])")
            XCTAssertTrue(matches[0].contains("#bnb_button_clickable_area"), "Match 0 should carry the id: \(matches[0])")
            XCTAssertTrue(matches[0].contains("@(24,2190)"), "Match 0 should carry the frame: \(matches[0])")
            XCTAssertTrue(matches[1].contains("Chats tab"), "Match 1 should carry the label: \(matches[1])")
            XCTAssertTrue(matches[1].contains("@(240,2190)"), "Match 1 should carry the frame: \(matches[1])")

            let description = error.localizedDescription
            // Prose should echo the failing pattern and recommend at
            // least one of the unused disambiguator flags (we suggest
            // `--id` / `--element-type` / `--frame`; `--label` is
            // omitted because programmatic detection of "do matches
            // have distinct labels?" lives in the agent, not here).
            XCTAssertTrue(description.contains("--id 'bnb_button_clickable_area'"), "Should echo the failing pattern: \(description)")
            XCTAssertTrue(
                description.contains("--element-type") || description.contains("--frame"),
                "Should recommend an unused disambiguator flag: \(description)"
            )

            let hint = (error as? AndroidSelectorError)?.hint ?? ""
            XCTAssertTrue(hint.contains("matches (2)"), "Hint should label and count matches: \(hint)")
            XCTAssertTrue(hint.contains("#bnb_button_clickable_area"), "Hint should embed match details: \(hint)")
        }
    }

    /// `noMatch` against `--id` should surface available ids, not
    /// labels — agents trying to fix a typo on `--id` need to see the
    /// id namespace, not labels they cannot pass to `--id` directly.
    /// Mirror iOS's `notFound(candidateKind: "ids", …)`.
    func testNoMatchForIdSurfacesIdCandidates() {
        let entries: [Outline.Entry] = [
            Outline.Entry(
                aliases: .init(at: 1),
                role: "Button",
                label: "Sign in",
                frame: .init(x: 0, y: 0, width: 100, height: 50),
                region: .init(kind: "Content"),
                states: [],
                uniqueId: nil, value: nil,
                resourceId: "sign_in_btn", hint: nil
            ),
            Outline.Entry(
                aliases: .init(at: 2),
                role: "Button",
                label: "Cancel",
                frame: .init(x: 0, y: 60, width: 100, height: 50),
                region: .init(kind: "Content"),
                states: [],
                uniqueId: nil, value: nil,
                resourceId: "cancel_btn", hint: nil
            ),
        ]
        XCTAssertThrowsError(try AndroidSelectorResolver.resolve(
            selector: AndroidSelector(id: "does_not_exist"),
            entries: entries
        )) { error in
            guard case let .noMatch(_, candidates, candidateKind, suggestedAlternative) = (error as? AndroidSelectorError) else {
                XCTFail("Expected .noMatch, got \(error)")
                return
            }
            XCTAssertEqual(candidateKind, "ids")
            XCTAssertTrue(candidates.contains("sign_in_btn"), "Available ids should appear: \(candidates)")
            XCTAssertTrue(candidates.contains("cancel_btn"), "Available ids should appear: \(candidates)")
            XCTAssertNil(suggestedAlternative, "No label/value match for the failing id, so no cross-attribute suggestion")
        }
    }

    /// `--id 'Sign in'` where 'Sign in' actually exists as a label
    /// should suggest `--label 'Sign in'`. Mirrors iOS's
    /// `notFound(suggestedAlternative: …)` cross-attribute hint.
    func testNoMatchForIdSuggestsLabelWhenValueMatchesLabel() {
        let entries: [Outline.Entry] = [
            Outline.Entry(
                aliases: .init(at: 1),
                role: "Button",
                label: "Sign in",
                frame: .init(x: 0, y: 0, width: 100, height: 50),
                region: .init(kind: "Content"),
                states: [],
                uniqueId: nil, value: nil,
                resourceId: "sign_in_btn", hint: nil
            ),
        ]
        XCTAssertThrowsError(try AndroidSelectorResolver.resolve(
            selector: AndroidSelector(id: "Sign in"),
            entries: entries
        )) { error in
            guard case let .noMatch(_, _, _, suggestedAlternative) = (error as? AndroidSelectorError) else {
                XCTFail("Expected .noMatch, got \(error)")
                return
            }
            XCTAssertNotNil(suggestedAlternative, "Should suggest --label when the failed id matches a label")
            XCTAssertTrue(suggestedAlternative!.contains("--label 'Sign in'"),
                          "Suggestion should name the alternative flag: \(suggestedAlternative ?? "")")
            XCTAssertTrue(error.localizedDescription.contains("--label 'Sign in'"),
                          "Description should include the suggestion verbatim: \(error.localizedDescription)")
        }
    }

    /// `noMatch` on `--label` should surface labels (not ids) so an
    /// agent fixing a typo can find the right label in the same column
    /// they searched.
    func testNoMatchForLabelSurfacesLabelCandidates() {
        let entries: [Outline.Entry] = [
            Outline.Entry(
                aliases: .init(at: 1),
                role: "Button",
                label: "Sign in",
                frame: .init(x: 0, y: 0, width: 100, height: 50),
                region: .init(kind: "Content"),
                states: [],
                uniqueId: nil, value: nil, resourceId: "sign_in_btn", hint: nil
            ),
            Outline.Entry(
                aliases: .init(at: 2),
                role: "Button",
                label: "Cancel",
                frame: .init(x: 0, y: 60, width: 100, height: 50),
                region: .init(kind: "Content"),
                states: [],
                uniqueId: nil, value: nil, resourceId: "cancel_btn", hint: nil
            ),
        ]
        XCTAssertThrowsError(try AndroidSelectorResolver.resolve(
            selector: AndroidSelector(label: "Signin"),
            entries: entries
        )) { error in
            guard case let .noMatch(_, candidates, candidateKind, _) = (error as? AndroidSelectorError) else {
                XCTFail("Expected .noMatch, got \(error)")
                return
            }
            XCTAssertEqual(candidateKind, "labels")
            XCTAssertTrue(candidates.contains("Sign in"))
            XCTAssertTrue(candidates.contains("Cancel"))
        }
    }

    /// Ambiguous errors should not double-list `--id` / `--element-type`
    /// when the selector already constrains by that flag — surfacing the
    /// same flag as a "disambiguator" would be misleading. When every
    /// available knob is already set, the prose pivots to "the
    /// constraint set is already maximal".
    func testAmbiguousErrorOmitsAlreadyUsedDisambiguators() {
        let entries: [Outline.Entry] = [
            Outline.Entry(
                aliases: .init(at: 1),
                role: "Button",
                label: "A",
                frame: .init(x: 0, y: 0, width: 100, height: 50),
                region: .init(kind: "Content"),
                states: [],
                uniqueId: nil, value: nil, resourceId: "dup", hint: nil
            ),
            Outline.Entry(
                aliases: .init(at: 2),
                role: "Button",
                label: "B",
                frame: .init(x: 0, y: 60, width: 100, height: 50),
                region: .init(kind: "Content"),
                states: [],
                uniqueId: nil, value: nil, resourceId: "dup", hint: nil
            ),
        ]
        var frame = SelectorFrameFilter()
        frame.minX = 0
        XCTAssertThrowsError(try AndroidSelectorResolver.resolve(
            selector: AndroidSelector(id: "dup", elementType: "Button", frame: frame),
            entries: entries
        )) { error in
            let description = error.localizedDescription
            // The recommendation phrase ("add --id / --element-type /
            // --frame") must be absent — we already use all of them.
            // The prose still echoes the failing pattern (e.g. `--id
            // 'dup'`) so we narrow the assertion to the recommendation
            // tail.
            XCTAssertFalse(description.contains("add --"),
                           "Should not invite the user to add an already-used disambiguator: \(description)")
            XCTAssertTrue(description.contains("constraint set is already maximal"),
                          "When every knob is set, prose should pivot: \(description)")
        }
    }
}