// SPDX-License-Identifier: Apache-2.0
import Foundation
import FBSimulatorControl
import SimUseCore

/// Legacy-shaped wrappers over the typed `FBAccessibilityElement` API.
///
/// Upstream idb replaced the dictionary-returning accessibility calls with an
/// opaque element handle plus an explicit serialize step. The serializer's
/// output shapes are unchanged (frontmost tree → array of dictionaries, point
/// query → single dictionary — "mirror the old SimulatorBridge implementation
/// for downstream compatibility" per upstream), so the whole downstream
/// pipeline (serialization, collapsed-children recovery, orientation
/// calibration) keeps consuming the same raw structures through these
/// wrappers.
extension FBSimulator {

    /// The frontmost application's accessibility tree, in the same shape the
    /// pre-Swiftification `accessibilityElements(withNestedFormat:)` returned:
    /// an array of dictionaries (a single root for the nested format).
    ///
    /// `includeRemoteContent` opts into upstream's coverage-grid discovery
    /// of elements owned by other processes (grid hit-testing over screen
    /// regions the frontmost tree does not cover). Off by default: on a
    /// healthy full-coverage tree it probes nothing, but on sparse (yet
    /// perfectly valid) trees it burns a grid of hit-test XPCs — callers
    /// enable it only when the plain fetch came back as an empty shell
    /// (issue #64).
    ///
    /// `remoteSamplingRegion` overrides upstream's default sampling region
    /// (the root's UI-space frame). Pass the hit-test canvas's portrait
    /// bounds: the grid points feed the point hit-test, which runs on
    /// native-portrait AXES (issue #34) in the UI point METRIC
    /// (`NativePortraitSize.uiMetric`), so a rotated UI-space region
    /// samples the wrong band, and a pixels/scale region leaves a
    /// downscaled panel's right/bottom edge unsampled.
    func legacyAccessibilityElements(
        nestedFormat: Bool,
        includeRemoteContent: Bool = false,
        remoteSamplingRegion: CGRect? = nil
    ) async throws -> AnyObject {
        let element: FBAccessibilityElement
        do {
            element = try await accessibilityElementForFrontmostApplication()
        } catch {
            throw FrontmostAccessibilityError.mapping(error, udid: udid)
        }
        defer { element.close() }
        let options = LegacyAccessibilityRequestBuilder.options(
            nestedFormat: nestedFormat,
            includeRemoteContent: includeRemoteContent,
            remoteSamplingRegion: remoteSamplingRegion
        )
        let response = try element.serialize(with: options)
        return response.elements as AnyObject
    }

    /// The accessibility element at `point`, in the same single-dictionary
    /// shape the pre-Swiftification `accessibilityElement(at:nestedFormat:)`
    /// returned.
    func legacyAccessibilityElement(at point: CGPoint, nestedFormat: Bool) async throws -> AnyObject {
        let element = try await accessibilityElement(at: point)
        defer { element.close() }
        let response = try element.serialize(with: FBAccessibilityRequestOptions(nestedFormat: nestedFormat))
        return response.elements as AnyObject
    }
}

/// Replaces idb's `noTranslationObject` on the frontmost-tree fetch. idb's
/// text blames an invalid point or a fullscreen dialog, which applies only
/// to point queries. On the frontmost path, with SpringBoard alive (idb
/// re-labels a dead SpringBoard itself), the usual cause is a stale
/// CoreSimulatorBridge: point queries still resolve, the frontmost query
/// returns nil on every screen, and only a bridge restart recovers it.
///
/// The description keeps idb's leading sentence on purpose:
/// `DaemonErrorKind.classify` matches it to retry once after a fresh boot,
/// when the same nil is genuinely transient.
public struct FrontmostAccessibilityError: LocalizedError, HintProviding, Equatable {
    public let udid: String

    public init(udid: String) {
        self.udid = udid
    }

    public var errorDescription: String? {
        "No translation object returned for simulator \(udid) for the frontmost application. " +
            "The simulator's accessibility bridge reported no frontmost application; no screen point was involved."
    }

    public var hint: String? {
        "If the simulator booted only a moment ago, wait a few seconds and retry. " +
            "If the error continues while the simulator responds normally (`screenshot` works, `ui --point` returns elements), " +
            "the simulator's accessibility bridge is stale. Restart it with " +
            "`xcrun simctl spawn \(udid) launchctl stop com.apple.CoreSimulator.bridge` " +
            "(launchd starts it again at once), then retry. " +
            "Other tools that use this simulator lose accessibility for a moment during the restart."
    }

    /// `noTranslationObject` becomes this error; every other error passes through.
    static func mapping(_ error: Error, udid: String) -> Error {
        if case FBAccessibilityError.noTranslationObject = error {
            return FrontmostAccessibilityError(udid: udid)
        }
        return error
    }
}

/// Options assembly for the legacy tree fetch, factored out so the
/// remote-retry request contract stays unit-testable without a
/// simulator.
enum LegacyAccessibilityRequestBuilder {
    static func options(
        nestedFormat: Bool,
        includeRemoteContent: Bool,
        remoteSamplingRegion: CGRect?
    ) -> FBAccessibilityRequestOptions {
        var options = FBAccessibilityRequestOptions(nestedFormat: nestedFormat)
        if includeRemoteContent {
            // Deliberately WITHOUT collectFrameCoverage: the coverage grid
            // is created and filled with UI-space frames while its
            // isFilled gate consumes the discovery grid's
            // portrait-axes sample points — under rotation a
            // discovered element's UI frame would shadow a numerically
            // overlapping but visually unrelated portrait-axes band,
            // skipping later sample points. On the only path that runs
            // discovery (an empty shell) the gate's upside is zero anyway:
            // the grid starts empty, so it can never save a probe — it
            // can only mis-skip one. Duplicate hits are already collapsed
            // by upstream's frame-key dedup, which compares UI-space
            // frames against UI-space frames.
            var remote = FBAccessibilityRemoteContentOptions()
            if let remoteSamplingRegion {
                remote.region = remoteSamplingRegion
            }
            options.remoteContentOptions = remote
        }
        return options
    }
}
