// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import SimUseCore

final class JSONValueRoundTripTests: XCTestCase {

    func testRoundTripPrimitives() throws {
        let original: [JSONValue] = [
            .null,
            .bool(true),
            .integer(42),
            .double(3.14),
            .string("hello"),
        ]
        let data = try JSONEncoder().encode(JSONValue.array(original))
        let decoded = try JSONValue.decode(from: data)
        if case .array(let arr) = decoded {
            XCTAssertEqual(arr[0], .null)
            XCTAssertEqual(arr[1], .bool(true))
            XCTAssertEqual(arr[2], .integer(42))
            // 3.14 may round-trip as 3.14 (double)
            if case .double(let d) = arr[3] {
                XCTAssertEqual(d, 3.14, accuracy: 0.0001)
            } else {
                XCTFail("Expected double, got \(arr[3])")
            }
            XCTAssertEqual(arr[4], .string("hello"))
        } else {
            XCTFail("Expected array")
        }
    }

    func testRoundTripNestedObject() throws {
        let value: JSONValue = .object([
            "a": .integer(1),
            "b": .array([.string("x"), .string("y")]),
            "c": .object(["nested": .bool(false)]),
        ])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONValue.decode(from: data)
        XCTAssertEqual(decoded, value)
    }

    func testFoundationObjectBridge() {
        let value: JSONValue = .object([
            "name": .string("sim-use"),
            "version": .integer(1),
            "flag": .bool(true),
            "items": .array([.integer(1), .integer(2)]),
        ])
        let bridged = value.foundationObject as? [String: Any]
        XCTAssertEqual(bridged?["name"] as? String, "sim-use")
        XCTAssertEqual(bridged?["version"] as? Int, 1)
        XCTAssertEqual(bridged?["flag"] as? Bool, true)
        XCTAssertEqual((bridged?["items"] as? [Int])?.count, 2)
    }

    func testNullEncodesAsJSONNull() throws {
        let value: JSONValue = .object(["k": .null])
        let data = try JSONEncoder().encode(value)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("\"k\":null"))
    }
}