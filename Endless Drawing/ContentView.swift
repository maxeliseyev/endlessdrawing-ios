import SwiftUI

struct ContentView: View {
    @State private var model: CanvasModel
    /// Measured palette size, so the anchor clamp uses the real height rather than a fixed guess.
    @State private var paletteSize = CGSize(width: 320, height: 440)
    /// Live finger translation while the palette is dragged by its header; committed to the anchor on end.
    @GestureState private var paletteDrag = CGSize.zero

    init(model: CanvasModel = CanvasModel()) { _model = State(initialValue: model) }

    var body: some View {
        ZStack {
            CanvasRepresentable(model: model).ignoresSafeArea()
            if let anchor = model.paletteAnchor {
                GeometryReader { geometry in
                    let layout = PaletteLayout(area: geometry.size, paletteHeight: paletteSize.height)
                    let insets = CGPoint(x: geometry.safeAreaInsets.leading, y: geometry.safeAreaInsets.top)
                    // Where the palette rests now, before any drag: the stored anchor clamped on screen.
                    let resting = layout.center(for: CGPoint(x: anchor.x - insets.x, y: anchor.y - insets.y))
                    let shown = layout.center(for: CGPoint(x: resting.x + paletteDrag.width, y: resting.y + paletteDrag.height))
                    let move = DragGesture(minimumDistance: 4, coordinateSpace: .global)
                        .updating($paletteDrag) { value, state, _ in state = value.translation }
                        .onEnded { value in
                            let end = layout.center(for: CGPoint(x: resting.x + value.translation.width,
                                                                 y: resting.y + value.translation.height))
                            model.paletteAnchor = CGPoint(x: end.x + insets.x, y: end.y + insets.y)
                        }
                    Color.clear.contentShape(Rectangle()).ignoresSafeArea()
                        .onTapGesture { model.paletteAnchor = nil }
                    ContextPalette(model: model, move: AnyGesture(move.map { _ in }))
                        .frame(width: layout.width)
                        .frame(maxHeight: layout.maxHeight)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { paletteSize = $0 }
                        .position(shown)
                }
            }
        }
        .overlay(alignment: .top) {
            if model.reporting { ReportBar(model: model).padding(.top, 12) }
            if model.exporting { ExportBar(model: model).padding(.top, 12) }
        }
        .overlay(alignment: .bottomLeading) {
            Text(model.centerCoordinates)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(Color(red: 118.0 / 255.0, green: 118.0 / 255.0, blue: 118.0 / 255.0))
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityLabel(Text("Canvas center coordinates"))
                .accessibilityAddTraits(.isStaticText)
                .allowsHitTesting(false)
                .padding(.leading, 12)
                .padding(.bottom, 12)
        }
        .overlay(alignment: .bottom) {
            if model.exporting { ExportPanel(model: model).padding(.horizontal, 16).padding(.bottom, 12) }
            if let notice = model.notice {
                NoticeToast(text: notice).padding(.bottom, 24)
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(3))
                        if model.notice == notice { model.notice = nil }
                    }
            }
        }
        .sheet(isPresented: $model.termsPrompt) { TermsSheet(model: model) }
        .sheet(isPresented: $model.reportSheet) { ReportSheet(model: model) }
        .sheet(isPresented: $model.showExportShare) {
            if let url = model.exportShareURL, let png = model.exportSharePNG {
                ShareSheet(url: url, png: png)
            }
        }
        .preferredColorScheme(.light)
        .alert("Canvas unavailable", isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })) {
            Button("Retry") { model.failure = nil; model.command?(.retry) }
            Button("Close", role: .cancel) { model.failure = nil }
        } message: { Text(model.failure ?? "") }
    }
}

/// Palette size and on-screen clamping inside the safe area, with a 16 pt margin.
struct PaletteLayout: Equatable {
    static let margin: CGFloat = 16
    let width: CGFloat
    let maxHeight: CGFloat
    let height: CGFloat
    let area: CGSize

    init(area: CGSize, paletteHeight: CGFloat) {
        self.area = area
        width = min(320, max(1, area.width - 2 * Self.margin))
        maxHeight = max(1, area.height - 2 * Self.margin)
        height = min(paletteHeight, maxHeight)
    }

    /// Centre for a requested point, keeping the whole palette on screen.
    func center(for point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, width / 2 + Self.margin), area.width - width / 2 - Self.margin),
                y: min(max(point.y, height / 2 + Self.margin), area.height - height / 2 - Self.margin))
    }
}

#Preview { ContentView() }
