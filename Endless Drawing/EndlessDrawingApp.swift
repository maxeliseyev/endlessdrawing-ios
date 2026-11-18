//
//  EndlessDrawingApp.swift
//  Endless Drawing
//
//  Created by Maxim Eliseyev on 18.11.2026.
//

import SwiftUI

@main
struct EndlessDrawingApp: App {
    private static var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
            || NSClassFromString("XCTestCase") != nil
    }

    var body: some Scene {
        WindowGroup {
            // Unit-test hosts and previews must never connect to the public canvas implicitly.
            ContentView(model: CanvasModel(environment: Self.isTestHost ? nil : .live))
        }
    }
}
