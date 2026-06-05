// SPDX-License-Identifier: Apache-2.0
//
//  SimUsePlaygroundApp.swift
//  SimUsePlayground
//
//  Created by Cameron on 23/05/2025.
//

import SwiftUI

@main
struct SimUsePlaygroundApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    // Handle launch arguments for direct screen navigation
                    handleLaunchArguments()
                }
        }
    }
    
    private func handleLaunchArguments() {
        let arguments = ProcessInfo.processInfo.arguments
        
        // Look for screen launch argument
        if let screenIndex = arguments.firstIndex(of: "--launch-arg"),
           screenIndex + 1 < arguments.count {
            let argument = arguments[screenIndex + 1]
            if argument.hasPrefix("screen=") {
                let screenName = String(argument.dropFirst(7)) // Remove "screen=" prefix
                NavigationManager.shared.navigateToScreen(screenName)
            }
        }
    }
}

// Singleton to manage navigation state
class NavigationManager: ObservableObject {
    static let shared = NavigationManager()
    
    @Published var directLaunchScreen: String? = nil
    
    private init() {}
    
    func navigateToScreen(_ screenName: String) {
        directLaunchScreen = screenName
    }
}