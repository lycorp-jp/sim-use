// SPDX-License-Identifier: Apache-2.0
//
//  OrientationTestView.swift
//  SimUsePlayground
//
//  Created by Cameron on 23/05/2025.
//

import SwiftUI
import UIKit

// MARK: - Orientation Test View
//
// Exercises sim-use's AX→HID orientation self-calibration: after a
// programmatic rotation the four corner probes must still register a tap
// when addressed by AX id, proving the coordinate transform tracks the
// live interface orientation. `current-orientation` reflects the current
// interface orientation; the rotate buttons drive it via
// `UIWindowScene.requestGeometryUpdate`.
struct OrientationTestView: View {
    @State private var orientationName = "unknown"
    @State private var lastTappedCorner = "none"

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                VStack(spacing: 20) {
                    Text("Orientation Playground")
                        .font(.title2)
                        .fontWeight(.bold)
                        .accessibilityIdentifier("orientation-test-title")

                    Text("Orientation: \(orientationName)")
                        .font(.headline)
                        .foregroundColor(.blue)
                        .accessibilityIdentifier("current-orientation")
                        .accessibilityValue(orientationName)

                    Text("Last corner: \(lastTappedCorner)")
                        .font(.subheadline)
                        .foregroundColor(.green)
                        .accessibilityIdentifier("corner-last-tapped")
                        .accessibilityValue(lastTappedCorner)

                    HStack(spacing: 12) {
                        Button("Landscape") {
                            requestOrientation(.landscapeRight)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("rotate-landscape-button")

                        Button("Portrait") {
                            requestOrientation(.portrait)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("rotate-portrait-button")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Corner probes pinned to the four corners. Declared last
                // so they sit on top of the centred content for hit-testing.
                VStack {
                    HStack {
                        cornerButton("corner-top-leading")
                        Spacer()
                        cornerButton("corner-top-trailing")
                    }
                    Spacer()
                    HStack {
                        cornerButton("corner-bottom-leading")
                        Spacer()
                        cornerButton("corner-bottom-trailing")
                    }
                }
            }
            .onAppear { updateOrientation() }
            .onChange(of: geometry.size) { _, _ in updateOrientation() }
        }
        .padding()
        .navigationTitle("Orientation Test")
        .navigationBarTitleDisplayMode(.inline)
        // No screen-level accessibilityIdentifier: applied to the root it
        // propagates down and overrides every child's own id, which the
        // per-element E2E selectors (corner-top-trailing, current-orientation,
        // …) depend on.
    }

    private func cornerButton(_ id: String) -> some View {
        Button {
            lastTappedCorner = id
        } label: {
            Image(systemName: "smallcircle.filled.circle")
                .font(.title)
                .frame(width: 56, height: 56)
                .background(Color.orange.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityIdentifier(id)
    }

    private func activeWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    private func updateOrientation() {
        guard let scene = activeWindowScene() else { return }
        orientationName = name(for: scene.interfaceOrientation)
    }

    private func requestOrientation(_ mask: UIInterfaceOrientationMask) {
        guard let scene = activeWindowScene() else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in
            // Request rejected (e.g. unsupported orientation); the label
            // simply stays put. Nothing to recover here.
        }
        // The geometry change also drives `onChange(of:)`, but re-read
        // shortly after in case the size does not change (e.g. re-request
        // of the current orientation).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            updateOrientation()
        }
    }

    private func name(for orientation: UIInterfaceOrientation) -> String {
        switch orientation {
        case .portrait: return "portrait"
        case .portraitUpsideDown: return "portraitUpsideDown"
        case .landscapeLeft: return "landscapeLeft"
        case .landscapeRight: return "landscapeRight"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }
}

#Preview {
    NavigationStack {
        OrientationTestView()
    }
}
