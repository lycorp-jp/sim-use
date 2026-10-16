// SPDX-License-Identifier: Apache-2.0
import CompanionUtilities
import FBControlCore
import FBSimulatorControl
import Foundation
import SimUseCore

/// Result of an orientation self-calibration. AX-derived coordinates
/// must pass through exactly one of two entry points: `hidPoint` before
/// reaching HID dispatch, `probeCGPoint` before reaching a point
/// hit-test — the two spaces share native-portrait AXES but the
/// hit-test keeps the UI point METRIC while HID normalizes against
/// pixels/scale. Explicit user coordinates (`-x/-y`) never pass through
/// either.
public struct OrientationCalibration: Sendable {
    public let orientation: DisplayOrientation
    public let native: NativePortraitSize?
    /// Metric ratio between the UI point space and the native framebuffer
    /// point space; identity except on display-downscaled devices.
    public let uiScale: UIPointScale
    public let probesUsed: Int
    /// Non-nil when calibration degraded to a guess (see
    /// `OrientationCalibrator` fallback rules); merge into the command's
    /// advisory slot so the caller learns taps may be off.
    public let advisory: CommandAdvisory?
    /// Where the app's scene starts inside the display's interface, in UI
    /// points. Zero when the scene fills the display. A scene smaller than
    /// its display sits elsewhere: an iOS 27.0 SDK app on the iPhone Duo
    /// cover keeps out of the status bar strip, which stays on the
    /// hardware's right edge, so in `landscape-right` it starts 80 pt down;
    /// an older SDK app is centred on the inner display (plan E29, E30).
    public let sceneOffset: CGPoint
    /// The scene's UI size when it is smaller than the display; nil when it
    /// fills it.
    public let sceneSize: CGSize?

    public init(
        orientation: DisplayOrientation,
        native: NativePortraitSize?,
        uiScale: UIPointScale = .identity,
        probesUsed: Int,
        advisory: CommandAdvisory?,
        sceneOffset: CGPoint = .zero,
        sceneSize: CGSize? = nil
    ) {
        self.orientation = orientation
        self.native = native
        self.uiScale = uiScale
        self.probesUsed = probesUsed
        self.advisory = advisory
        self.sceneOffset = sceneOffset
        self.sceneSize = sceneSize
    }

    /// The same calibration for a scene at `offset` of size `size`.
    func withScene(offset: CGPoint, size: CGSize?, probesUsed extra: Int = 0, advisory override: CommandAdvisory? = nil) -> OrientationCalibration {
        OrientationCalibration(
            orientation: orientation,
            native: native,
            uiScale: uiScale,
            probesUsed: probesUsed + extra,
            advisory: override ?? advisory,
            sceneOffset: offset,
            sceneSize: size
        )
    }

    public var isIdentity: Bool { orientation == .portrait && uiScale.isIdentity && sceneOffset == .zero }

    private func intoDisplay(_ p: CGPoint) -> CGPoint {
        sceneOffset == .zero ? p : CGPoint(x: p.x + sceneOffset.x, y: p.y + sceneOffset.y)
    }

    public func hidPoint(x: Double, y: Double) -> (x: Double, y: Double) {
        let p = hidCGPoint(CGPoint(x: x, y: y))
        return (Double(p.x), Double(p.y))
    }

    public func hidCGPoint(_ p: CGPoint) -> CGPoint {
        guard let native, !isIdentity else { return p }
        return orientation.uiToFramebuffer(intoDisplay(p), native: native, uiScale: uiScale)
    }

    /// UI point → AX point-hit-test coordinate. The hit-test shares
    /// HID's native-portrait AXES but consumes points in the UI point
    /// METRIC (see ``NativePortraitSize/uiMetric(_:)``), so this rotates
    /// on the UI-sized canvas and never applies the HID metric scale.
    /// Portrait is always the identity — even on display-downscaled
    /// devices — which is what keeps the single-probe fast paths valid
    /// there.
    public func probeCGPoint(_ p: CGPoint) -> CGPoint {
        guard let native else { return p }
        guard orientation != .portrait || sceneOffset != .zero else { return p }
        return orientation.uiToFramebuffer(intoDisplay(p), native: native.uiMetric(uiScale))
    }

