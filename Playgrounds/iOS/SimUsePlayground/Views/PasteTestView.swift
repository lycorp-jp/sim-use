// SPDX-License-Identifier: Apache-2.0
//
//  PasteTestView.swift
//  SimUsePlayground
//
//  Created by Cameron on 23/05/2025.
//

import SwiftUI

// MARK: - Paste Test View
struct PasteTestView: View {
    @State private var inputText = ""
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("Paste Playground")
                    .font(.title2)
                    .fontWeight(.bold)
                    .accessibilityIdentifier("paste-test-title")
                Text("Paste text via the simulator pasteboard")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .accessibilityIdentifier("paste-test-description")
            }
            .padding()
            .background(Color.white.opacity(0.9))
            .cornerRadius(12)
            .shadow(radius: 4)

            VStack(spacing: 16) {
                TextField("Paste target...", text: $inputText)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .font(.title2)
                    .focused($isTextFieldFocused)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("paste-input-field")
                    .accessibilityValue(inputText.isEmpty ? "empty" : inputText)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Characters: \(inputText.count)")
                        .font(.headline)
                        .accessibilityIdentifier("paste-char-count")
                        .accessibilityValue("\(inputText.count)")
                    Text("Content: \(inputText)")
                        .accessibilityIdentifier("paste-content-echo")
                        .accessibilityValue(inputText.isEmpty ? "empty" : inputText)
                }
                .padding()
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
                .frame(maxWidth: .infinity, alignment: .leading)

                Button("Clear") {
                    inputText = ""
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("paste-clear-button")
            }
            .padding()

            Spacer()
        }
        .padding()
        .navigationTitle("Paste Test")
        .navigationBarTitleDisplayMode(.inline)
        // No screen-level accessibilityIdentifier: applied to the root it
        // propagates down and overrides every child's own id, which the
        // per-element E2E selectors (paste-input-field, paste-content-echo,
        // …) depend on.
        .onAppear {
            isTextFieldFocused = true
        }
    }
}

#Preview {
    NavigationStack {
        PasteTestView()
    }
}
