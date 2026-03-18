// MetaGlassesClaudeApp.swift
// App entry point.

import SwiftUI

@main
struct MetaGlassesClaudeApp: App {
    @StateObject private var glassesManager = GlassesManager()

    var body: some Scene {
        WindowGroup {
            ContentView(glassesManager: glassesManager)
                .onOpenURL { url in
                    // Forward Meta AI OAuth deep-link back to the DAT SDK
                    Task { await glassesManager.handleOpenURL(url) }
                }
        }
    }
}