    /// The UI-space size of the app's canvas: the scene when it is smaller
    /// than the display, else the display's interface for the calibrated
    /// orientation.
    public func uiScreenSize() -> (width: Double, height: Double)? {
        if let sceneSize { return (width: Double(sceneSize.width), height: Double(sceneSize.height)) }
        return native.map { orientation.uiSize(native: $0, uiScale: uiScale) }
    }

    /// Zero-probe identity result for surfaces that opt out (Android
    /// reshapes, tests) or cannot calibrate at all.
    public static func identity(
        native: NativePortraitSize? = nil,
        uiScale: UIPointScale = .identity,
        advisory: CommandAdvisory? = nil
    ) -> OrientationCalibration {
        OrientationCalibration(
            orientation: .portrait,
            native: native,
            uiScale: uiScale,
            probesUsed: 0,
            advisory: advisory
        )
    }

    /// Wraps a hit-test probe so UI-space probe points cross onto the
    /// hit-test's native-portrait axes; portrait returns the probe
    /// unchanged (the exact pre-fix closure) — the probe transform is
    /// the identity there regardless of the HID metric scale.
    public func wrappedProbe(
        _ probe: @escaping OrientationCalibrator.HitTestProbe
    ) -> OrientationCalibrator.HitTestProbe {
        orientation == .portrait && sceneOffset == .zero ? probe : { try await probe(self.probeCGPoint($0)) }
    }
}

