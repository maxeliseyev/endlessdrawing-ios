import SwiftUI

struct ContextPalette: View {
    @Bindable var model: CanvasModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Brush").font(.headline)
                    Spacer()
                    Button { model.paletteAnchor = nil } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(Text("Close tools"))
                        .frame(minWidth: 44, minHeight: 44)
                }
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
                    ForEach(Array(InkColor.palette.enumerated()), id: \.offset) { _, ink in
                        Button { model.style.color = ink } label: {
                            Circle().fill(Color(red: Double(ink.red) / 255, green: Double(ink.green) / 255,
                                                blue: Double(ink.blue) / 255))
                                .frame(width: 28, height: 28)
                                .overlay(Circle().stroke(.primary, lineWidth: model.style.color == ink ? 2 : 0).padding(-3))
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .accessibilityLabel(Text(String(format: "#%02X%02X%02X", ink.red, ink.green, ink.blue)))
                        .accessibilityAddTraits(model.style.color == ink ? .isSelected : [])
                    }
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
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.black.opacity(0.12)))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 4)
        .accessibilityAction(.escape) { model.paletteAnchor = nil }
    }
}

//#Preview { ContextPalette() }
