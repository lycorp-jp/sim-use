// SPDX-License-Identifier: Apache-2.0
import Foundation

/// `iOSSimBackend` hosts the iOS Simulator backend for `sim-use`.
///
/// Mirrors `AndroidBackend`. Per-verb commands live in
/// `Sources/iOSSimBackend/Verbs/IOSSim<Verb>Command.swift`; the
/// top-level cross-platform forwarders in `Sources/SimUse/Commands/`
/// dispatch iOS UDIDs through them, and `Sources/iOSSimBackend/Verbs/IOSSimCommand.swift`
/// also exposes the same set under `sim-use ios <verb>`.
///
/// Naming note: `Sim` is in the name because the current iOS surface
/// only covers the Simulator. Real-device support would live in a
/// peer `iOSDeviceBackend` module (likely WebDriverAgent-backed) when
/// that work is taken on.
public enum IOSSimBackend {}