/// Determines the current interface orientation by probing the AX
/// hit-test, which shares the HID coordinate AXES (issue #34; the metric
/// stays UI — see `probeCGPoint`): probe a portrait-axes point derived
/// from a known element under a candidate orientation, and keep the
/// candidates whose mapping puts the probe point inside the returned
/// element's UI frame.
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
        logger: SimUseLogger,
        authoritative: AuthoritativeOrientation? = nil
    ) async -> OrientationCalibration {
        guard let native else {
            return .identity(advisory: CommandAdvisory(
                kind: .orientationCalibrationFallback,
                message: "Simulator screen info unavailable; assuming portrait orientation. Coordinates may be wrong if the device is rotated."
            ))
        }

        let uiScale = uiPointScale(native: native, uiScreenSize: uiScreenSize ?? hint)
        var candidates = orderedCandidates(
            native: native,
            uiScale: uiScale,
            uiScreenSize: uiScreenSize,
            hint: hint
        )
        // A scene smaller than the display (it keeps out of a status bar
        // strip, or an older SDK app is centred) breaks the probes, which
        // assume the scene starts at the display origin. CoreDevice knows
        // the rotation; the scene's place is then found by
        // `resolveSceneOffset`.
        let scene = (uiScreenSize ?? hint).map { CGSize(width: $0.width, height: $0.height) }
        let insetScene = scene.map { isInsetScene($0, native: native, uiScale: uiScale) } ?? false
        func placed(_ base: OrientationCalibration) async -> OrientationCalibration {
            guard insetScene else { return base }
            return await resolveSceneOffset(base, sceneSize: scene, discriminators: discriminators, probe: probe, logger: logger)
        }
        if insetScene, let authoritative, let reported = await authoritative() {
            logger.info().log("OrientationCalibrator: scene \(scene.map { "\(Int($0.width))x\(Int($0.height))" } ?? "?") is smaller than the display; CoreDevice reports \(reported.rawValue)")
            return await placed(OrientationCalibration(orientation: reported, native: native, uiScale: uiScale, probesUsed: 0, advisory: nil))
        }
        if candidates.count == 1, let only = candidates.first {
            return OrientationCalibration(
                orientation: only,
                native: native,
                uiScale: uiScale,
                probesUsed: 0,
                advisory: nil
            )
        }
        // Nil-probe demotion below reorders `candidates` to diversify the
        // next probe, but that is weak evidence — the ambiguity fallback
        // should guess by the original prior, not by whoever happened to
        // be demoted last.
        let priorOrder = candidates

        // Probes ride the hit-test, whose axes are native-portrait but
        // whose METRIC is the UI point space — so every probe transform
        // runs on the UI-sized canvas without the HID scale (see
        // `OrientationCalibration.probeCGPoint`). Discriminator rects are
        // UI-space, hence the area gate uses the same canvas.
        let probeCanvas = native.uiMetric(uiScale)
        let screenArea = probeCanvas.width * probeCanvas.height
        var probesUsed = 0

        for rect in discriminators {
            if candidates.count <= 1 || probesUsed >= maxProbes { break }
            guard rect.width > 0, rect.height > 0,
                  rect.width * rect.height <= maxDiscriminatorAreaRatio * screenArea,
                  let lead = candidates.first
            else { continue }

            let center = CGPoint(x: rect.midX, y: rect.midY)
            let probePoint = lead.uiToFramebuffer(center, native: probeCanvas)
            let projections = candidates.map {
                $0.framebufferToUI(probePoint, native: probeCanvas)
            }

            // A probe can only discriminate when at least two candidates
            // project this framebuffer point to places farther apart than
            // the element itself — near-center rects project (almost) onto
            // themselves under every mapping.
            let minSeparation = max(rect.width, rect.height)
            guard hasSeparatedPair(projections, minSeparation: minSeparation) else { continue }

            probesUsed += 1
            guard let hit = try? await probe(probePoint),
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
                expanded.contains(
                    candidate.framebufferToUI(probePoint, native: probeCanvas)
                )
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
            return await placed(OrientationCalibration(
                orientation: winner,
                native: native,
                uiScale: uiScale,
                probesUsed: probesUsed,
                advisory: nil
            ))
        }

        // Ambiguous. CoreDevice reports the display's rotation directly
        // (`devicectl device info displays`, Xcode 26.6+); prefer it to a
        // guess. Probes run first because they cost milliseconds and
        // settle the common cases; they cannot settle a scene that does
        // not fill the display — an iOS 27.0 SDK app on the iPhone Duo
        // cover keeps out of the status bar strip, so its 678x386 root
        // matches no device size (plan E29).
        if let authoritative, let reported = await authoritative() {
            logger.info().log("OrientationCalibrator: ambiguous after \(probesUsed) probe(s); CoreDevice reports \(reported.rawValue)")
            return await placed(OrientationCalibration(
                orientation: reported,
                native: native,
                uiScale: uiScale,
                probesUsed: probesUsed,
                advisory: nil
            ))
        }

        // No CoreDevice answer. Guess the highest-prior surviving
        // candidate rather than hard-coding portrait: when the AX dims are
        // swapped, portrait is certainly wrong while either landscape has
        // even odds.
        let guess = priorOrder.first(where: candidates.contains) ?? .portrait
        logger.info().log(
            "OrientationCalibrator: ambiguous after \(probesUsed) probe(s); guessing \(guess.rawValue) among \(candidates.map(\.rawValue).joined(separator: ","))"
        )
        return await placed(OrientationCalibration(
            orientation: guess,
            native: native,
            uiScale: uiScale,
            probesUsed: probesUsed,
            advisory: CommandAdvisory(
                kind: .orientationCalibrationFallback,
                message: "Screen orientation could not be confirmed (\(probesUsed) probe(s)); assuming \(guess.rawValue). If the screen changed or the device rotated, re-run describe-ui, or pass explicit -x/-y coordinates."
            )
        ))
    }

    // MARK: - Scene placement

    /// A scene that matches neither device size but fits inside one of
    /// them: it does not fill the display.
    nonisolated static func isInsetScene(_ scene: CGSize, native: NativePortraitSize, uiScale: UIPointScale) -> Bool {
        let portrait = DisplayOrientation.portrait.uiSize(native: native, uiScale: uiScale)
        let size = (width: Double(scene.width), height: Double(scene.height))
        if matches(size, width: portrait.width, height: portrait.height)
            || matches(size, width: portrait.height, height: portrait.width) {
            return false
        }
        func fits(_ w: Double, _ h: Double) -> Bool { size.width <= w + 1 && size.height <= h + 1 }
        return fits(portrait.width, portrait.height) || fits(portrait.height, portrait.width)
    }

    /// Finds where a scene smaller than its display sits, by probing small
    /// elements at each candidate offset: on each axis the scene hugs one
    /// edge, the other, or the centre. The first candidate whose probe
    /// lands on the probed element wins. A scene that fills the display
    /// returns `base` unchanged, without a probe.
    public static func resolveSceneOffset(
        _ base: OrientationCalibration,
        sceneSize: CGSize?,
        discriminators: [CGRect],
        probe: HitTestProbe,
        maxProbes: Int? = nil,
        logger: SimUseLogger
    ) async -> OrientationCalibration {
        guard let sceneSize, let native = base.native else { return base }
        let display = base.orientation.uiSize(native: native, uiScale: base.uiScale)
        let gapX = display.width - Double(sceneSize.width)
        let gapY = display.height - Double(sceneSize.height)
        guard gapX >= -1, gapY >= -1, gapX > 1 || gapY > 1 else { return base }

        func steps(_ gap: Double) -> [Double] { gap > 1 ? [0, gap, gap / 2] : [0] }
        let offsets = steps(gapX).flatMap { x in steps(gapY).map { y in CGPoint(x: x, y: y) } }
        let sceneArea = Double(sceneSize.width * sceneSize.height)
        let usable = discriminators.filter {
            $0.width > 0 && $0.height > 0 && Double($0.width * $0.height) <= maxDiscriminatorAreaRatio * sceneArea
        }.prefix(2)
        // Two probes per candidate at most (~3 ms each): at worst 18 for a
        // scene inset on both axes.
        let budget = maxProbes ?? offsets.count * usable.count

        // A candidate needs every usable element (two at most) to confirm
        // it: one probe can land on something unrelated that happens to
        // sit inside the probed element — on the Duo inner display, the
        // status bar's Wi-Fi icon inside the app's Help button when the
        // offset is wrong by the 80 pt strip.
        var probesUsed = 0
        candidates: for offset in offsets {
            let candidate = base.withScene(offset: offset, size: sceneSize)
            var confirmations = 0
            for rect in usable {
                if probesUsed >= budget { break candidates }
                let center = CGPoint(x: rect.midX, y: rect.midY)
                probesUsed += 1
                guard let hit = try? await probe(candidate.probeCGPoint(center)),
                      let frame = frameRect(of: hit)
                else { continue candidates }
                logger.debug().log("OrientationCalibrator: scene offset (\(Int(offset.x)), \(Int(offset.y))): probe for \(rect) hit \(frame)")
                // The hit must be the probed element or one of its children:
                // a container that merely covers the point would confirm a
                // wrong offset (a full-width row under an 80 pt shift).
                guard rect.insetBy(dx: -containmentSlack, dy: -containmentSlack).contains(frame) else { continue candidates }
                confirmations += 1
            }
            if confirmations == usable.count, confirmations > 0 {
                logger.info().log("OrientationCalibrator: scene \(Int(sceneSize.width))x\(Int(sceneSize.height)) sits at offset (\(Int(offset.x)), \(Int(offset.y))) in the \(Int(display.width))x\(Int(display.height)) display (\(probesUsed) probe(s))")
                return base.withScene(offset: offset, size: sceneSize, probesUsed: probesUsed)
            }
        }
        logger.info().log("OrientationCalibrator: could not place the \(Int(sceneSize.width))x\(Int(sceneSize.height)) scene in the display; assuming the display origin")
        return base.withScene(
            offset: .zero,
            size: sceneSize,
            probesUsed: probesUsed,
            advisory: CommandAdvisory(
                kind: .orientationCalibrationFallback,
                message: "The app's \(Int(sceneSize.width))x\(Int(sceneSize.height)) scene is smaller than the \(Int(display.width))x\(Int(display.height)) display and its position could not be confirmed; taps assume it starts at the display origin and may miss. Re-run describe-ui, or pass explicit -x/-y coordinates."
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
        let scene = display.map { CGSize(width: $0.width, height: $0.height) }
        if let fixed = session.fixedCalibration(sceneSize: scene) {
            return await resolveSceneOffset(
                fixed, sceneSize: scene, discriminators: discriminatorRects(from: roots, display: display),
                probe: session.probe, logger: logger
            )
        }
        return await calibrate(
            native: session.native,
            uiScreenSize: display.map { (width: $0.width, height: $0.height) },
            discriminators: discriminatorRects(from: roots, display: display),
            probe: session.probe,
            maxProbes: maxProbes,
            logger: logger,
            authoritative: session.authoritative
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
        let scene = CGSize(width: payload.screen.width, height: payload.screen.height)
        if let fixed = session.fixedCalibration(sceneSize: scene) {
            return await resolveSceneOffset(
                fixed, sceneSize: scene, discriminators: [rect(entry)] + payload.entries.filter { $0 != entry }.map(rect),
                probe: session.probe, logger: logger
            )
        }
        return await calibrate(
            native: session.native,
            uiScreenSize: nil,
            hint: (width: Double(payload.screen.width), height: Double(payload.screen.height)),
            discriminators: [rect(entry)] + payload.entries.filter { $0 != entry }.map(rect),
            probe: session.probe,
            maxProbes: maxProbes,
            logger: logger,
            authoritative: session.authoritative
        )
    }

    // MARK: - UI metric

    /// A downscaled panel is one uniform factor, so both axis ratios agree
    /// to within a pixels/scale rounding error.
    nonisolated static let maxUIMetricSkew = 0.005
    /// Shipping downscales sit at 0.96 (12/13 mini) and 0.87 (Plus); a
    /// ratio outside this band is not a panel, it is a bad screen size.
    nonisolated static let uiMetricBand = 0.8...1.25

    /// Rotation swaps the reported screen dimensions but never changes the
    /// two numbers, so sorting recovers the portrait-major UI size without
    /// knowing the orientation yet — which is what the scale needs, since
    /// resolving the orientation is what it is about to help with.
    ///
    /// Falls back to identity unless the ratio looks like a real panel
    /// downscale: a UI size that is a window rather than the display (a
    /// resized iPad scene) would otherwise skew every coordinate.
    nonisolated static func uiPointScale(
        native: NativePortraitSize,
        uiScreenSize: (width: Double, height: Double)?
    ) -> UIPointScale {
        guard let size = uiScreenSize else { return .identity }
        let portrait = (width: min(size.width, size.height), height: max(size.width, size.height))
        guard let scale = UIPointScale(native: native, uiPortrait: portrait),
              uiMetricBand.contains(scale.x), uiMetricBand.contains(scale.y),
              abs(scale.x - scale.y) <= maxUIMetricSkew
        else { return .identity }
        return scale
    }

    // MARK: - Candidate ordering

    private static func orderedCandidates(
        native: NativePortraitSize,
        uiScale: UIPointScale,
        uiScreenSize: (width: Double, height: Double)?,
        hint: (width: Double, height: Double)?
    ) -> [DisplayOrientation] {
        if let size = uiScreenSize {
            let portrait = DisplayOrientation.portrait.uiSize(native: native, uiScale: uiScale)
            if matches(size, width: portrait.width, height: portrait.height) {
                return [.portrait, .portraitUpsideDown]
            }
            if matches(size, width: portrait.height, height: portrait.width) {
                return [.landscapeRight, .landscapeLeft]
            }
        }
        let all: [DisplayOrientation] = [.portrait, .portraitUpsideDown, .landscapeRight, .landscapeLeft]
        if let size = uiScreenSize, size.width != size.height {
            // A UI size that is not the device's (a scene that keeps out of
            // a status bar strip) still tells landscape from portrait by its
            // aspect, so probe those candidates first.
            let landscape = size.width > size.height
            return all.filter { $0.swapsDimensions == landscape } + all.filter { $0.swapsDimensions != landscape }
        }
        guard let hint else { return all }
        // The hint (e.g. snapshot dims) is stale by definition — use it
        // only to probe the consistent candidates first.
        let preferred = all.filter { orientation in
            let size = orientation.uiSize(native: native, uiScale: uiScale)
            return matches(hint, width: size.width, height: size.height)
        }
        return preferred + all.filter { !preferred.contains($0) }
    }

    private nonisolated static func matches(_ size: (width: Double, height: Double), width: Double, height: Double) -> Bool {
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

    /// The single orientation under which `probePoint` projects into
    /// `hitFrame` (± `containmentSlack`), or nil when zero or several
    /// orientations do. An ambiguous hit must not pick a winner: the
    /// `--point` fast path used to give portrait the tie, so on a
    /// rotated device a raw hit landing on a large frame confidently
    /// returned the wrong element as `orientation: portrait` with no
    /// advisory.
    ///
    /// Runs before any `UIPointScale` is known, so the non-portrait
    /// projections use the native canvas — on a display-downscaled
    /// device they carry up to ~4% error, which can only make this MORE
    /// conservative (a missed containment falls through to the full
    /// tree calibration). The portrait projection is the identity and
    /// exact everywhere.
    nonisolated static func soleOrientation(
        mapping probePoint: CGPoint,
        into hitFrame: CGRect,
        native: NativePortraitSize
    ) -> DisplayOrientation? {
        let expanded = hitFrame.insetBy(dx: -containmentSlack, dy: -containmentSlack)
        let contained = DisplayOrientation.allCases.filter {
            expanded.contains($0.framebufferToUI(probePoint, native: native))
        }
        return contained.count == 1 ? contained.first : nil
    }

    nonisolated static func frameRect(of node: [String: Any]) -> CGRect? {
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

/// The interface orientation CoreDevice reports for the display that hosts
/// the app, or nil when it cannot answer. The calibrator asks it only when
/// its probes leave the orientation ambiguous.
public typealias AuthoritativeOrientation = @Sendable () async -> DisplayOrientation?

public enum CoreDeviceOrientation {
    /// Reads the active integrated display's rotation (the primary one on a
    /// runtime that marks no display active) with a fresh devicectl query.
    public static func provider(udid: String, monitor: SimulatorDisplayTopologyMonitor = .shared) -> AuthoritativeOrientation {
        {
            guard let topology = await monitor.state(for: udid, fresh: true).topology,
                  let display = topology.activeIntegrated ?? topology.primary
            else { return nil }
            return display.rotation.interfaceOrientation
        }
    }
}

/// One-time simulator lookup yielding the hit-test probe and native
/// screen size — the two inputs calibration needs. Factored so verbs
/// that never fetch a tree (the tap-alias path) can calibrate without
/// paying for one.
///
/// Off the main display (an unfolded iPhone Duo, a Resize Mode session)
/// the probe addresses the routing display and `fixedCalibration` carries
/// the transform CoreDevice already knows, so callers skip the probes.
/// Work record: docs/ai/010-display-routing/000-plan.md.
@MainActor
public struct AXProbeSession {
    public let probe: OrientationCalibrator.HitTestProbe
    public let native: NativePortraitSize?
    public let routing: RoutingDisplay
    public let authoritative: AuthoritativeOrientation

    /// The calibration off the main display; nil on the main display.
    public func fixedCalibration(sceneSize: CGSize?) -> OrientationCalibration? {
        routing.fixedCalibration(sceneSize: sceneSize)
    }

    public static func make(udid: String, logger: SimUseLogger) async throws -> AXProbeSession {
        let simulatorSet = try await getSimulatorSet(
            deviceSetPath: nil,
            logger: logger,
            reporter: EmptyEventReporter.shared
        )
        guard let target = simulatorSet.allSimulators.first(where: { $0.udid == udid }) else {
            throw CLIError(errorDescription: "Simulator with UDID \(udid) not found in set.")
        }
        let routing = await RoutingDisplayResolver.current(udid: udid)
        let displayId = routing.accessibilityDisplayID
        let probe: OrientationCalibrator.HitTestProbe = { point in
            let raw: AnyObject = try await target.legacyAccessibilityElement(at: point, nestedFormat: false, displayId: displayId)
            return raw as? [String: Any]
        }
        return AXProbeSession(
            probe: probe,
            native: NativePortraitSize(screenInfo: target.screenInfo),
            routing: routing,
            authoritative: CoreDeviceOrientation.provider(udid: udid)
        )
    }
}
