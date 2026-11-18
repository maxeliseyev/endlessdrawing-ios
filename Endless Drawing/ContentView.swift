import SwiftUI

struct ContentView: View {
    @State private var model: CanvasModel
    /// Measured palette size, so the anchor clamp uses the real height rather than a fixed guess.
    @State private var paletteSize = CGSize(width: 320, height: 440)

    init(model: CanvasModel = CanvasModel()) { _model = State(initialValue: model) }

    var body: some View {
        ZStack {
            CanvasRepresentable(model: model).ignoresSafeArea()
            if let anchor = model.paletteAnchor {
                GeometryReader { geometry in
                    let width = min(320, max(1, geometry.size.width - 32))
                    let maxHeight = max(1, geometry.size.height - 32)
                    let height = min(paletteSize.height, maxHeight)
                    let localAnchor = CGPoint(x: anchor.x - geometry.safeAreaInsets.leading,
                                              y: anchor.y - geometry.safeAreaInsets.top)
                    Color.clear.contentShape(Rectangle()).ignoresSafeArea()
                        .onTapGesture { model.paletteAnchor = nil }
                    ContextPalette(model: model)
                        .frame(width: width)
                        .frame(maxHeight: maxHeight)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { paletteSize = $0 }
                        .position(x: min(max(localAnchor.x, width / 2 + 16), geometry.size.width - width / 2 - 16),
                                  y: min(max(localAnchor.y, height / 2 + 16), geometry.size.height - height / 2 - 16))
                }
            }
        }
        .preferredColorScheme(.light)
        .alert("Canvas unavailable", isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })) {
            Button("Retry") { model.failure = nil; model.command?(.retry) }
            Button("Close", role: .cancel) { model.failure = nil }
        } message: { Text(model.failure ?? "") }
    }
}

#Preview { ContentView() }
