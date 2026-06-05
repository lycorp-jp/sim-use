// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AndroidBackend
import SimUseCore

final class ElementNodeDecodingTests: XCTestCase {

    func testDecodesFullSchema() throws {
        let json = """
        {
          "resourceId": "com.example.app:id/chats_tab",
          "uniqueId": "chats_tab",
          "package": "com.example.app",
          "className": "androidx.appcompat.widget.AppCompatButton",
          "text": "Chats",
          "contentDescription": "Chats",
          "hintText": null,
          "stateDescription": null,
          "boundsInScreen": {"left": 0, "top": 100, "right": 200, "bottom": 200},
          "clickable": true,
          "longClickable": false,
          "scrollable": false,
          "focusable": true,
          "focused": false,
          "enabled": true,
          "checkable": false,
          "checked": false,
          "selected": true,
          "password": false,
          "collectionInfo": null,
          "collectionItemInfo": null,
          "children": []
        }
        """.data(using: .utf8)!

        let node = try JSONDecoder().decode(ElementNode.self, from: json)
        XCTAssertEqual(node.resourceId, "com.example.app:id/chats_tab")
        XCTAssertEqual(node.resourceIdShortName, "chats_tab")
        XCTAssertEqual(node.uniqueId, "chats_tab")
        XCTAssertEqual(node.text, "Chats")
        XCTAssertTrue(node.clickable)
        XCTAssertTrue(node.selected)
        XCTAssertEqual(node.boundsInScreen.width, 200)
        XCTAssertEqual(node.boundsInScreen.height, 100)
        XCTAssertEqual(node.boundsInScreen.toFrame(), Outline.Frame(x: 0, y: 100, width: 200, height: 100))
    }

    func testDecodesEnvelopeWithInlineResult() throws {
        let json = """
        {
          "status": "success",
          "result": {
            "resourceId": "",
            "package": "android",
            "className": "android.widget.FrameLayout",
            "text": "",
            "contentDescription": "",
            "boundsInScreen": {"left": 0, "top": 0, "right": 1080, "bottom": 1920},
            "clickable": false,
            "longClickable": false,
            "scrollable": false,
            "focusable": false,
            "focused": false,
            "enabled": true,
            "checkable": false,
            "checked": false,
            "selected": false,
            "password": false,
            "children": []
          }
        }
        """.data(using: .utf8)!
        let envelope = try JSONDecoder().decode(BridgeEnvelope<ElementNode>.self, from: json)
        XCTAssertEqual(envelope.status, "success")
        XCTAssertEqual(envelope.result?.boundsInScreen.width, 1080)
        XCTAssertEqual(envelope.result?.boundsInScreen.height, 1920)
    }

    func testDecodesErrorEnvelope() throws {
        let json = """
        {"status": "error", "code": "no_active_window", "error": "Screen mid-transition"}
        """.data(using: .utf8)!
        let envelope = try JSONDecoder().decode(BridgeEnvelope<ElementNode>.self, from: json)
        XCTAssertFalse(envelope.isSuccess)
        XCTAssertEqual(envelope.code, "no_active_window")
        XCTAssertEqual(envelope.error, "Screen mid-transition")
    }

    /// Forward-compat: older bridge builds (pre-this-wire-bump) may
    /// omit individual interaction-flag fields entirely if the
    /// underlying `AccessibilityNodeInfo` couldn't supply them.
    /// Decoding must default missing booleans to a sensible value
    /// rather than fail the whole tree parse — losing a node here
    /// cascades into a degraded outline and broken `@N` aliasing.
    ///
    /// Defaults match Android's own semantics: a node is "enabled"
    /// unless the platform explicitly says otherwise; every other
    /// state flag is false-by-default.
    func testDecodesWhenInteractionFlagsAbsent() throws {
        // No `clickable`, `longClickable`, `scrollable`, `focusable`,
        // `focused`, `checkable`, `checked`, `selected`, `password`,
        // or `enabled` in the payload — the oldest bridge shape we
        // ever shipped.
        let json = """
        {
          "resourceId": "",
          "package": "android",
          "className": "android.view.View",
          "text": "",
          "contentDescription": "",
          "boundsInScreen": {"left": 0, "top": 0, "right": 100, "bottom": 100},
          "children": []
        }
        """.data(using: .utf8)!
        let node = try JSONDecoder().decode(ElementNode.self, from: json)
        // `enabled` defaults true (Android's own default for a fresh
        // View) so a missing flag doesn't make every element look
        // disabled.
        XCTAssertTrue(node.enabled)
        // Every other state flag defaults to false.
        XCTAssertFalse(node.clickable)
        XCTAssertFalse(node.longClickable)
        XCTAssertFalse(node.scrollable)
        XCTAssertFalse(node.focusable)
        XCTAssertFalse(node.focused)
        XCTAssertFalse(node.checkable)
        XCTAssertFalse(node.checked)
        XCTAssertFalse(node.selected)
        XCTAssertFalse(node.password)
    }
}