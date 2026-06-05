// SPDX-License-Identifier: Apache-2.0
//
//  GesturePresetsView.swift
//  SimUsePlayground
//
//  Created by Cameron on 23/05/2025.
//

import SwiftUI
import SceneKit

// MARK: - SceneKit 3D Cube View
struct SceneKitCubeView: UIViewRepresentable {
    @Binding var scale: Float
    @Binding var rotationX: Float
    @Binding var rotationY: Float
    @Binding var rotationZ: Float
    @Binding var color: Color
    @Binding var opacity: Float
    @Binding var gestureType: String
    
    func makeUIView(context: Context) -> SCNView {
        let sceneView = SCNView()
        let scene = SCNScene()
        sceneView.scene = scene
        sceneView.allowsCameraControl = false
        sceneView.backgroundColor = UIColor.clear
        sceneView.isUserInteractionEnabled = false
        sceneView.antialiasingMode = .multisampling4X
        
        let cubeGeometry = SCNBox(width: 3.0, height: 3.0, length: 3.0, chamferRadius: 0.2)
        let cubeNode = SCNNode(geometry: cubeGeometry)
        cubeNode.name = "cube"
        
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(color)
        material.specular.contents = UIColor.white
        material.shininess = 1.0
        material.lightingModel = .lambert
        cubeGeometry.materials = [material]
        scene.rootNode.addChildNode(cubeNode)
        
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.position = SCNVector3(x: 0, y: 0, z: 10)
        scene.rootNode.addChildNode(cameraNode)
        
        let lightNode = SCNNode()
        lightNode.light = SCNLight()
        lightNode.light!.type = .omni
        lightNode.light!.intensity = 1000
        lightNode.position = SCNVector3(x: 0, y: 10, z: 10)
        scene.rootNode.addChildNode(lightNode)
        
        let ambientLightNode = SCNNode()
        ambientLightNode.light = SCNLight()
        ambientLightNode.light!.type = .ambient
        ambientLightNode.light!.color = UIColor.lightGray
        ambientLightNode.light!.intensity = 300
        scene.rootNode.addChildNode(ambientLightNode)
        
        return sceneView
    }
    
    func updateUIView(_ uiView: SCNView, context: Context) {
        guard let cubeNode = uiView.scene?.rootNode.childNode(withName: "cube", recursively: false) else { return }
        
        if let material = cubeNode.geometry?.materials.first {
            material.diffuse.contents = UIColor(color.opacity(Double(opacity)))
        }
        
        cubeNode.removeAllActions()
        
        if gestureType == "reset" {
            let scaleAction = SCNAction.scale(to: 1.0, duration: 0.5)
            let rotateAction = SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: 0.5)
            let group = SCNAction.group([scaleAction, rotateAction])
            group.timingMode = .easeOut
            cubeNode.runAction(group)
        } else {
            cubeNode.scale = SCNVector3(scale, scale, scale)
            cubeNode.eulerAngles = SCNVector3(
                rotationX * Float.pi / 180,
                rotationY * Float.pi / 180,
                rotationZ * Float.pi / 180
            )
        }
    }
}

// MARK: - Gesture Presets View
struct GesturePresetsView: View {
    @State private var gestureHistory: [GestureEvent] = []
    @State private var gestureColor: Color = .blue
    @State private var lastDetectedGesture: String = "None"
    @State private var showLastDetectedGesture: Bool = false
    @State private var gestureResetTimer: Timer? = nil
    
    @GestureState private var magnificationState = false
    @GestureState private var dragState = false
    @GestureState private var rotationState = false
    
    @State private var cubeScale: Float = 1.0
    @State private var cubeRotationX: Float = 0.0
    @State private var cubeRotationY: Float = 0.0
    @State private var cubeRotationZ: Float = 0.0
    @State private var cubeColor: Color = .blue
    @State private var cubeOpacity: Float = 0.8
    @State private var gestureTypeForSceneKit: String = ""
    
