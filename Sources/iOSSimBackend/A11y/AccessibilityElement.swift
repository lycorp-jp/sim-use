// SPDX-License-Identifier: Apache-2.0
import Foundation

public struct AccessibilityElement: Decodable {
    private static let actionableTypes: Set<String> = [
        "Button",
        "Cell",
        "CheckBox",
        "Link",
        "MenuItem",
        "PopUpButton",
        "RadioButton",
        "SecureTextField",
        "SegmentedControl",
        "Switch",
        "Tab",
        "TabBarButton",
        "TextField",
    ]
    public struct Frame: Decodable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double
    }

    public let type: String?
    public let frame: Frame?
    public let children: [AccessibilityElement]?
    public let enabled: Bool?
    /// Process identifier emitted by the AX serializer on every element.
    /// On the Application root this is the foreground app's pid; the
    /// `BundleIdentifierResolver` maps it back to `CFBundleIdentifier`.
    public let pid: Int?

    public let AXLabel: String?
    public let AXUniqueId: String?
    // `AXValue` is stringly-typed in the legacy JSON shape, but the accessibility
    // tree occasionally reports it as a number or bool — e.g. UITabBar tab buttons
    // emit `AXValue: 0` / `AXValue: 1` for their selected state. A strict
    // `String?` decode would throw and abort the whole tree parse, breaking
    // downstream callers like the `--label` tap resolver even though they never
    // read `AXValue`. We stringify the scalar so both `--label` (which ignores
    // the field) and `--value` (which matches against it) keep working.
    public let AXValue: String?

    public enum CodingKeys: String, CodingKey {
        case type
        case frame
        case children
        case enabled
        case pid
        case AXLabel
        case AXUniqueId
        case AXValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        frame = try container.decodeIfPresent(Frame.self, forKey: .frame)
        children = try container.decodeIfPresent([AccessibilityElement].self, forKey: .children)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
        pid = try container.decodeIfPresent(Int.self, forKey: .pid)
        AXLabel = try container.decodeIfPresent(String.self, forKey: .AXLabel)
        AXUniqueId = try container.decodeIfPresent(String.self, forKey: .AXUniqueId)
        AXValue = Self.decodeFlexibleString(from: container, forKey: .AXValue)
    }

    /// Decodes a value that may be encoded as String, Int, Double, Bool, or null.
    /// Non-string scalars are stringified so the rest of the pipeline keeps a
    /// uniform `String?` shape.
    private static func decodeFlexibleString(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> String? {
        guard container.contains(key) else { return nil }
        if (try? container.decodeNil(forKey: key)) == true { return nil }
        if let value = try? container.decode(String.self, forKey: key) { return value }
        if let value = try? container.decode(Int.self, forKey: key) { return String(value) }
        if let value = try? container.decode(Double.self, forKey: key) { return String(value) }
        if let value = try? container.decode(Bool.self, forKey: key) { return String(value) }
        return nil
    }

    public var normalizedLabel: String? {
        AXLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// AXLabel with every internal run of whitespace (spaces, tabs, newlines)
    /// collapsed to a single space and the ends trimmed. The compact
    /// `describe-ui` outline renders a multi-line AXLabel space-joined, so an
    /// agent that copies a label out of the outline and passes it back to
    /// `--label` supplies a space-joined string that never equals the
    /// newline-bearing AXLabel under exact comparison. Matching on the
    /// collapsed form lets that round-trip succeed.
    public var collapsedLabel: String? {
        AccessibilityElement.collapseWhitespace(AXLabel)
    }

    /// `collapsedLabel` counterpart for AXValue, used by the `--value`
    /// whitespace-tolerant fallback.
    public var collapsedValue: String? {
        AccessibilityElement.collapseWhitespace(AXValue)
    }

    /// Collapse internal whitespace runs to single spaces and trim. Returns
    /// nil for a nil input; an all-whitespace string collapses to "".
    public static func collapseWhitespace(_ string: String?) -> String? {
        guard let string else { return nil }
        return string.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    public var normalizedUniqueId: String? {
        AXUniqueId?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var normalizedValue: String? {
        AXValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isActionable: Bool {
        guard let type else {
            return false
        }
        return Self.actionableTypes.contains(type)
    }

    public func flattened() -> [AccessibilityElement] {
        var result: [AccessibilityElement] = [self]
        if let children {
            result.append(contentsOf: children.flatMap { $0.flattened() })
        }
        return result
    }
}