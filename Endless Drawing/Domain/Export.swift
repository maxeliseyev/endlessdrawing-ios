import Foundation

/// Whose strokes go into the PNG: ours (`own`) and/or other authors by v5+ tag.
nonisolated struct ExportSelection: Equatable, Sendable {
    var own: Bool
    var authors: [String]
    static let defaultSelection = ExportSelection(own: true, authors: [])
}

/// The stroke under an export tap: enough to toggle the selection (own or another author).
nonisolated struct ExportTarget: Equatable, Sendable {
    let own: Bool
    let author: String?
}

/// Result of an offscreen export render: the PNG and the exact frame/size it was rendered with.
nonisolated struct ExportRenderResult: Sendable {
    let png: Data
    let size: ExportSize
    let frame: ExportFrame
}

nonisolated enum ExportBackground: String, CaseIterable, Sendable {
    case transparent, white
}

/// Pixel scale choices, same as the web client.
nonisolated enum ExportScale: Int, CaseIterable, Sendable {
    case one = 1, two = 2, four = 4
}

/// A rectangle in world units; deliberately not `WireBounds` (no 30k span / world-limit validation).
nonisolated struct ExportFrame: Equatable, Sendable {
    var minX: Double, minY: Double, maxX: Double, maxY: Double
    var centerX: Double { (minX + maxX) / 2 }
    var centerY: Double { (minY + maxY) / 2 }
}

nonisolated struct ExportSize: Equatable, Sendable {
    var width: Int, height: Int
    var scale: Double
}

/// Pure, UI-free port of the web client's `src/export.ts` (PR #14). Rendering stays separate.
nonisolated enum Export {
    static let scales = [1, 2, 4]
    /// Safari/iPadOS refuse larger 2D canvases (area), every engine caps a side.
    static let maximumPixels = 16_777_216
    static let maximumSide = 16_384
    static let minimumMargin = 16.0
    static let marginShare = 0.04
    static let minimumFrame = 8.0

    /// A tap on our stroke toggles "mine"; on someone else's, toggles that author.
    static func toggleAuthor(_ selection: ExportSelection, own: Bool, author: String?) -> ExportSelection {
        if own { return ExportSelection(own: !selection.own, authors: selection.authors) }
        guard let author else { return selection } // pre-v5 profile: other authors cannot be told apart
        if selection.authors.contains(author) {
            return ExportSelection(own: selection.own, authors: selection.authors.filter { $0 != author })
        }
        return ExportSelection(own: selection.own, authors: selection.authors + [author])
    }

    static func isEmptySelection(_ selection: ExportSelection) -> Bool {
        !selection.own && selection.authors.isEmpty
    }

    static func includes(_ selection: ExportSelection, own: Bool, author: String?) -> Bool {
        if own { return selection.own }
        guard let author else { return false }
        return selection.authors.contains(author)
    }

    /// Selected strokes in canvas order: confirmed by seq, then our unacknowledged creates on top.
    static func selectStrokes(confirmed: [SceneStroke], pending: [LocalStroke], selection: ExportSelection,
                              isHidden: (SceneStroke) -> Bool) -> [LocalStroke] {
        var result = confirmed.compactMap { record -> LocalStroke? in
            guard !isHidden(record), includes(selection, own: record.server.own, author: record.server.author) else { return nil }
            return record.drawable
        }
        if selection.own { result.append(contentsOf: pending) }
        return result
    }

    /// The union of stroke extents (brush width included) plus a proportional margin.
    static func frameFor(_ strokes: [LocalStroke]) -> ExportFrame? {
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for stroke in strokes {
            guard !stroke.points.isEmpty else { continue }
            let e = StrokeExtent(stroke)
            minX = min(minX, e.minX); minY = min(minY, e.minY)
            maxX = max(maxX, e.maxX); maxY = max(maxY, e.maxY)
        }
        guard minX <= maxX else { return nil }
        let margin = max(minimumMargin, max(maxX - minX, maxY - minY) * marginShare)
        return ExportFrame(minX: minX - margin, minY: minY - margin, maxX: maxX + margin, maxY: maxY + margin)
    }

    /// Normalizes a frame dragged by its corners and keeps it from collapsing.
    static func normalizeFrame(a: WorldPoint, b: WorldPoint) -> ExportFrame {
        var minX = min(a.x, b.x), maxX = max(a.x, b.x)
        var minY = min(a.y, b.y), maxY = max(a.y, b.y)
        if maxX - minX < minimumFrame {
            let center = (minX + maxX) / 2
            minX = center - minimumFrame / 2; maxX = center + minimumFrame / 2
        }
        if maxY - minY < minimumFrame {
            let center = (minY + maxY) / 2
            minY = center - minimumFrame / 2; maxY = center + minimumFrame / 2
        }
        return ExportFrame(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    /// Pixel size for a frame; the scale is lowered as needed to stay within canvas limits.
    static func exportSize(frame: ExportFrame, requested: Int) -> ExportSize {
        let width = frame.maxX - frame.minX, height = frame.maxY - frame.minY
        let scale = min(Double(requested),
                        Double(maximumSide) / width,
                        Double(maximumSide) / height,
                        (Double(maximumPixels) / (width * height)).squareRoot())
        let pixelsWide = max(1, min(maximumSide, Int((width * scale).rounded(.down))))
        let pixelsHigh = max(1, min(maximumSide, Int((height * scale).rounded(.down))))
        return ExportSize(width: pixelsWide, height: pixelsHigh, scale: scale)
    }

    /// Strokes that touch the frame at all; parts outside are clipped by the render target.
    static func inFrame(_ strokes: [LocalStroke], frame: ExportFrame) -> [LocalStroke] {
        strokes.filter { stroke in
            guard !stroke.points.isEmpty else { return false }
            let e = StrokeExtent(stroke)
            return e.minX <= frame.maxX && e.maxX >= frame.minX && e.minY <= frame.maxY && e.maxY >= frame.minY
        }
    }

    /// Selection summary with EN/RU pluralization, mirroring the web client's `exportSummary`.
    static func summary(own: Bool, authorCount: Int, russian: Bool = Locale.current.language.languageCode?.identifier == "ru") -> String {
        if own && authorCount == 0 { return russian ? "Мои рисунки" : "My drawings" }
        if own { return russian ? "Мои рисунки + \(authorCount) \(authorNoun(authorCount, russian: russian))"
                                 : "My drawings + \(authorCount) \(authorNoun(authorCount, russian: false))" }
        if authorCount == 0 { return russian ? "Ничего не выбрано" : "Nothing selected" }
        return russian ? "\(authorCount) \(authorNoun(authorCount, russian: true))"
                       : "\(authorCount) \(authorNoun(authorCount, russian: false))"
    }

    static func authorNoun(_ count: Int, russian: Bool) -> String {
        guard russian else { return count == 1 ? "author" : "authors" }
        let mod10 = count % 10, mod100 = count % 100
        if mod10 == 1 && mod100 != 11 { return "автор" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "автора" }
        return "авторов"
    }

    /// `endless-drawing_<x>_<y>.png` from the frame centre in whole world units, ASCII minus, no −0.
    static func exportFileName(frame: ExportFrame) -> String {
        func integer(_ value: Double) -> String {
            let magnitude = abs(value).rounded()
            let digits = String(Int64(magnitude))
            return value < 0 && magnitude != 0 ? "-\(digits)" : digits
        }
        return "endless-drawing_\(integer(frame.centerX))_\(integer(frame.centerY)).png"
    }
}