    var body: some View {
        ZStack {
             if showLastDetectedGesture {
                 Text(lastDetectedGesture.uppercased())
                     .font(.headline).fontWeight(.bold).foregroundColor(.white)
                     .padding(.horizontal, 16).padding(.vertical, 8)
                     .background(colorForGesture(lastDetectedGesture).opacity(0.9))
                     .clipShape(Capsule())
                     .shadow(radius: 4).scaleEffect(1.1)
                     .animation(.easeOut(duration: 0.3), value: lastDetectedGesture)
             }
            
            Rectangle()
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [gestureColor.opacity(0.1), gestureColor.opacity(0.05)]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("gesture-detection-area")
                .accessibilityValue(generateGestureAccessibilityValue())
                .gesture(
                    SimultaneousGesture(
                        MagnificationGesture()
                            .updating($magnificationState) { value, state, _ in
                                // `value` from MagnificationGesture is the cumulative scale factor from the start.
                                state = true
                                
                                // Set cubeScale directly based on gesture's value, then clamp.
                                self.cubeScale = max(0.3, min(1.8, Float(value)))

                                self.cubeOpacity = Float(0.4 + (Double(self.cubeScale) * 0.4))
                                self.cubeColor = Float(value) > 1.0 ? .mint : .green
                                self.gestureColor = self.cubeColor
                                
                                // Capture the cubeScale that resulted from *this specific magnification update*
                                // This is the value the timer will use if onEnded doesn't fire.
                                let scaleAtThisMagnificationUpdate = self.cubeScale
                                
                                self.gestureResetTimer?.invalidate()
                                self.gestureResetTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in 
                                    if scaleAtThisMagnificationUpdate <= 0.65 {
                                         self.detectGesture("pinch-in")
                                    } else if scaleAtThisMagnificationUpdate >= 1.35 {
                                         self.detectGesture("pinch-out")
                                    }
                                    
                                    self.resetCubeState(triggeredByMagnification: true)
                                }
                            }
                            .onEnded { value in
                                let finalMagnificationFactor = Float(value)
                                self.gestureResetTimer?.invalidate()
                                self.gestureResetTimer = nil
                                
                                if abs(finalMagnificationFactor - 1.0) > 0.2 {
                                    let detectedPinchType = finalMagnificationFactor > 1.0 ? "pinch-out" : "pinch-in"
                                    self.detectGesture(detectedPinchType)
                                } else {
                                }
                                
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                    self.resetCubeState(triggeredByMagnification: true)
                                }
                            },
                        
                        SimultaneousGesture(
                            RotationGesture()
                                .updating($rotationState) { value, state, _ in
                                    state = true
                                    self.cubeRotationZ = Float(value.radians * 180 / .pi)
                                    self.cubeColor = .purple
                                    self.gestureColor = self.cubeColor
                                }
                                .onEnded { value in
                                    var detected = false
                                    if abs(value.radians) > 0.3 {
                                        self.detectGesture("rotate")
                                        detected = true
                                    }
                                    self.resetCubeState(triggeredByMagnification: false)
                                },
                            
                            DragGesture(minimumDistance: 0)
                                .updating($dragState) { value, state, _ in
                                    state = true
                                    let sensitivity: Float = 0.5
                                    self.cubeRotationX = Float(value.translation.height) * sensitivity
                                    self.cubeRotationY = Float(value.translation.width) * sensitivity
                                    
                                    let absX = abs(value.translation.width)
                                    let absY = abs(value.translation.height)
                                    if absX > absY {
                                        self.cubeColor = value.translation.width > 0 ? .cyan : .purple
                                    } else {
                                        self.cubeColor = value.translation.height > 0 ? .blue : .red
                                    }
                                    self.gestureColor = self.cubeColor
                                }
                                .onEnded { value in
                                    let distance = sqrt(pow(value.translation.width, 2) + pow(value.translation.height, 2))
                                    var detected = false
                                    if distance > 30 {
                                        let detectedDragType = self.classifyDragGesture(value.translation)
                                        self.detectGesture(detectedDragType)
                                        detected = true
                                    }
                                    self.resetCubeState(triggeredByMagnification: false)
                                }
                        )
                    )
                )
            
