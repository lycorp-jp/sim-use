// SPDX-License-Identifier: Apache-2.0
//
//  KeyPressView.swift
//  SimUsePlayground
//
//  Created by Cameron on 23/05/2025.
//

import SwiftUI
import UIKit

// MARK: - Key Press View
struct KeyPressView: View {
    @State private var lastKeyPressed: (name: String, code: Int, modifiers: [String])?
    @State private var keyPressCount = 0
    @State private var detectedKeys: [KeyEvent] = []
    
    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("Key Press Detection")
                    .font(.title2)
                    .fontWeight(.bold)
                    .accessibilityIdentifier("key-press-title")
                
                Text("Detects individual HID key events from CLI")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                if let lastKey = lastKeyPressed {
                    Text("Last Key: \(lastKey.modifiers.joined())\(lastKey.name) (\(lastKey.code))")
                        .font(.headline)
                        .foregroundColor(.blue)
                        .accessibilityIdentifier("last-key-press")
                        .accessibilityValue("\(lastKey.modifiers.joined())\(lastKey.name) (\(lastKey.code))")
                } else {
                    Text("No keys pressed yet")
                        .font(.headline)
                        .foregroundColor(.gray)
                        .accessibilityIdentifier("no-keys-pressed")
                }
                
                Text("Key Count: \(keyPressCount)")
                    .font(.subheadline)
                    .foregroundColor(.green)
                    .accessibilityIdentifier("key-press-count")
                    .accessibilityValue("\(keyPressCount)")
            }
            .padding()
            .background(Color.white.opacity(0.9))
            .cornerRadius(12)
            .shadow(radius: 4)
            
            // Custom key capture view
            KeyCaptureView { keyInfo in
                registerKeyPress(name: keyInfo.name, code: keyInfo.code, modifiers: keyInfo.modifiers)
            }
            .frame(height: 100)
            .background(Color.blue.opacity(0.1))
            .cornerRadius(8)
            .overlay(
                VStack {
                    Text("🔤 Key Capture Area")
                        .font(.headline)
                    Text("Tap here and press any key")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            )
            .accessibilityIdentifier("key-press-field")
            
            if !detectedKeys.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent Key Events:")
                        .font(.headline)
                    ScrollView {
                        LazyVStack(alignment: .leading) {
                            ForEach(detectedKeys.suffix(10)) { keyEvent in
                                HStack {
                                    HStack(spacing: 2) {
                                        if !keyEvent.modifiers.isEmpty {
                                            Text(keyEvent.modifiers.joined())
                                                .font(.caption)
                                                .foregroundColor(.orange)
                                        }
                                        Text("\(keyEvent.name)")
                                            .fontWeight(.medium)
                                    }
                                    Spacer()
                                    Text("Code: \(keyEvent.code)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(keyEvent.timestamp.formatted(date: .omitted, time: .standard))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.horizontal)
                                .accessibilityIdentifier("key-event-\(keyEvent.id)")
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
            }

            Spacer()
        }
        .padding()
        .navigationTitle("Key Press")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("key-press-screen")
    }
    
    private func registerKeyPress(name: String, code: Int, modifiers: [String] = []) {
        lastKeyPressed = (name: name, code: code, modifiers: modifiers)
        keyPressCount += 1
        detectedKeys.append(KeyEvent(name: name, code: code, modifiers: modifiers, timestamp: Date()))
    }
}

// MARK: - Custom Key Capture View
struct KeyCaptureView: UIViewRepresentable {
    let onKeyPress: (KeyInfo) -> Void
    
    func makeUIView(context: Context) -> KeyCaptureUIView {
        let view = KeyCaptureUIView()
        view.onKeyPress = onKeyPress
        return view
    }
    
    func updateUIView(_ uiView: KeyCaptureUIView, context: Context) {
        uiView.onKeyPress = onKeyPress
    }
}

// MARK: - Custom UIView for Key Capture
class KeyCaptureUIView: UIView {
    var onKeyPress: ((KeyInfo) -> Void)?
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }
    
    private func setup() {
        backgroundColor = UIColor.clear
        isUserInteractionEnabled = true
        
        // Add tap gesture to make view first responder
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tapGesture)
    }
    
    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        // Automatically become first responder when added to view hierarchy
        if superview != nil {
            DispatchQueue.main.async {
                self.becomeFirstResponder()
            }
        }
    }
    
    @objc private func handleTap() {
        becomeFirstResponder()
    }
    
    override var canBecomeFirstResponder: Bool {
        return true
    }
    
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let press = presses.first else {
            super.pressesBegan(presses, with: event)
            return
        }
        
        let keyInfo = getKeyInfo(from: press)
        
        // Only log non-modifier keys (but capture any modifiers that are active)
        if !isModifierKeyCode(keyInfo.code) {
            onKeyPress?(keyInfo)
        }
        
        // Don't call super to prevent default handling
    }
    
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Handle key release if needed
        super.pressesEnded(presses, with: event)
    }
    
    private func getKeyInfo(from press: UIPress) -> KeyInfo {
        guard let key = press.key else {
            return KeyInfo(name: "Unknown", code: 0, modifiers: [])
        }
        
        // Extract modifier flags from the press
        let modifiers = extractModifiers(from: press)
        
        // Handle special keys first
        let keyCode = key.keyCode
        switch keyCode {
        case .keyboardTab:
            return KeyInfo(name: "Tab", code: key.keyCode.rawValue, modifiers: modifiers)
        case .keyboardReturnOrEnter:
            return KeyInfo(name: "Return", code: key.keyCode.rawValue, modifiers: modifiers)
        case .keyboardDeleteOrBackspace:
            return KeyInfo(name: "Backspace", code: key.keyCode.rawValue, modifiers: modifiers)
        case .keyboardEscape:
            return KeyInfo(name: "Escape", code: key.keyCode.rawValue, modifiers: modifiers)
        case .keyboardSpacebar:
            return KeyInfo(name: "Space", code: key.keyCode.rawValue, modifiers: modifiers)
        case .keyboardLeftArrow:
            return KeyInfo(name: "Left Arrow", code: key.keyCode.rawValue, modifiers: modifiers)
        case .keyboardRightArrow:
            return KeyInfo(name: "Right Arrow", code: key.keyCode.rawValue, modifiers: modifiers)
        case .keyboardUpArrow:
            return KeyInfo(name: "Up Arrow", code: key.keyCode.rawValue, modifiers: modifiers)
        case .keyboardDownArrow:
            return KeyInfo(name: "Down Arrow", code: key.keyCode.rawValue, modifiers: modifiers)
        case .keyboardPageUp:
            return KeyInfo(name: "Page Up", code: key.keyCode.rawValue, modifiers: modifiers)
        case .keyboardPageDown:
            return KeyInfo(name: "Page Down", code: key.keyCode.rawValue, modifiers: modifiers)
        case .keyboardHome:
            return KeyInfo(name: "Home", code: key.keyCode.rawValue, modifiers: modifiers)
        case .keyboardEnd:
            return KeyInfo(name: "End", code: key.keyCode.rawValue, modifiers: modifiers)
        case .keyboardInsert:
            return KeyInfo(name: "Insert", code: key.keyCode.rawValue, modifiers: modifiers)
        case .keyboardDeleteForward:
            return KeyInfo(name: "Delete", code: key.keyCode.rawValue, modifiers: modifiers)
        case .keyboardF1:
            return KeyInfo(name: "F1", code: key.keyCode.rawValue, modifiers: modifiers)
        case .keyboardF2:
            return KeyInfo(name: "F2", code: key.keyCode.rawValue, modifiers: modifiers)
        case .keyboardF3:
            return KeyInfo(name: "F3", code: key.keyCode.rawValue, modifiers: modifiers)
        case .keyboardF4:
            return KeyInfo(name: "F4", code: key.keyCode.rawValue, modifiers: modifiers)
        case .keyboardF5:
            return KeyInfo(name: "F5", code: key.keyCode.rawValue, modifiers: modifiers)
        case .keyboardF6:
            return KeyInfo(name: "F6", code: key.keyCode.rawValue, modifiers: modifiers)
        case .keyboardF7:
            return KeyInfo(name: "F7", code: key.keyCode.rawValue, modifiers: modifiers)
        case .keyboardF8:
            return KeyInfo(name: "F8", code: key.keyCode.rawValue, modifiers: modifiers)
        case .keyboardF9:
            return KeyInfo(name: "F9", code: key.keyCode.rawValue, modifiers: modifiers)
        case .keyboardF10:
            return KeyInfo(name: "F10", code: key.keyCode.rawValue, modifiers: modifiers)
        case .keyboardF11:
            return KeyInfo(name: "F11", code: key.keyCode.rawValue, modifiers: modifiers)
        case .keyboardF12:
            return KeyInfo(name: "F12", code: key.keyCode.rawValue, modifiers: modifiers)
        default:
            return KeyInfo(name: key.characters, code: key.keyCode.rawValue, modifiers: modifiers)
        }
    }
    
    private func extractModifiers(from press: UIPress) -> [String] {
        var modifiers: [String] = []
        
        // Check if modifierFlags is available (iOS 13.4+)
        if #available(iOS 13.4, *) {
            let modifierFlags = press.key?.modifierFlags ?? []
            
            if modifierFlags.contains(.command) {
                modifiers.append("⌘")  // Command
            }
            if modifierFlags.contains(.control) {
                modifiers.append("⌃")  // Control
            }
            if modifierFlags.contains(.alternate) {
                modifiers.append("⌥")  // Option/Alt
            }
            if modifierFlags.contains(.shift) {
                modifiers.append("⇧")  // Shift
            }
            if modifierFlags.contains(.alphaShift) {
                modifiers.append("⇪")  // Caps Lock
            }
            if modifierFlags.contains(.numericPad) {
                modifiers.append("⌨")  // Numeric Pad
            }
        }
        
        return modifiers
    }
    
    private func isModifierKeyCode(_ code: Int) -> Bool {
        // Common modifier key codes
        switch code {
        case 224: return true // Left Control
        case 225: return true // Left Shift  
        case 226: return true // Left Alt/Option
        case 227: return true // Left Command/GUI
        case 228: return true // Right Control
        case 229: return true // Right Shift
        case 230: return true // Right Alt/Option
        case 231: return true // Right Command/GUI
        default: return false
        }
    }
}

// MARK: - Supporting Types
struct KeyInfo {
    let name: String
    let code: Int
    let modifiers: [String]
}

struct KeyEvent: Identifiable {
    let id = UUID()
    let name: String
    let code: Int
    let modifiers: [String]
    let timestamp: Date
} 