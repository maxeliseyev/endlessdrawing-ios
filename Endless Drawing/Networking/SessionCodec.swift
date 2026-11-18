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
    static let jsonProtocol = "endless-drawing.json.v1"
    case legacyJSONV1, jsonV1, messagePackV2

    var protocolVersion: Int { self == .messagePackV2 ? 2 : 1 }
    var maximumServerBytes: Int { self == .messagePackV2 ? 256 * 1024 : WireLimits.maximumServerBytes }
}

/// Explicit deployment policy, never a fallback after a failed negotiation.
nonisolated enum TransportPolicy: Sendable, Equatable {
    case negotiated, legacyJSONV1
    var offeredProtocols: [String] {
        self == .negotiated ? [TransportProfile.messagePackProtocol, TransportProfile.jsonProtocol] : []
    }
    func selected(_ value: String?) throws -> TransportProfile {
        if self == .legacyJSONV1 {
            guard value == nil || value == "" else { throw TransportFailure.unexpectedProfile }
            return .legacyJSONV1
        }
        switch value {
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
        do {
            if profile == .messagePackV2 {
                return .binary(try BoundedMessagePack.encode(message, maximumBytes: WireLimits.maximumClientBytes))
            }
            return .text(String(decoding: try message.jsonData(), as: UTF8.self))
        } catch let failure as TransportFailure { throw failure }
        catch DrawingDataError.limitExceeded { throw TransportFailure.messageTooLarge }
        catch { throw TransportFailure.malformedMessage }
    }

    func decode(_ packet: WebSocketPacket) throws -> ServerMessage {
        switch (profile, packet) {
        case (.messagePackV2, .binary), (.jsonV1, .text), (.legacyJSONV1, .text): break
        default: throw TransportFailure.wrongMessageType
        }
        guard packet.byteCount <= profile.maximumServerBytes else { throw TransportFailure.messageTooLarge }
        do {
            switch (profile, packet) {
            case (.messagePackV2, .binary(let bytes)):
                return try BoundedMessagePack.decode(ServerMessage.self, from: bytes, protocolVersion: 2)
            case (.legacyJSONV1, .text(let text)), (.jsonV1, .text(let text)):
                return try ServerMessage.decode(Data(text.utf8))
            default: throw TransportFailure.wrongMessageType
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
        try MessagePackPreflight.validate(data)
        var decoder = MessagePackDecoder()
        decoder.userInfo[WireDecodingContext.protocolVersion] = protocolVersion
        return try decoder.decode(type, from: data)
    }
}
