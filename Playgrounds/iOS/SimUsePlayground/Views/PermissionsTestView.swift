// SPDX-License-Identifier: Apache-2.0
//
//  PermissionsTestView.swift
//  SimUsePlayground
//
//  Created by Cameron on 23/05/2025.
//

import CoreLocation
import SwiftUI

// MARK: - Permissions Test View
//
// Exercises the "system alert appears → sim-use observes it (SpringBoard /
// system layer) → sim-use taps to dismiss it → app state reflects the
// choice" loop. Location is used because it is the permission type
// `xcrun simctl privacy reset location <bundle>` can reset, so the prompt
// reliably reappears on every E2E run. The current authorization status
// is echoed as `location-status` (notDetermined / authorizedWhenInUse /
// denied / …) and updates via the CLLocationManager delegate as soon as
// the prompt is dismissed.
struct PermissionsTestView: View {
    @StateObject private var location = LocationPermissionModel()

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("Permissions Playground")
                    .font(.title2)
                    .fontWeight(.bold)
                    .accessibilityIdentifier("permissions-test-title")
                Text("Trigger a system permission prompt, then allow/deny it")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .accessibilityIdentifier("permissions-test-description")
            }
            .padding()
            .background(Color.white.opacity(0.9))
            .cornerRadius(12)
            .shadow(radius: 4)

            Text("location-status: \(location.status)")
                .font(.headline)
                .foregroundColor(.blue)
                .accessibilityIdentifier("location-status")
                .accessibilityValue(location.status)

            Button("Request Location Permission") {
                location.request()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("request-location-button")

            Button("Refresh Status") {
                location.refresh()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("refresh-status-button")

            Spacer()
        }
        .padding()
        .navigationTitle("Permissions Test")
        .navigationBarTitleDisplayMode(.inline)
        // No screen-level accessibilityIdentifier: it would propagate down
        // and clobber the child ids (location-status, request-location-button)
        // the E2E selectors depend on.
    }
}

// MARK: - Location permission model

/// Thin wrapper around `CLLocationManager` that publishes the current
/// authorization status as a stable string. The delegate callback fires
/// on the main thread when the user responds to the prompt, so the
/// `location-status` label updates as soon as the alert is dismissed.
final class LocationPermissionModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    @Published var status: String

    override init() {
        status = "notDetermined"
        super.init()
        manager.delegate = self
        status = Self.name(for: manager.authorizationStatus)
    }

    func request() {
        manager.requestWhenInUseAuthorization()
    }

    func refresh() {
        status = Self.name(for: manager.authorizationStatus)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        status = Self.name(for: manager.authorizationStatus)
    }

    private static func name(for status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedAlways: return "authorizedAlways"
        case .authorizedWhenInUse: return "authorizedWhenInUse"
        @unknown default: return "unknown"
        }
    }
}

#Preview {
    NavigationStack {
        PermissionsTestView()
    }
}
