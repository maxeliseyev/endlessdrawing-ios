import SwiftUI
import UIKit

/// Export mode banner: taps toggle authors, fingers/Pencil still move the canvas.
struct ExportBar: View {
    @Bindable var model: CanvasModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.down").foregroundStyle(.secondary).accessibilityHidden(true)
            Text(model.exportSummary).monospacedDigit().lineLimit(1)
            Spacer()
            Button { model.exporting = false } label: { Image(systemName: "xmark") }
                .accessibilityLabel(Text("Close"))
                .frame(minWidth: 44, minHeight: 44)
        }
        .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        .accessibilityAction(.escape) { model.exporting = false }
    }
}

/// Bottom panel: a live preview of exactly what goes into the file, plus scale, background and save.
struct ExportPanel: View {
    @Bindable var model: CanvasModel
    @State private var preview: UIImage?
    @State private var pixelText = ""

    private var previewKey: String {
        "\(model.exportSelection.own)|\(model.exportSelection.authors.count)|\(model.exportScale.rawValue)|\(model.exportBackground.rawValue)"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Group {
                if let preview {
                    Image(uiImage: preview).resizable().scaledToFit()
                } else {
                    ProgressView()
                }
            }
            .frame(width: 112, height: 112)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.black.opacity(0.12)))

            VStack(alignment: .leading, spacing: 8) {
                Text(model.exportSummary).font(.headline).lineLimit(1)
                Picker("Scale", selection: $model.exportScale) {
                    Text("1×").tag(ExportScale.one)
                    Text("2×").tag(ExportScale.two)
                    Text("4×").tag(ExportScale.four)
                }.pickerStyle(.segmented)
                Picker("Background", selection: $model.exportBackground) {
                    Text("Transparent").tag(ExportBackground.transparent)
                    Text("White").tag(ExportBackground.white)
                }.pickerStyle(.segmented)
                if !pixelText.isEmpty {
                    Text("\(pixelText) px").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                HStack {
                    Button("By drawings") { model.exportFrame = nil }
                        .disabled(model.exportFrame == nil)
                    Spacer()
                    Button { save() } label: {
                        Label("Save", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.exportBusy)
                }
                Text("Only drawings loaded around the view")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 4)
        .task(id: previewKey) { await refreshPreview() }
        .accessibilityAction(.escape) { model.exporting = false }
    }

    private func refreshPreview() async {
        model.exportBusy = true
        defer { model.exportBusy = false }
        guard let result = try? await model.renderExport() else { return }
        preview = UIImage(data: result.png)
        pixelText = "\(result.size.width) × \(result.size.height)"
    }

    private func save() {
        Task {
            model.exportBusy = true
            defer { model.exportBusy = false }
            guard let result = try? await model.renderExport() else { return }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(Export.exportFileName(frame: result.frame))
            try? result.png.write(to: url, options: .atomic)
            model.exportShareURL = url
            model.exportSharePNG = result.png
            model.showExportShare = true
        }
    }
}

/// Wraps `UIActivityViewController` so the PNG can go to Photos (image) and Files (file URL).
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    let png: Data

    func makeUIViewController(context: Context) -> UIActivityViewController {
        var items: [Any] = [url]
        if let image = UIImage(data: png) { items.append(image) }
        return UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
