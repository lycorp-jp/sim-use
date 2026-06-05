// SPDX-License-Identifier: Apache-2.0
//
//  KeySequenceView.swift
//  SimUsePlayground
//
//  Created by Cameron on 23/05/2025.
//

import SwiftUI

// MARK: - Key Sequence View
struct KeySequenceView: View {
    @State private var detectedSequences: [KeySequence] = []
    @State private var currentSequence: [String] = []
    @State private var sequenceTimer: Timer?
    @State private var isDetecting = true
    @FocusState private var isTextFieldFocused: Bool
    
    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("Key Sequence Detection")
                    .font(.title2)
                    .fontWeight(.bold)
                Text("Detects key sequences sent by CLI")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                HStack {
                    Circle()
                        .fill(isDetecting ? .green : .red)
                        .frame(width: 12, height: 12)
                    Text(isDetecting ? "Detecting sequences" : "Not detecting")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(Color.white.opacity(0.9))
            .cornerRadius(12)
            .shadow(radius: 4)
            
            // Text field to capture key sequence events
            TextField("Focus here to detect CLI key sequences", text: .constant(""))
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .font(.title2)
                .focused($isTextFieldFocused)
                .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidChangeNotification)) { notification in
                    if let textField = notification.object as? UITextField,
                       let text = textField.text,
                       let lastChar = text.last {
                        currentSequence.append(String(lastChar))
                        textField.text = ""
                        
                        // Reset timer for sequence completion
                        sequenceTimer?.invalidate()
                        sequenceTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
                            if !currentSequence.isEmpty {
                                let sequence = KeySequence(keys: currentSequence, timestamp: Date())
                                detectedSequences.append(sequence)
                                currentSequence.removeAll()
                            }
                        }
                    }
                }
            
            if !currentSequence.isEmpty {
                Text("Current: \(currentSequence.joined(separator: " → "))")
                    .font(.headline)
                    .padding()
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(8)
            }
            
            if !detectedSequences.isEmpty {
                VStack(alignment: .leading) {
                    Text("Detected Sequences:")
                        .font(.headline)
                    ScrollView {
                        LazyVStack(alignment: .leading) {
                            ForEach(Array(detectedSequences.suffix(5).enumerated()), id: \.offset) { index, sequence in
                                let timeString = sequence.timestamp.formatted(date: .omitted, time: .standard)
                                Text("\(sequence.keys.joined(separator: " → ")) - \(timeString)")
                                    .font(.caption)
                                    .padding(.horizontal)
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
        .navigationTitle("Key Sequence")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            isTextFieldFocused = true
        }
    }
}

struct KeySequence: Identifiable {
    let id = UUID()
    let keys: [String]
    let timestamp: Date
} 