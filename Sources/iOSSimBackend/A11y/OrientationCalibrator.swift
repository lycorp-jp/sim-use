// SPDX-License-Identifier: Apache-2.0
import CompanionUtilities
import FBControlCore
import FBSimulatorControl
import Foundation
import SimUseCore

/// Result of an orientation self-calibration. `hidPoint` is the one entry
/// point AX-derived coordinates must pass through before reaching HID or
/// a point hit-test; explicit user coordinates (`-x/-y`) never do.
public struct OrientationCalibration: Sendable {
    public let orientation: DisplayOrientation
    public let native: NativePortraitSize?
    public let probesUsed: Int
    /// Non-nil when calibration degraded to a guess (see
    /// `OrientationCalibrator` fallback rules); merge into the command's
    /// advisory slot so the caller learns taps may be off.
    public let advisory: CommandAdvisory?

    public var isIdentity: Bool { orientation == .portrait }

    public func hidPoint(x: Double, y: Double) -> (x: Double, y: Double) {
        let p = hidCGPoint(CGPoint(x: x, y: y))
        return (Double(p.x), Double(p.y))
    }

    public func hidCGPoint(_ p: CGPoint) -> CGPoint {
        guard let native, orientation != .portrait else { return p }
        return orientation.uiToFramebuffer(p, native: native)
    }

    /// Zero-probe identity result for surfaces that opt out (Android
    /// reshapes, tests) or cannot calibrate at all.
    public static func identity(native: NativePortraitSize? = nil, advisory: CommandAdvisory? = nil) -> OrientationCalibration {
        OrientationCalibration(orientation: .portrait, native: native, probesUsed: 0, advisory: advisory)
    }

    /// Wraps a hit-test probe so UI-space probe points cross into the
    /// framebuffer space the hit-test consumes; identity returns the
    /// probe unchanged (the exact pre-fix closure).
    public func wrappedProbe(
        _ probe: @escaping OrientationCalibrator.HitTestProbe
    ) -> OrientationCalibrator.HitTestProbe {
        isIdentity ? probe : { try await probe(self.hidCGPoint($0)) }
    }
}

/// Determines the current interface orientation by probing the AX
/// hit-test, which shares the HID coordinate space (issue #34): probe a
/// framebuffer point derived from a known element under a candidate
/// orientation, and keep the candidates whose mapping puts the probe
/// point inside the returned element's UI frame.
///
/// No public or private simulator API exposes a queryable orientation,
/// and the AX-reported screen size alone cannot separate 0° from 180°
/// nor the two landscapes — so the calibrator measures the mapping
/// directly. Portrait (the overwhelmingly common case) confirms in a
/// single probe. Results are only valid for the current command
/// execution; orientation can change at any time, so never cache across
/// commands.
@MainActor
public enum OrientationCalibrator {
    public typealias HitTestProbe = CollapsedChildrenRecovery.PointProbe

    public nonisolated static let defaultMaxProbes = 3
    /// Discriminators larger than this share of the screen are skipped:
    /// their frames would contain several candidates' projections and
    /// prove nothing.
    public nonisolated static let maxDiscriminatorAreaRatio = 0.4
    /// Containment slack for probe results, mirroring the quadtree's
    /// tolerance for AX frame rounding.
    public nonisolated static let containmentSlack = 2.0

