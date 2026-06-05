// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
import Foundation
import Testing

// MARK: - Fixtures

private func decode(_ json: String) throws -> AccessibilityElement {
    let data = Data(json.utf8)
    return try JSONDecoder().decode(AccessibilityElement.self, from: data)
}

// MARK: - AXValue flexible decoding

struct AccessibilityElementAXValueTests {
    @Test("decodes AXValue as String")
    func stringValue() throws {
        let element = try decode(#"{"AXValue": "hello"}"#)
        #expect(element.AXValue == "hello")
        #expect(element.normalizedValue == "hello")
    }

    @Test("decodes AXValue as Int and stringifies")
    func intValue() throws {
        let element = try decode(#"{"AXValue": 1}"#)
        #expect(element.AXValue == "1")
        #expect(element.normalizedValue == "1")
    }

    @Test("decodes AXValue as zero Int")
    func zeroIntValue() throws {
        let element = try decode(#"{"AXValue": 0}"#)
        #expect(element.AXValue == "0")
    }

    @Test("decodes AXValue as Double and stringifies")
    func doubleValue() throws {
        let element = try decode(#"{"AXValue": 3.14}"#)
        #expect(element.AXValue == "3.14")
    }

    @Test("decodes AXValue as Bool and stringifies")
    func boolValue() throws {
        let trueElement = try decode(#"{"AXValue": true}"#)
        #expect(trueElement.AXValue == "true")

        let falseElement = try decode(#"{"AXValue": false}"#)
        #expect(falseElement.AXValue == "false")
    }

    @Test("AXValue is nil when explicitly null")
    func nullValue() throws {
        let element = try decode(#"{"AXValue": null}"#)
        #expect(element.AXValue == nil)
    }

    @Test("AXValue is nil when key is missing")
    func missingValue() throws {
        let element = try decode(#"{"AXLabel": "no value here"}"#)
        #expect(element.AXValue == nil)
    }

    @Test("does not accept arrays or objects as AXValue — falls back to nil")
    func unsupportedShape() throws {
        // Historically these shapes were not observed, but we prefer a silent
        // `nil` over crashing the whole tree parse.
        let arrayElement = try decode(#"{"AXValue": [1, 2, 3]}"#)
        #expect(arrayElement.AXValue == nil)

        let objectElement = try decode(#"{"AXValue": {"nested": true}}"#)
        #expect(objectElement.AXValue == nil)
    }
}

// MARK: - Other fields still strict

struct AccessibilityElementStrictnessTests {
    @Test("type field rejects non-string input")
    func typeRequiresString() {
        #expect(throws: DecodingError.self) {
            try decode(#"{"type": 123}"#)
        }
    }

    @Test("frame field rejects malformed shape")
    func frameRequiresObject() {
        #expect(throws: DecodingError.self) {
            try decode(#"{"frame": "not an object"}"#)
        }
    }

    @Test("frame rejects missing numeric fields")
    func frameRequiresAllFields() {
        #expect(throws: DecodingError.self) {
            try decode(#"{"frame": {"x": 0, "y": 0, "width": 100}}"#)
        }
    }
}

// MARK: - End-to-end realistic tab button node

struct AccessibilityElementTabButtonTests {
    @Test("decodes a realistic synthesized MINI tab button JSON")
    func tabButtonDecodes() throws {
        let json = """
        {
          "title": null,
          "AXLabel": "MINI",
          "type": "RadioButton",
          "AXUniqueId": null,
          "subrole": "AXTabButton",
          "enabled": true,
          "AXValue": 0,
          "content_required": false,
          "custom_actions": [],
          "children": [],
          "role": "AXRadioButton",
          "role_description": "tab",
          "frame": {
            "y": 792,
            "x": 324.00000000596049,
            "width": 75.999999994039513,
            "height": 48
          },
          "AXFrame": "{{324.00000000596049, 792}, {75.999999994039513, 48}}",
          "synthesized": true,
          "pid": 30015,
          "help": null
        }
        """
        let element = try JSONDecoder().decode(AccessibilityElement.self, from: Data(json.utf8))

        #expect(element.type == "RadioButton")
        #expect(element.AXLabel == "MINI")
        #expect(element.AXValue == "0")
        #expect(element.AXUniqueId == nil)
        #expect(element.frame?.x == 324.00000000596049)
        #expect(element.frame?.width == 75.999999994039513)
        #expect(element.children?.isEmpty == true)
        #expect(element.isActionable)
        #expect(element.normalizedLabel == "MINI")
    }

    @Test("decodes a tab button tree used by the --label resolver")
    func tabButtonTreeDecodes() throws {
        let json = """
        [
          {
            "type": "Application",
            "AXLabel": "LINE Dev",
            "frame": {"x": 0, "y": 0, "width": 402, "height": 874},
            "children": [
              {
                "type": "RadioButton",
                "AXLabel": "MINI",
                "AXValue": 1,
                "frame": {"x": 324, "y": 792, "width": 76, "height": 48},
                "children": []
              },
              {
                "type": "RadioButton",
                "AXLabel": "Home tab",
                "AXValue": 0,
                "frame": {"x": 2, "y": 792, "width": 76, "height": 48},
                "children": []
              }
            ]
          }
        ]
        """
        let roots = try JSONDecoder().decode([AccessibilityElement].self, from: Data(json.utf8))
        #expect(roots.count == 1)

        let flat = roots.flatMap { $0.flattened() }
        let miniTab = flat.first { $0.AXLabel == "MINI" }
        let homeTab = flat.first { $0.AXLabel == "Home tab" }

        #expect(miniTab?.AXValue == "1")
        #expect(homeTab?.AXValue == "0")
        #expect(miniTab?.isActionable == true)
    }
}