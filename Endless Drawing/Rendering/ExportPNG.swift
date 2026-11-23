import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

/// Reads a completed export texture and encodes a straight-alpha PNG. Runs off the main actor: the
/// caller passes the already-committed command buffer and a shared-storage texture.
nonisolated enum ExportPNG {
    static func encode(texture: MTLTexture, command: MTLCommandBuffer, background: ExportBackground) throws -> Data {
        command.waitUntilCompleted()
        guard command.status == .completed else { throw MetalRenderer.Failure.command }
        let width = texture.width, height = texture.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { pointer in
            texture.getBytes(pointer.baseAddress!, bytesPerRow: width * 4,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        // The renderer stores premultiplied BGRA; PNG expects straight RGBA.
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let b = Int(pixels[index]), g = Int(pixels[index + 1])
            let r = Int(pixels[index + 2]), a = Int(pixels[index + 3])
            if background == .white || a == 0 {
                rgba[index] = UInt8(r); rgba[index + 1] = UInt8(g); rgba[index + 2] = UInt8(b); rgba[index + 3] = UInt8(a)
            } else {
                rgba[index] = UInt8(min(255, r * 255 / a))
                rgba[index + 1] = UInt8(min(255, g * 255 / a))
                rgba[index + 2] = UInt8(min(255, b * 255 / a))
                rgba[index + 3] = UInt8(a)
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw MetalRenderer.Failure.command
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw MetalRenderer.Failure.command
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw MetalRenderer.Failure.command }
        return output as Data
    }
}
