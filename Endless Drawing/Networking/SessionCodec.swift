import Foundation
import MessagePack

nonisolated enum TransportFailure: Error, Equatable, Sendable {
    case unexpectedProfile, incompatibleVersion, wrongMessageType, messageTooLarge, malformedMessage
    case notConnected, queueFull, timedOut, network

    var closeCode: Int {
        switch self {
        case .wrongMessageType: 1003
        case .messageTooLarge: 1009
        case .malformedMessage: 1007
        case .unexpectedProfile, .incompatibleVersion: 1002
        case .notConnected, .timedOut, .network: 1001
        case .queueFull: 1008
        }
    }
}

nonisolated enum TransportProfile: Sendable, Equatable {
    static let messagePackProtocol = "endless-drawing.msgpack.v2"
    static let manifestProtocol = "endless-drawing.msgpack.v3"
    static let priorityProtocol = "endless-drawing.msgpack.v4"
    static let safetyProtocol = "endless-drawing.msgpack.v5"
    static let compactProtocol = "endless-drawing.msgpack.v6"
    static let jsonProtocol = "endless-drawing.json.v1"
    /// v3 adds manifest + fetch (cached subscribe); v4 adds visible-first snapshots (`visible_bounds`);
    /// v5 adds per-viewer author tags and `stroke.report` (backend docs/protocol-v5-safety.md).
    case legacyJSONV1, jsonV1, messagePackV2, messagePackV3, messagePackV4, messagePackV5, messagePackV6

    var protocolVersion: Int {
        switch self {
        case .legacyJSONV1, .jsonV1: 1
        case .messagePackV2: 2
        case .messagePackV3: 3
        case .messagePackV4: 4
        case .messagePackV5: 5
        case .messagePackV6: 6
        }
    }
    var isMessagePack: Bool { protocolVersion >= 2 }
    var supportsManifest: Bool { protocolVersion >= 3 }
    var requiresVisibleBounds: Bool { protocolVersion >= 4 }
    var supportsReports: Bool { protocolVersion >= 5 }
    var maximumServerBytes: Int { isMessagePack ? 256 * 1024 : WireLimits.maximumServerBytes }
}

/// Explicit deployment policy, never a fallback after a failed negotiation.
nonisolated enum TransportPolicy: Sendable, Equatable {
    case negotiated, legacyJSONV1
    /// Preference order; the server picks the first one it has enabled.
    var offeredProtocols: [String] {
        self == .negotiated ? [TransportProfile.compactProtocol, TransportProfile.safetyProtocol, TransportProfile.priorityProtocol, TransportProfile.manifestProtocol,
                               TransportProfile.messagePackProtocol, TransportProfile.jsonProtocol] : []
    }
    func selected(_ value: String?) throws -> TransportProfile {
        if self == .legacyJSONV1 {
            guard value == nil || value == "" else { throw TransportFailure.unexpectedProfile }
            return .legacyJSONV1
        }
        switch value {
        case TransportProfile.compactProtocol: return .messagePackV6
        case TransportProfile.safetyProtocol: return .messagePackV5
        case TransportProfile.priorityProtocol: return .messagePackV4
        case TransportProfile.manifestProtocol: return .messagePackV3
        case TransportProfile.messagePackProtocol: return .messagePackV2
        case TransportProfile.jsonProtocol: return .jsonV1
        default: throw TransportFailure.unexpectedProfile
        }
    }
}

nonisolated enum WebSocketPacket: Sendable, Equatable {
    case text(String), binary(Data)
    var byteCount: Int {
        switch self { case .text(let text): text.utf8.count; case .binary(let data): data.count }
    }
}

/// Codec and protocol version are immutable for one connection generation.
nonisolated struct SessionCodec: Sendable {
    let profile: TransportProfile

    func encode(_ message: ClientMessage) throws -> WebSocketPacket {
        // Profile shape is a caller contract, never silently adapted on the wire.
        switch message {
        case .subscribe(_, _, let visible), .subscribeCached(_, _, let visible):
            guard (visible != nil) == profile.requiresVisibleBounds else { throw TransportFailure.malformedMessage }
            if case .subscribeCached = message, !profile.supportsManifest { throw TransportFailure.malformedMessage }
        case .fetch:
            guard profile.supportsManifest else { throw TransportFailure.malformedMessage }
        case .report:
            guard profile.supportsReports else { throw TransportFailure.malformedMessage }
        default: break
        }
        do {
            if profile.isMessagePack {
                return .binary(try BoundedMessagePack.encode(message, maximumBytes: WireLimits.maximumClientBytes))
            }
            return .text(String(decoding: try message.jsonData(), as: UTF8.self))
        } catch let failure as TransportFailure { throw failure }
        catch DrawingDataError.limitExceeded { throw TransportFailure.messageTooLarge }
        catch { throw TransportFailure.malformedMessage }
    }

    func decode(_ packet: WebSocketPacket) throws -> ServerMessage {
        switch packet {
        case .binary: guard profile.isMessagePack else { throw TransportFailure.wrongMessageType }
        case .text: guard !profile.isMessagePack else { throw TransportFailure.wrongMessageType }
        }
        guard packet.byteCount <= profile.maximumServerBytes else { throw TransportFailure.messageTooLarge }
        do {
            switch packet {
            case .binary(let bytes):
                return try BoundedMessagePack.decode(ServerMessage.self, from: bytes, protocolVersion: profile.protocolVersion)
            case .text(let text):
                return try ServerMessage.decode(Data(text.utf8))
            }
        } catch let failure as TransportFailure { throw failure }
        catch DrawingDataError.unsupportedProtocol { throw TransportFailure.incompatibleVersion }
        catch { throw TransportFailure.malformedMessage }
    }
}

/// The external library never sees unvalidated binary input. No JSON intermediate or byte sniffing.
nonisolated enum BoundedMessagePack {
    static func encode<T: Encodable>(_ value: T, maximumBytes: Int = WireLimits.maximumClientBytes) throws -> Data {
        let data: Data
        do { data = try MessagePackEncoder().encode(value) }
        catch { throw TransportFailure.malformedMessage }
        return try MessagePackPreflight.normalizeEncoderOutput(data, maximumBytes: maximumBytes)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data, protocolVersion: Int = 2) throws -> T {
        try MessagePackPreflight.validate(data, compact: protocolVersion >= 6)
        var decoder = MessagePackDecoder()
        decoder.userInfo[WireDecodingContext.protocolVersion] = protocolVersion
        return try decoder.decode(type, from: data)
    }
}
