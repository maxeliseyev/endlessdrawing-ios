// macOS harness for the Metal renderer on a real Apple GPU. The iOS Simulator has no framebuffer
// fetch, so the single-pass ink path only runs on devices; Apple silicon Macs share the GPU family.
// Usage: tools/render-harness/run.sh  (prints probes, single-pass vs legacy equivalence, pan cost).
import Metal
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
import QuartzCore

func scene(count: Int, seed: UInt64 = 7, spread: Double = 1600, offset: Double = 0) -> [LocalStroke] {
    var state = seed
    func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double(z ^ (z >> 31)) / Double(UInt64.max)
    }
    return (0..<count).map { index in
        var style = BrushStyle()
        let kind = next()
        style.brush = kind < 0.7 ? .round : kind < 0.8 ? .square : kind < 0.9 ? .chisel : .spray
        style.width = 4 + next() * 20
        style.opacity = next() < 0.3 ? 0.5 : 1
        style.color = InkColor.palette[index % InkColor.palette.count]
        var x = offset + (next() - 0.5) * spread, y = -offset + (next() - 0.5) * spread * 0.7
        var angle = next() * .pi * 2
        let points = (0..<64).map { _ -> WorldPoint in
            angle += (next() - 0.5) * 0.6
            x += cos(angle) * 6; y += sin(angle) * 6
            return WorldPoint(x: x, y: y)
        }
        return LocalStroke(id: UUID(), points: points, style: style)
    }
}

@MainActor func target(_ device: MTLDevice, _ w: Int, _ h: Int, shared: Bool) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]; d.storageMode = shared ? .shared : .private
    return device.makeTexture(descriptor: d)!
}

@MainActor func frame(_ r: MetalRenderer, _ t: MTLTexture, _ v: CanvasSize) -> (Double, Double, Double) {
    let start = CACurrentMediaTime()
    let c = r.queue.makeCommandBuffer()!
    try! r.encode(to: t, viewport: v, command: c)
    let enc = CACurrentMediaTime()
    c.commit(); c.waitUntilCompleted()
    precondition(c.status == .completed, "\(String(describing: c.error))")
    return ((CACurrentMediaTime() - start) * 1000, (enc - start) * 1000, (c.gpuEndTime - c.gpuStartTime) * 1000)
}

@MainActor func pixels(_ t: MTLTexture) -> [UInt8] {
    var p = [UInt8](repeating: 0, count: t.width * t.height * 4)
    p.withUnsafeMutableBytes { t.getBytes($0.baseAddress!, bytesPerRow: t.width * 4, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0) }
    return p
}

