// SPDX-License-Identifier: Apache-2.0
//
//  ButtonTestView.swift
//  SimUsePlayground
//
//  Created by Cameron on 24/05/2025.
//

import SwiftUI

struct ButtonTestView: View {
    @State private var lastButtonPressed: String?
    @State private var buttonPressCount = 0
    @State private var pressHistory: [ButtonPress] = []
    
    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("Hardware Button Detection")
                    .font(.title2)
                    .fontWeight(.bold)
                    .accessibilityIdentifier("button-test-title")
                
                Text("Detects hardware button presses from CLI")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                if let lastButton = lastButtonPressed {
                    Text("Last Button: \(lastButton)")
                        .font(.headline)
                        .foregroundColor(.blue)
                        .accessibilityIdentifier("last-button-press")
                        .accessibilityValue(lastButton)
                } else {
                    Text("No buttons pressed yet")
                        .font(.headline)
                        .foregroundColor(.gray)
                        .accessibilityIdentifier("no-buttons-pressed")
                }
                
                Text("Button Count: \(buttonPressCount)")
                    .font(.subheadline)
                    .foregroundColor(.green)
                    .accessibilityIdentifier("button-press-count")
                    .accessibilityValue("\(buttonPressCount)")
            }
            .padding()
            .background(Color.white.opacity(0.9))
            .cornerRadius(12)
            .shadow(radius: 4)
            
            // Manual button simulation for testing
            VStack(spacing: 12) {
                Text("Simulate Button Presses:")
                    .font(.headline)
                
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 12) {
                    ButtonSimulator(title: "Home", icon: "house.fill") {
                        registerButtonPress("home")
                    }
                    ButtonSimulator(title: "Lock", icon: "lock.fill") {
                        registerButtonPress("lock")
                    }
                    ButtonSimulator(title: "Side Button", icon: "power") {
                        registerButtonPress("side-button")
                    }
                    ButtonSimulator(title: "Siri", icon: "mic.fill") {
                        registerButtonPress("siri")
                    }
                    ButtonSimulator(title: "Apple Pay", icon: "creditcard.fill") {
                        registerButtonPress("apple-pay")
                    }
                }
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)
            
            if !pressHistory.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent Button Presses:")
                        .font(.headline)
                    ScrollView {
                        LazyVStack(alignment: .leading) {
                            ForEach(pressHistory.suffix(5)) { press in
                                Text("\(press.button) - \(press.timestamp.formatted(date: .omitted, time: .standard))")
                                    .font(.caption)
                                    .padding(.horizontal)
                                    .accessibilityIdentifier("button-event-\(press.id)")
                            }
                        }
                    }
                    .frame(maxHeight: 120)
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
            }

            Spacer()
        }
        .padding()
        .navigationTitle("Button Test")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("button-test-screen")
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // This would be where we'd detect actual hardware button events
            // For now, we'll simulate based on app lifecycle events
        }
    }
    
    private func registerButtonPress(_ button: String) {
        lastButtonPressed = button
        buttonPressCount += 1
        pressHistory.append(ButtonPress(button: button, timestamp: Date()))
    }
}

struct ButtonSimulator: View {
    let title: String
    let icon: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title2)
                Text(title)
                    .font(.caption)
            }
            .foregroundColor(.white)
            .frame(height: 60)
            .frame(maxWidth: .infinity)
            .background(Color.blue)
            .cornerRadius(8)
        }
    }
}

struct ButtonPress: Identifiable {
    let id = UUID()
    let button: String
    let timestamp: Date
}

#Preview {
    NavigationStack {
        ButtonTestView()
    }
}