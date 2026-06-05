// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore

public enum BatchStepKind: String {
    case tap
    case swipe
    case gesture
    case touch
    case type
    case paste
    case button
    case key
    case keySequence = "key-sequence"
    case keyCombo = "key-combo"
    case sleep
}

@MainActor
public struct BatchStepParser {
    public static func parseStepTokens(
        _ tokens: [String],
        globalUDID: String,
        context: BatchContext,
        logger: SimUseLogger
    ) async throws -> [BatchPrimitive] {
        guard let firstToken = tokens.first else {
            return []
        }

        guard let kind = BatchStepKind(rawValue: firstToken) else {
            throw ValidationError("Unsupported batch step '\(firstToken)'.")
        }

        if kind == .sleep {
            return try parseSleep(tokens)
        }

        let stepArguments = Array(tokens.dropFirst())
        try ensureNoPerStepUDID(stepArguments)
        let arguments = stepArguments + ["--udid", globalUDID]

        // Parse each step directly into its IOSSim<Verb>Command. The
        // batch subsystem lives entirely in iOSSimBackend, so SimUse
        // top-level types aren't reachable from here anyway.
        switch kind {
        case .tap:
            return try await parseCommand(IOSSimTapCommand.self, arguments: arguments, context: context, logger: logger)
        case .swipe:
            return try await parseCommand(IOSSimSwipeCommand.self, arguments: arguments, context: context, logger: logger)
        case .gesture:
            return try await parseCommand(IOSSimGestureCommand.self, arguments: arguments, context: context, logger: logger)
        case .touch:
            return try await parseCommand(IOSSimTouchCommand.self, arguments: arguments, context: context, logger: logger)
        case .type:
            return try await parseCommand(IOSSimTypeCommand.self, arguments: arguments, context: context, logger: logger)
        case .paste:
            return try await parseCommand(IOSSimPasteCommand.self, arguments: arguments, context: context, logger: logger)
        case .button:
            return try await parseCommand(IOSSimButtonCommand.self, arguments: arguments, context: context, logger: logger)
        case .key:
            return try await parseCommand(IOSSimKeyCommand.self, arguments: arguments, context: context, logger: logger)
        case .keySequence:
            return try await parseCommand(IOSSimKeySequenceCommand.self, arguments: arguments, context: context, logger: logger)
        case .keyCombo:
            return try await parseCommand(IOSSimKeyComboCommand.self, arguments: arguments, context: context, logger: logger)
        case .sleep:
            return []
        }
    }

    private static func parseCommand<C: AsyncParsableCommand & BatchConvertible>(
        _ type: C.Type,
        arguments: [String],
        context: BatchContext,
        logger: SimUseLogger
    ) async throws -> [BatchPrimitive] {
        guard var parsed = try C.parseAsRoot(arguments) as? C else {
            throw CLIError(errorDescription: "Failed to parse batch step arguments: \(arguments.joined(separator: " "))")
        }
        try parsed.validate()
        return try await parsed.toBatchPrimitives(context: context, logger: logger)
    }

    private static func ensureNoPerStepUDID(_ args: [String]) throws {
        if args.contains(where: { $0 == "--udid" || $0.hasPrefix("--udid=") }) {
            throw ValidationError("Per-step --udid is not supported in batch steps. Use batch-level --udid.")
        }
    }

    private static func parseSleep(_ tokens: [String]) throws -> [BatchPrimitive] {
        guard tokens.count == 2 else {
            throw ValidationError("Sleep step format: sleep <seconds>")
        }
        guard let seconds = Double(tokens[1]), seconds >= 0 else {
            throw ValidationError("Sleep step requires a non-negative number of seconds.")
        }
        return [.hostSleep(seconds)]
    }
}