            SceneKitCubeView(
                scale: $cubeScale,
                rotationX: $cubeRotationX,
                rotationY: $cubeRotationY,
                rotationZ: $cubeRotationZ,
                color: $cubeColor,
                opacity: $cubeOpacity,
                gestureType: $gestureTypeForSceneKit
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            
            VStack(spacing: 16) {
                VStack(spacing: 8) {
                    Text("Gesture Presets Playground").font(.title2).fontWeight(.bold)
                    Text("Watch the 3D cube react to your gestures").font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
                    Text("Detected: \(gestureHistory.count)").font(.headline).foregroundColor(.purple)
                        .accessibilityIdentifier("gesture-count").accessibilityValue("\(gestureHistory.count)")
                    Text("Latest Gesture: \(lastDetectedGesture)")
                        .accessibilityIdentifier("latest-gesture").accessibilityValue(lastDetectedGesture)
                }
                .padding().background(Material.thin).cornerRadius(12).shadow(radius: 4)
                
                HStack {
                    Circle().fill(gestureStatusColor()).frame(width: 12, height: 12)
                    Text(gestureStatusText()).font(.caption).foregroundColor(.secondary)
                }
                .padding(.horizontal)
                
                Spacer()
                
                if !gestureHistory.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Recent:").font(.caption).fontWeight(.semibold)
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(gestureHistory.enumerated()), id: \.offset) { index, event in
                                HStack(spacing: 8) {
                                    HStack(spacing: 4) {
                                        Circle().fill(colorForGesture(event.gesture)).frame(width: 6, height: 6)
                                        Text(event.gesture).font(.caption2).fontWeight(.medium)
                                    }
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(colorForGesture(event.gesture).opacity(0.2)).cornerRadius(4)
                                    Spacer()
                                    Text(event.timestamp.formatted(date: .omitted, time: .standard))
                                        .font(.caption2).foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.horizontal).padding(.vertical, 8)
                    .background(Material.regular).cornerRadius(8).shadow(radius: 2)
                }
            }
            .padding()
            .allowsHitTesting(false)
        }
        .navigationTitle("Gesture Presets")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("gesture-presets-screen")
    }
    
    private func classifyDragGesture(_ translation: CGSize) -> String {
        let absX = abs(translation.width)
        let absY = abs(translation.height)
        if absX > absY { return translation.width > 0 ? "scroll-right" : "scroll-left" }
        else { return translation.height > 0 ? "scroll-down" : "scroll-up" }
    }
    
    private func detectGesture(_ gesture: String) {
        let event = GestureEvent(gesture: gesture, timestamp: Date())
        gestureHistory.append(event)
        lastDetectedGesture = gesture
        
        showLastDetectedGesture = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.showLastDetectedGesture = false
        }
    }
    
    private func resetCubeState(triggeredByMagnification: Bool) {
        if triggeredByMagnification {
            gestureResetTimer?.invalidate()
            gestureResetTimer = nil
        } 
        
        cubeScale = 1.0
        cubeRotationX = 0.0
        cubeRotationY = 0.0
        cubeRotationZ = 0.0
        cubeColor = .blue
        cubeOpacity = 0.8
        gestureColor = .blue
        
        self.gestureTypeForSceneKit = "reset"
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if self.gestureTypeForSceneKit == "reset" { self.gestureTypeForSceneKit = "" }
        }
    }
    
    private func gestureStatusColor() -> Color {
        if magnificationState { return .green }
        else if rotationState { return .purple }
        else if dragState { return .blue }
        else { return .gray }
    }
    
    private func gestureStatusText() -> String {
        if magnificationState { return "Pinch active - Scale: \(String(format: "%.2f", cubeScale))" }
        else if rotationState { return "Rotation active - Z: \(String(format: "%.1f", cubeRotationZ))°" }
        else if dragState { return "Drag active - X: \(String(format: "%.1f", cubeRotationX))°, Y: \(String(format: "%.1f", cubeRotationY))°" }
        else { return "Ready for gestures" }
    }
    
    private func generateGestureAccessibilityValue() -> String {
        if gestureHistory.isEmpty { return "no-gestures-detected" }
        let recentGestures = gestureHistory.suffix(5).map { "\($0.gesture):\($0.timestamp.timeIntervalSince1970)" }
        return "count:\(gestureHistory.count);recent:[\(recentGestures.joined(separator: ","))]"
    }
    
    private func colorForGesture(_ gesture: String) -> Color {
        switch gesture {
        case "scroll-up": return .red; case "scroll-down": return .blue
        case "scroll-left": return .purple; case "scroll-right": return .cyan
        case "pinch-in": return .green; case "pinch-out": return .mint
        case "rotate": return .purple; default: return .gray
        }
    }
}

struct GestureEvent: Identifiable {
    let id = UUID()
    let gesture: String
    let timestamp: Date
}