    public static func calibrate(
        native: NativePortraitSize?,
        uiScreenSize: (width: Double, height: Double)?,
        hint: (width: Double, height: Double)? = nil,
        discriminators: [CGRect],
        probe: HitTestProbe,
        maxProbes: Int = defaultMaxProbes,
        logger: SimUseLogger
    ) async -> OrientationCalibration {
        guard let native else {
            return .identity(advisory: CommandAdvisory(
                kind: .orientationCalibrationFallback,
                message: "Simulator screen info unavailable; assuming portrait orientation. Coordinates may be wrong if the device is rotated."
            ))
        }

        var candidates = orderedCandidates(native: native, uiScreenSize: uiScreenSize, hint: hint)
        if candidates.count == 1, let only = candidates.first {
            return OrientationCalibration(orientation: only, native: native, probesUsed: 0, advisory: nil)
        }
        // Nil-probe demotion below reorders `candidates` to diversify the
        // next probe, but that is weak evidence — the ambiguity fallback
        // should guess by the original prior, not by whoever happened to
        // be demoted last.
        let priorOrder = candidates

        let screenArea = native.width * native.height
        var probesUsed = 0

        for rect in discriminators {
            if candidates.count <= 1 || probesUsed >= maxProbes { break }
            guard rect.width > 0, rect.height > 0,
                  rect.width * rect.height <= maxDiscriminatorAreaRatio * screenArea,
                  let lead = candidates.first
            else { continue }

            let center = CGPoint(x: rect.midX, y: rect.midY)
            let framebufferPoint = lead.uiToFramebuffer(center, native: native)
            let projections = candidates.map { $0.framebufferToUI(framebufferPoint, native: native) }

            // A probe can only discriminate when at least two candidates
            // project this framebuffer point to places farther apart than
            // the element itself — near-center rects project (almost) onto
            // themselves under every mapping.
            let minSeparation = max(rect.width, rect.height)
            guard hasSeparatedPair(projections, minSeparation: minSeparation) else { continue }

            probesUsed += 1
            guard let hit = try? await probe(framebufferPoint),
                  let hitFrame = frameRect(of: hit)
            else {
                // Under the true orientation this point should have hit the
                // discriminator element itself — a miss is soft evidence
                // against the leading candidate.
                candidates.append(candidates.removeFirst())
                continue
            }

            let expanded = hitFrame.insetBy(dx: -containmentSlack, dy: -containmentSlack)
            let retained = candidates.filter { candidate in
                expanded.contains(candidate.framebufferToUI(framebufferPoint, native: native))
            }
            // Empty: inconsistent hit; full: a frame fat enough to cover
            // every projection (wrapper view). Neither narrows anything —
            // rotate the lead so the next probe tests a different
            // assumption instead of re-landing on the same wrapper.
            guard !retained.isEmpty, retained.count < candidates.count else {
                candidates.append(candidates.removeFirst())
                continue
            }
            candidates = retained
        }

        if candidates.count == 1, let winner = candidates.first {
            logger.debug().log("OrientationCalibrator: \(winner.rawValue) confirmed in \(probesUsed) probe(s)")
            return OrientationCalibration(orientation: winner, native: native, probesUsed: probesUsed, advisory: nil)
        }

        // Ambiguous. Guess the highest-prior surviving candidate rather
        // than hard-coding portrait: when the AX dims are swapped,
        // portrait is certainly wrong while either landscape has even
        // odds.
        let guess = priorOrder.first(where: candidates.contains) ?? .portrait
        logger.info().log(
            "OrientationCalibrator: ambiguous after \(probesUsed) probe(s); guessing \(guess.rawValue) among \(candidates.map(\.rawValue).joined(separator: ","))"
        )
        return OrientationCalibration(
            orientation: guess,
            native: native,
            probesUsed: probesUsed,
            advisory: CommandAdvisory(
                kind: .orientationCalibrationFallback,
                message: "Screen orientation could not be confirmed (\(probesUsed) probe(s)); assuming \(guess.rawValue). If the screen changed or the device rotated, re-run describe-ui, or pass explicit -x/-y coordinates."
            )
        )
    }

    /// Convenience for callers that already hold a decoded tree: derives
    /// the UI screen size and discriminators from `roots` and probes via
    /// a fresh `AXProbeSession`.
    public static func calibrate(
        udid: String,
        roots: [AccessibilityElement],
        logger: SimUseLogger,
        maxProbes: Int = defaultMaxProbes
    ) async -> OrientationCalibration {
        guard let session = try? await AXProbeSession.make(udid: udid, logger: logger) else {
            return .identity(advisory: CommandAdvisory(
                kind: .orientationCalibrationFallback,
                message: "Simulator unreachable for orientation calibration; assuming portrait orientation."
            ))
        }
        let display = AXDisplayFrame.frame(in: roots)
        return await calibrate(
            native: session.native,
            uiScreenSize: display.map { (width: $0.width, height: $0.height) },
            discriminators: discriminatorRects(from: roots, display: display),
            probe: session.probe,
            maxProbes: maxProbes,
            logger: logger
        )
    }

    /// Convenience for the tap-alias path, which resolves against the
    /// `describe-ui` snapshot without fetching a tree. The matched entry
    /// is the primary discriminator — in the portrait common case the
    /// single confirming probe lands on the very element about to be
    /// tapped. The snapshot screen size is only a hint: orientation may
    /// have changed since the snapshot was captured.
    public static func calibrate(
        udid: String,
        snapshotEntry entry: OutlineCache.Payload.Entry,
        payload: OutlineCache.Payload,
        logger: SimUseLogger,
        maxProbes: Int = defaultMaxProbes
    ) async -> OrientationCalibration {
        guard let session = try? await AXProbeSession.make(udid: udid, logger: logger) else {
            return .identity(advisory: CommandAdvisory(
                kind: .orientationCalibrationFallback,
                message: "Simulator unreachable for orientation calibration; assuming portrait orientation."
            ))
        }
        func rect(_ e: OutlineCache.Payload.Entry) -> CGRect {
            CGRect(
                x: Double(e.x) - Double(e.w) / 2,
                y: Double(e.y) - Double(e.h) / 2,
                width: Double(e.w),
                height: Double(e.h)
            )
        }
        return await calibrate(
            native: session.native,
            uiScreenSize: nil,
            hint: (width: Double(payload.screen.width), height: Double(payload.screen.height)),
            discriminators: [rect(entry)] + payload.entries.filter { $0 != entry }.map(rect),
            probe: session.probe,
            maxProbes: maxProbes,
            logger: logger
        )
    }

    // MARK: - Candidate ordering

