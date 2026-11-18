import SwiftUI

struct ContextPalette: View {
    @Bindable var model: CanvasModel
    /// Drag that moves the palette, attached to the header only so sliders and buttons keep their own gestures.
    var move: AnyGesture<Void>? = nil

    /// Natural height when it fits on screen; scrolls only when the screen is genuinely too short.
    var body: some View {
        ViewThatFits(in: .vertical) {
            tools
            ScrollView { tools }
        }
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.black.opacity(0.12)))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 4)
        .accessibilityAction(.escape) { model.paletteAnchor = nil }
    }

    /// Grabber + title: the handle for moving the palette with a finger or the Pencil.
    @ViewBuilder private var header: some View {
        let handle = VStack(spacing: 4) {
            Capsule().fill(.secondary.opacity(0.4)).frame(width: 36, height: 5)
                .accessibilityHidden(true)
            HStack {
                Text("Brush").font(.headline)
                Spacer()
                Button { model.paletteAnchor = nil } label: { Image(systemName: "xmark") }
                    .accessibilityLabel(Text("Close tools"))
                    .frame(minWidth: 44, minHeight: 44)
            }
        }
        .contentShape(Rectangle())
        if let move { handle.gesture(move) } else { handle }
    }

    private var customColor: Binding<CGColor> {
        Binding(get: { model.style.color.cgColor },
                set: { if let color = InkColor($0) { model.style.color = color } })
    }

    private func swatch(_ ink: InkColor) -> some View {
        Button { model.style.color = ink } label: {
            Circle().fill(Color(cgColor: ink.cgColor))
                .frame(width: 28, height: 28)
                .overlay(Circle().stroke(.black.opacity(0.15)))
                .overlay(Circle().stroke(.primary, lineWidth: model.style.color == ink ? 2 : 0).padding(-3))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .accessibilityLabel(Text(ink.hex))
        .accessibilityAddTraits(model.style.color == ink ? .isSelected : [])
    }

    private var tools: some View {
            VStack(alignment: .leading, spacing: 16) {
                header
                Text(model.statusText)
                    .font(.footnote).foregroundStyle(.secondary)
                if let state = model.worldState, state.pendingCount > 0 {
                    Text("Pending operations: \(state.pendingCount)").font(.footnote).foregroundStyle(.secondary)
                }
                if model.isShared {
                    Button("Retry") { model.command?(.retry) }.frame(minHeight: 44)
                }
                Picker("Brush", selection: $model.style.brush) {
                    Text("Round").tag(BrushKind.round)
                    Text("Square").tag(BrushKind.square)
                    Text("Chisel").tag(BrushKind.chisel)
                    Text("Spray").tag(BrushKind.spray)
                }.pickerStyle(.segmented)
                HStack(spacing: 0) {
                    ForEach(InkColor.palette, id: \.hex) { swatch($0) }
                    // System picker: grid, spectrum, sliders and the eyedropper that samples the screen.
                    ColorPicker(selection: customColor, supportsOpacity: false) { Text("Custom color") }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityLabel(Text("Custom color"))
                }
                if !model.recentColors.colors.isEmpty {
                    HStack(spacing: 0) {
                        ForEach(model.recentColors.colors, id: \.hex) { swatch($0) }
                        ForEach(model.recentColors.colors.count..<RecentColors.capacity, id: \.self) { _ in
                            // Fixed height: a bare Color is greedy and stretched the palette to the screen.
                            Color.clear.frame(maxWidth: .infinity).frame(height: 44)
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(Text("Recent colors"))
                }
                VStack(alignment: .leading) {
                    Text("Width")
                    Slider(value: $model.style.width, in: 1...64, step: 1).accessibilityLabel(Text("Width"))
                    Text(model.style.width.formatted(.number.precision(.fractionLength(0)))).font(.caption.monospacedDigit())
                }
                VStack(alignment: .leading) {
                    Text("Opacity")
                    Slider(value: $model.style.opacity, in: 0.05...1).accessibilityLabel(Text("Opacity"))
                    Text(model.style.opacity.formatted(.percent.precision(.fractionLength(0)))).font(.caption.monospacedDigit())
                }
                HStack {
                    Button("Undo", systemImage: "arrow.uturn.backward") { model.command?(.undo) }
                        .disabled(!model.canUndo)
                    Spacer()
                    Button("Reset view") { model.command?(.resetCamera) }
                }
                .frame(minHeight: 44)
            }
            .padding(20)
    }
}

//#Preview { ContextPalette() }
