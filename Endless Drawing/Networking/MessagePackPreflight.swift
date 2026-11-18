import Foundation

/// Runs before the library decoder allocates containers or coerces numeric types.
nonisolated enum MessagePackPreflight {
    static func validate(_ data: Data, maximumBytes: Int = 256 * 1024) throws {
        guard data.count <= maximumBytes else { throw TransportFailure.messageTooLarge }
        try data.withUnsafeBytes { bytes in
            guard let first = bytes.first, (0x80...0x8f).contains(first) || first == 0xde || first == 0xdf else {
                throw TransportFailure.malformedMessage
            }
            var scanner = Scanner(bytes: bytes, maximumBytes: maximumBytes)
            try scanner.read(depth: 0)
            guard scanner.offset == bytes.count else { throw TransportFailure.malformedMessage }
        }
    }

    /// msgpack-swift 2.0.6 losslessly shortens exact Double values to float32. Expand only trusted
    /// encoder output back to float64; received float32 remains forbidden. This is not an encoder.
    static func normalizeEncoderOutput(_ data: Data, maximumBytes: Int) throws -> Data {
        guard data.count <= maximumBytes else { throw TransportFailure.messageTooLarge }
        return try data.withUnsafeBytes { bytes in
            guard let first = bytes.first, (0x80...0x8f).contains(first) || first == 0xde || first == 0xdf else {
                throw TransportFailure.malformedMessage
            }
            var scanner = Scanner(bytes: bytes, maximumBytes: maximumBytes, normalizeFloats: true)
            try scanner.read(depth: 0)
            guard scanner.offset == bytes.count else { throw TransportFailure.malformedMessage }
            guard var output = scanner.output else { return data }
            output.append(contentsOf: bytes[scanner.copiedThrough..<bytes.count])
            return output
        }
    }

    private struct Scanner {
        let bytes: UnsafeRawBufferPointer
        let maximumBytes: Int
        var normalizeFloats = false
        var offset = 0
        var nodes = 0
        var copiedThrough = 0
        var output: Data?
        var expansion = 0

        mutating func take(_ count: Int) throws -> Int {
            guard count >= 0, count <= bytes.count - offset else { throw TransportFailure.malformedMessage }
            let start = offset
            offset += count
            return start
        }

        mutating func integer(bytes count: Int) throws -> UInt64 {
            let start = try take(count)
            var value: UInt64 = 0
            for index in start..<(start + count) { value = (value << 8) | UInt64(bytes[index]) }
            return value
        }

        @discardableResult
        mutating func read(depth: Int, isKey: Bool = false) throws -> String? {
            nodes += 1
            guard nodes <= 65_536 else { throw TransportFailure.malformedMessage }
            let tag = bytes[try take(1)]
            let stringLength: Int?
            switch tag {
            case 0xa0...0xbf: stringLength = Int(tag & 31)
            case 0xd9: stringLength = Int(try integer(bytes: 1))
            case 0xda: stringLength = Int(try integer(bytes: 2))
            case 0xdb: stringLength = Int(try integer(bytes: 4))
            default: stringLength = nil
            }
            if let count = stringLength {
                guard count <= 256 else { throw TransportFailure.malformedMessage }
                let start = try take(count)
                guard let text = String(bytes: bytes[start..<(start + count)], encoding: .utf8) else {
                    throw TransportFailure.malformedMessage
                }
                return text
            }
            guard !isKey else { throw TransportFailure.malformedMessage }
            switch tag {
            case 0x00...0x7f, 0xe0...0xff, 0xc2, 0xc3: return nil
            case 0xcc, 0xd0: _ = try take(1); return nil
            case 0xcd, 0xd1: _ = try take(2); return nil
            case 0xce, 0xd2: _ = try take(4); return nil
            case 0xcf:
                guard try integer(bytes: 8) <= UInt64(WireLimits.maximumSequence) else { throw TransportFailure.malformedMessage }
                return nil
            case 0xd3:
                let value = Int64(bitPattern: try integer(bytes: 8))
                guard value >= -WireLimits.maximumSequence, value <= WireLimits.maximumSequence else { throw TransportFailure.malformedMessage }
                return nil
            case 0xca where normalizeFloats:
                let start = offset - 1
                let value = Float(bitPattern: UInt32(try integer(bytes: 4)))
                guard value.isFinite else { throw TransportFailure.malformedMessage }
                expansion += 4
                guard bytes.count + expansion <= maximumBytes else { throw TransportFailure.messageTooLarge }
                if output == nil { output = Data() }
                output?.append(contentsOf: bytes[copiedThrough..<start])
                output?.append(0xcb)
                let bits = Double(value).bitPattern
                for shift in stride(from: 56, through: 0, by: -8) { output?.append(UInt8(truncatingIfNeeded: bits >> shift)) }
                copiedThrough = offset
                return nil
            case 0xcb:
                guard Double(bitPattern: try integer(bytes: 8)).isFinite else { throw TransportFailure.malformedMessage }
                return nil
            default: break
            }
            let count: Int
            let map: Bool
            switch tag {
            case 0x80...0x8f: count = Int(tag & 15); map = true
            case 0x90...0x9f: count = Int(tag & 15); map = false
            case 0xdc, 0xdd: count = Int(try integer(bytes: tag == 0xdc ? 2 : 4)); map = false
            case 0xde, 0xdf: count = Int(try integer(bytes: tag == 0xde ? 2 : 4)); map = true
            default: throw TransportFailure.malformedMessage // nil, float32, binary, extensions and reserved tags
            }
            guard depth < 8, count <= (map ? 16 : 2000), count * (map ? 2 : 1) <= bytes.count - offset else {
                throw TransportFailure.malformedMessage
            }
            if map {
                var keys: Set<String> = []
                for _ in 0..<count {
                    guard let key = try read(depth: depth + 1, isKey: true),
                          !["__proto__", "prototype", "constructor"].contains(key), keys.insert(key).inserted else {
                        throw TransportFailure.malformedMessage
                    }
                    try read(depth: depth + 1)
                }
            } else {
                for _ in 0..<count { try read(depth: depth + 1) }
            }
            return nil
        }
    }
}