    private static func orderedCandidates(
        native: NativePortraitSize,
        uiScreenSize: (width: Double, height: Double)?,
        hint: (width: Double, height: Double)?
    ) -> [DisplayOrientation] {
        if let size = uiScreenSize {
            if matches(size, width: native.width, height: native.height) {
                return [.portrait, .portraitUpsideDown]
            }
            if matches(size, width: native.height, height: native.width) {
                return [.landscapeRight, .landscapeLeft]
            }
        }
        let all: [DisplayOrientation] = [.portrait, .portraitUpsideDown, .landscapeRight, .landscapeLeft]
        guard let hint else { return all }
        // The hint (e.g. snapshot dims) is stale by definition — use it
        // only to probe the consistent candidates first.
        let preferred = all.filter { orientation in
            let size = orientation.uiSize(native: native)
            return matches(hint, width: size.width, height: size.height)
        }
        return preferred + all.filter { !preferred.contains($0) }
    }

    private static func matches(_ size: (width: Double, height: Double), width: Double, height: Double) -> Bool {
        abs(size.width - width) <= 1 && abs(size.height - height) <= 1
    }

    // MARK: - Discriminator selection

    /// Small, off-center element frames make the best discriminators.
    /// Order by distance from the screen center (descending) so the most
    /// asymmetric elements are probed first, and cap the pool — trees can
    /// hold thousands of elements while calibration needs a handful.
    static func discriminatorRects(
        from roots: [AccessibilityElement],
        display: AccessibilityElement.Frame?,
        limit: Int = 40
    ) -> [CGRect] {
        let centerX = display.map { $0.x + $0.width / 2 }
        let centerY = display.map { $0.y + $0.height / 2 }
        let rects = roots
            .flatMap { $0.flattened() }
            .compactMap { element -> CGRect? in
                guard element.type != "Application",
                      let frame = element.frame, frame.width > 0, frame.height > 0
                else { return nil }
                return CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
            }
        guard let centerX, let centerY else { return Array(rects.prefix(limit)) }
        return rects
            .sorted {
                distanceSquared($0, x: centerX, y: centerY) > distanceSquared($1, x: centerX, y: centerY)
            }
            .prefix(limit)
            .map { $0 }
    }

    private static func distanceSquared(_ rect: CGRect, x: Double, y: Double) -> Double {
        let dx = rect.midX - x
        let dy = rect.midY - y
        return dx * dx + dy * dy
    }

    private static func hasSeparatedPair(_ points: [CGPoint], minSeparation: Double) -> Bool {
        for i in points.indices {
            for j in points.indices where j > i {
                let dx = points[i].x - points[j].x
                let dy = points[i].y - points[j].y
                if (dx * dx + dy * dy).squareRoot() > minSeparation { return true }
            }
        }
        return false
    }

    /// The single orientation under which `framebufferPoint` projects
    /// into `hitFrame` (± `containmentSlack`), or nil when zero or
    /// several orientations do. An ambiguous hit must not pick a winner:
    /// the `--point` fast path used to give portrait the tie, so on a
    /// rotated device a raw hit landing on a large frame confidently
    /// returned the wrong element as `orientation: portrait` with no
    /// advisory.
    nonisolated static func soleOrientation(
        mapping framebufferPoint: CGPoint,
        into hitFrame: CGRect,
        native: NativePortraitSize
    ) -> DisplayOrientation? {
        let expanded = hitFrame.insetBy(dx: -containmentSlack, dy: -containmentSlack)
        let contained = DisplayOrientation.allCases.filter {
            expanded.contains($0.framebufferToUI(framebufferPoint, native: native))
        }
        return contained.count == 1 ? contained.first : nil
    }

    static func frameRect(of node: [String: Any]) -> CGRect? {
        guard let f = node["frame"] as? [String: Any] else { return nil }
        func number(_ v: Any?) -> Double? {
            if let d = v as? Double { return d }
            if let n = v as? NSNumber { return n.doubleValue }
            return nil
        }
        guard let x = number(f["x"]), let y = number(f["y"]),
              let width = number(f["width"]), let height = number(f["height"]),
              width > 0, height > 0
        else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// One-time simulator lookup yielding the hit-test probe and native
/// screen size — the two inputs calibration needs. Factored so verbs
/// that never fetch a tree (the tap-alias path) can calibrate without
/// paying for one.
@MainActor
public struct AXProbeSession {
    public let probe: OrientationCalibrator.HitTestProbe
    public let native: NativePortraitSize?

    public static func make(udid: String, logger: SimUseLogger) async throws -> AXProbeSession {
        let simulatorSet = try await getSimulatorSet(
            deviceSetPath: nil,
            logger: logger,
            reporter: EmptyEventReporter.shared
        )
        guard let target = simulatorSet.allSimulators.first(where: { $0.udid == udid }) else {
            throw CLIError(errorDescription: "Simulator with UDID \(udid) not found in set.")
        }
        let probe: OrientationCalibrator.HitTestProbe = { point in
            let raw: AnyObject = try await target.legacyAccessibilityElement(at: point, nestedFormat: false)
            return raw as? [String: Any]
        }
        return AXProbeSession(probe: probe, native: NativePortraitSize(screenInfo: target.screenInfo))
    }
}
