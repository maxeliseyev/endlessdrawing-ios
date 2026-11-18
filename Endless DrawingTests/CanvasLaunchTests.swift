import MetalKit
import SwiftUI
import Testing
@testable import Endless_Drawing

@MainActor
struct CanvasLaunchTests {
    /// Run in Debug and Release: a build flag must not replace the prototype with a placeholder.
    @Test func rootContainsMetalCanvasInEveryBuildConfiguration() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: ContentView())
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        // SwiftUI commits its UIKit hierarchy on the run loop, not during loadView.
        for _ in 0..<50 {
            controller.view.layoutIfNeeded()
            if containsMetalView(controller.view) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(containsMetalView(controller.view))
    }

    private func containsMetalView(_ view: UIView) -> Bool {
        view is MTKView || view.subviews.contains(where: containsMetalView)
    }
}
