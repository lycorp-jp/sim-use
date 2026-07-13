// SPDX-License-Identifier: Apache-2.0
//
//  TapTestView.swift
//  SimUsePlayground
//
//  Created by Cameron on 23/05/2025.
//

import SwiftUI

struct TapTestView: View {
    @State private var tapIndicators: [TapIndicator] = []
    @State private var tapCount = 0
    @State private var lastTapCoordinates: CGPoint?
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Interactive tap area
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        addTapIndicator(at: location, in: geometry)
                    }
                    .accessibilityIdentifier("tap-test-area")
            
            VStack {
                // Header
                VStack(spacing: 8) {
                    Text("Tap Test")
                        .font(.title2)
                        .fontWeight(.bold)
                        .accessibilityIdentifier("tap-test-title")
                    
                    Text("Detects taps sent by CLI commands")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .accessibilityIdentifier("tap-test-description")
                    
                    Text("Tap Count: \(tapCount)")
                        .font(.headline)
                        .foregroundColor(.blue)
                        .accessibilityIdentifier("tap-count")
                        .accessibilityValue("\(tapCount)")
                    
                    if let lastTap = lastTapCoordinates {
                        Text("Tap Location: (\(Int(lastTap.x)), \(Int(lastTap.y)))")
                            .font(.headline)
                            .foregroundColor(.green)
                            .accessibilityIdentifier("last-tap-coordinates")
                            .accessibilityValue("x:\(Int(lastTap.x)),y:\(Int(lastTap.y))")
                    }
                }
                .padding()
                .background(Color.white.opacity(0.9))
                .cornerRadius(12)
                .shadow(radius: 4)  

                Spacer()      
            }
            .padding()
            .allowsHitTesting(false)
            
            // Tap indicators overlay - now persistent with labels
            ForEach(tapIndicators) { indicator in
                Capsule()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [indicator.color.opacity(0.8), indicator.color.opacity(0.6)]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: 80, height: 32)
                    .overlay(
                        Text("(\(Int(indicator.displayX)), \(Int(indicator.displayY)))")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                    )
                    .position(x: indicator.x, y: indicator.y)
                    .scaleEffect(indicator.scale)
                    .opacity(indicator.opacity)
                    .shadow(color: indicator.color.opacity(0.3), radius: 3, x: 0, y: 2)
                    .accessibilityIdentifier("tap-indicator-\(indicator.id.uuidString)")
                    .accessibilityValue("x:\(Int(indicator.displayX)),y:\(Int(indicator.displayY))")
            }
            
            // Hidden accessibility element that reports all tap history
            Text("")
                .accessibilityIdentifier("tap-history")
                .accessibilityValue(generateTapHistoryString())
                .accessibilityHidden(true)
        }
        }
        .navigationTitle("Tap Test")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("tap-test-screen")
    }
    
    private func addTapIndicator(at point: CGPoint, in geometry: GeometryProxy) {
        // Convert view coordinates to screen coordinates
        let globalFrame = geometry.frame(in: .global)
        let screenPoint = CGPoint(
            x: point.x + globalFrame.minX,
            y: point.y + globalFrame.minY
        )
        
        // Offset position slightly to avoid perfect overlap
        let offsetX = point.x + CGFloat.random(in: -5...5)
        let offsetY = point.y + CGFloat.random(in: -5...5)
        
        // Color cycling for visual distinction
        let colors: [Color] = [.blue, .green, .purple, .orange, .red, .cyan]
        let color = colors[tapCount % colors.count]
        
        let indicator = TapIndicator(
            x: offsetX,
            y: offsetY,
            displayX: screenPoint.x,  // Store screen coordinates for display
            displayY: screenPoint.y,
            color: color,
            scale: 0.3,
            opacity: 0.9
        )
        
        tapIndicators.append(indicator)
        tapCount += 1
        lastTapCoordinates = screenPoint
        
        // Animate the indicator appearing
        withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
            if let index = tapIndicators.firstIndex(where: { $0.id == indicator.id }) {
                tapIndicators[index].scale = 1.0
                tapIndicators[index].opacity = 0.9
            }
        }
    }
    
    private func generateTapHistoryString() -> String {
        if tapCount == 0 {
            return "no-taps"
        }
        
        let recentTaps = tapIndicators.suffix(10) // Last 10 taps
        let tapStrings = recentTaps.map { "x:\(Int($0.displayX)),y:\(Int($0.displayY))" }
        return "count:\(tapCount);recent:[\(tapStrings.joined(separator: ","))]"
    }
}

struct TapIndicator: Identifiable {
    let id = UUID()
    let x: CGFloat
    let y: CGFloat
    let displayX: CGFloat  // Screen coordinates for display
    let displayY: CGFloat
    let color: Color
    var scale: CGFloat
    var opacity: Double
}

#Preview {
    NavigationStack {
        TapTestView()
    }
} 