func png(_ bgra: [UInt8], _ w: Int, _ name: String) {
    var rgba = bgra
    for i in stride(from: 0, to: rgba.count, by: 4) { rgba.swapAt(i, i + 2) }
    let ctx = CGContext(data: &rgba, width: w, height: w, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
}

@MainActor func equivalence(_ device: MTLDevice) -> Bool {
    var ok = true
    let cases: [(String, Double, Int, Int, Double)] = [("zoom0.08", 0.08, 80, 256, 0), ("zoom1", 1, 300, 512, 0),
                                                        ("zoom4", 4, 60, 512, 0), ("far1e9", 1, 120, 512, 999_999_000)]
    for (name, zoom, count, size, offset) in cases {
        let v = CanvasSize(width: Double(size), height: Double(size))
        var camera = Camera()
        camera.pan(screenDelta: WorldPoint(x: -offset, y: offset))
        camera.zoom(to: zoom, anchor: WorldPoint(x: Double(size) / 2, y: Double(size) / 2), viewport: v)
        let strokes = scene(count: count, spread: zoom < 1 ? 1600 : 400 / zoom, offset: offset)
        var out: [[UInt8]] = []
        for single in [true, false] {
            let r = try! MetalRenderer(device: device, singlePassInk: single)
            precondition(r.usesSinglePassInk == single, r.singlePassUnavailableReason ?? "")
            r.camera = camera
            r.strokes = strokes.dropLast().map { try! r.upload(BrushGeometry.prepare($0)!) }
            r.preview = try! r.upload(BrushGeometry.prepare(strokes.last!)!)
            let t = target(device, size * 2, size * 2, shared: true)
            _ = frame(r, t, v)
            out.append(pixels(t))
        }
        let diff = zip(out[0], out[1]).map { abs(Int($0) - Int($1)) }
        var marked = out[1]
        var bad: [(Int, Int)] = []
        for i in stride(from: 0, to: diff.count, by: 4) where diff[i] > 1 || diff[i+1] > 1 || diff[i+2] > 1 {
            marked[i] = 0; marked[i+1] = 0; marked[i+2] = 255; bad.append(((i / 4) % (size * 2), (i / 4) / (size * 2)))
        }
        if let first = bad.first {
            let (bx, by) = first, w = size * 2
            print("DIFF \(name) first at \(bx),\(by) single=\(out[0][(by*w+bx)*4..<(by*w+bx)*4+3].map{$0}) legacy=\(out[1][(by*w+bx)*4..<(by*w+bx)*4+3].map{$0})")
        }
        let maxDiff = diff.max() ?? 0, over1 = diff.filter { $0 > 1 }.count
        let inked = out[1].filter { $0 < 200 }.count
        let pass = over1 <= diff.count / 400 && inked > 0
        ok = ok && pass
        if !pass {
            png(out[0], size * 2, "\(name)-single.png"); png(out[1], size * 2, "\(name)-legacy.png")
            png(marked, size * 2, "\(name)-diff.png")
        }
        print("EQUIV \(name) max=\(maxDiff) >1:\(over1)/\(diff.count) inked=\(inked) \(pass ? "OK" : "FAIL")")
    }
    return ok
}

/// Tile cache transitions on the single-pass path must equal a fresh render of the final scene.
@MainActor func tileTransitions(_ device: MTLDevice) -> Bool {
    let v = CanvasSize(width: 256, height: 256)
    func stroke(_ r: MetalRenderer, _ points: [WorldPoint], _ color: Int, _ seq: Int64) -> MetalRenderer.GPUStroke {
        var style = BrushStyle(); style.width = 12; style.opacity = 0.5; style.color = InkColor.palette[color]
        var g = try! r.upload(BrushGeometry.prepare(LocalStroke(id: UUID(), points: points, style: style))!)
        g.sequence = seq; return g
    }
    func render(_ r: MetalRenderer) -> [UInt8] { let t = target(device, 512, 512, shared: true); _ = frame(r, t, v); return pixels(t) }
    let r = try! MetalRenderer(device: device)
    let a = stroke(r, [WorldPoint(x: -60, y: 0), WorldPoint(x: 60, y: 0)], 0, 5)
    let b = stroke(r, [WorldPoint(x: 0, y: -60), WorldPoint(x: 0, y: 60)], 1, 9)
    let late = stroke(r, [WorldPoint(x: -50, y: -50), WorldPoint(x: 50, y: 50)], 2, 7)
    var ok = true
    func check(_ name: String, _ scene: [MetalRenderer.GPUStroke], _ expectAppend: Bool = false) {
        let appendedBefore = r.tileStats.appended
        r.strokes = scene
        let got = render(r)
        let fresh = try! MetalRenderer(device: device); fresh.strokes = scene
        let pass = got == render(fresh) && (!expectAppend || r.tileStats.appended > appendedBefore)
        ok = ok && pass
        print("TILES \(name) \(pass ? "OK" : "FAIL")")
    }
    check("initial", [a])
    check("append", [a, b], true)
    check("olderInsert", [a, late, b])
    check("remove", [a, b])
    for _ in 0..<5 { r.camera.pan(screenDelta: WorldPoint(x: 37, y: -11)); _ = render(r) }
    let built = r.tileStats.built
    r.camera.pan(screenDelta: WorldPoint(x: 3, y: 2)); _ = render(r)
    print("TILES panReuse \(r.tileStats.built == built ? "OK" : "FAIL")")
    return ok && r.tileStats.built == built
}

@MainActor func bench(_ device: MTLDevice, single: Bool) {
    let v = CanvasSize(width: 1210, height: 834)
    func ms(_ f: (Double, Double, Double)) -> String { String(format: "%.2f(cpu %.2f/gpu %.2f)", f.0, f.1, f.2) }
    for count in [250, 1000, 2000] {
        let r = try! MetalRenderer(device: device, singlePassInk: single)
        r.strokes = scene(count: count).map { try! r.upload(BrushGeometry.prepare($0)!) }
        let t = target(device, 2420, 1668, shared: false)
        let first = frame(r, t, v)
        var idle = frame(r, t, v)
        for _ in 0..<20 { idle = frame(r, t, v) } // let ring prefetch finish
        func average(_ n: Int, _ change: () -> Void) -> (Double, Double, Double) {
            var sum = (0.0, 0.0, 0.0)
            for _ in 0..<n { change(); let f = frame(r, t, v); sum = (sum.0 + f.0, sum.1 + f.1, sum.2 + f.2) }
            return (sum.0 / Double(n), sum.1 / Double(n), sum.2 / Double(n))
        }
        let pan = average(20) { r.camera.pan(screenDelta: WorldPoint(x: 10, y: 0)) }
        let zoom = average(10) { r.camera.zoom(to: r.camera.zoom * 1.02, anchor: WorldPoint(x: 605, y: 417), viewport: v) }
        let extra = try! r.upload(BrushGeometry.prepare(scene(count: 1, seed: 99)[0])!)
        let add = average(1) { r.strokes.append(extra) }
        let remove = average(1) { r.strokes.remove(at: count / 2) }
        print("BENCH \(single ? "single" : "legacy") n=\(count) first=\(ms(first)) idle=\(ms(idle)) pan=\(ms(pan)) zoom=\(ms(zoom)) add=\(ms(add)) remove=\(ms(remove))")
    }
}

MainActor.assumeIsolated {
    let device = MTLCreateSystemDefaultDevice()!
    print("GPU \(device.name)")
    for single in [true, false] {
        for (label, points) in [("dot", [WorldPoint.zero]), ("line", [WorldPoint(x: -40, y: 0), WorldPoint(x: 40, y: 0)])] {
            let r = try! MetalRenderer(device: device, singlePassInk: single)
            var style = BrushStyle(); style.opacity = 0.5; style.width = 12
            r.strokes = [try! r.upload(RoundGeometry.prepare(LocalStroke(id: UUID(), points: points, style: style))!)]
            let t = target(device, 128, 128, shared: true)
            _ = frame(r, t, CanvasSize(width: 128, height: 128))
            let p = pixels(t)
            let row = stride(from: 40, to: 90, by: 4).map { String(p[(64 * 128 + $0) * 4]) }.joined(separator: " ")
            print("PROBE \(single ? "single" : "legacy") \(label): \(row)")
        }
    }
    let ok = equivalence(device) && tileTransitions(device)
    bench(device, single: false)
    bench(device, single: true)
    exit(ok ? 0 : 1)
}
