import Foundation

nonisolated enum WireLimits {
    static let maximumClientBytes = 128 * 1024
    static let maximumServerBytes = 4 * 1024 * 1024
    static let maximumSequence: Int64 = 9_007_199_254_740_991

    static func identifier(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 128 else { throw DrawingDataError.invalidMessage }
        return value
    }

    static func sequence(_ value: Int64) throws -> Int64 {
        guard value > 0, value <= maximumSequence else { throw DrawingDataError.invalidMessage }
        return value
    }
}

nonisolated enum WireDecodingContext {
    static let protocolVersion = CodingUserInfoKey(rawValue: "endless-drawing.protocol-version")!
}

extension WorldPoint: Codable {
    nonisolated init(from decoder: Decoder) throws {
        var values = try decoder.unkeyedContainer()
        guard values.count == 2 else { throw DrawingDataError.invalidMessage }
        self.init(x: try values.decode(Double.self), y: try values.decode(Double.self))
        guard isValid, values.isAtEnd else { throw DrawingDataError.invalidMessage }
    }

    nonisolated func encode(to encoder: Encoder) throws {
        guard isValid else { throw DrawingDataError.invalidMessage }
        var values = encoder.unkeyedContainer()
        try values.encode(x)
        try values.encode(y)
    }
}

nonisolated enum BrushKind: String, Codable, Sendable { case round, square, chisel, spray }

/// Exact immutable create payload. Ownership and seq can never be encoded here.
nonisolated struct StrokePayload: Codable, Equatable, Sendable {
    let id: UUID
    let points: [WorldPoint]
    let brush: BrushKind
    let width: Double
    let color: String
    let opacity: Double

    init(id: UUID, points: [WorldPoint], brush: BrushKind, width: Double, color: String, opacity: Double) throws {
        guard !points.isEmpty, points.count <= StrokeInput.maximumPoints, points.allSatisfy(\.isValid),
              width.isFinite, (1...64).contains(width), opacity.isFinite, opacity > 0, opacity <= 1,
              color.utf8.count == 7, color.first == "#",
              color.dropFirst().utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw DrawingDataError.invalidMessage
        }
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for point in points {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        guard maxX - minX <= 100_000, maxY - minY <= 100_000 else { throw DrawingDataError.invalidMessage }
        self.id = id; self.points = points; self.brush = brush; self.width = width
        self.color = color.uppercased(); self.opacity = opacity
    }

    init(localRoundStroke stroke: LocalStroke) throws {
        guard stroke.style.brush == .round else { throw DrawingDataError.invalidMessage }
        try self.init(localStroke: stroke)
    }

    init(localStroke stroke: LocalStroke) throws {
        try self.init(id: stroke.id, points: stroke.points, brush: stroke.style.brush, width: stroke.style.width,
                      color: stroke.style.color.hex, opacity: stroke.style.opacity)
    }

    var drawable: LocalStroke {
        // color has already passed the exact #RRGGBB guard at construction/decode.
        LocalStroke(id: id, points: points, style: BrushStyle(brush: brush, width: width, opacity: opacity,
                                                            color: InkColor(hex: color)!))
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let id = try Self.uuid(values.decode(String.self, forKey: .id))
        var list = try values.nestedUnkeyedContainer(forKey: .points)
        guard let count = list.count, (1...StrokeInput.maximumPoints).contains(count) else { throw DrawingDataError.invalidMessage }
        var points: [WorldPoint] = []
        points.reserveCapacity(count)
        while !list.isAtEnd { points.append(try list.decode(WorldPoint.self)) }
        try self.init(id: id, points: points, brush: values.decode(BrushKind.self, forKey: .brush),
                      width: values.decode(Double.self, forKey: .width), color: values.decode(String.self, forKey: .color),
                      opacity: values.decode(Double.self, forKey: .opacity))
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id.uuidString.lowercased(), forKey: .id)
        try values.encode(points, forKey: .points)
        try values.encode(brush, forKey: .brush)
        try values.encode(width, forKey: .width)
        try values.encode(color, forKey: .color)
        try values.encode(opacity, forKey: .opacity)
    }

    static func uuid(_ text: String) throws -> UUID {
        guard text.utf8.count == 36, let id = UUID(uuidString: text),
              id.uuidString.lowercased() == text.lowercased() else { throw DrawingDataError.invalidMessage }
        return id
    }

    private enum CodingKeys: String, CodingKey { case id, points, brush, width, color, opacity }
}

nonisolated struct ServerStroke: Decodable, Equatable, Sendable {
    let payload: StrokePayload
    let sequence: Int64
    let own: Bool

    init(payload: StrokePayload, sequence: Int64, own: Bool) throws {
        self.payload = payload; self.sequence = try WireLimits.sequence(sequence); self.own = own
    }

    init(from decoder: Decoder) throws {
        payload = try StrokePayload(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sequence = try WireLimits.sequence(values.decode(Int64.self, forKey: .seq))
        own = try values.decode(Bool.self, forKey: .own)
    }

    private enum CodingKeys: String, CodingKey { case seq, own }
}

nonisolated struct WireBounds: Codable, Equatable, Sendable {
    let minX: Double, minY: Double, maxX: Double, maxY: Double
    init(minX: Double, minY: Double, maxX: Double, maxY: Double) throws {
        guard [minX, minY, maxX, maxY].allSatisfy({ $0.isFinite && abs($0) <= Camera.worldLimit }),
              minX < maxX, minY < maxY, maxX - minX <= 30_000, maxY - minY <= 30_000 else {
            throw DrawingDataError.invalidMessage
        }
        self.minX = minX; self.minY = minY; self.maxX = maxX; self.maxY = maxY
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(minX: values.decode(Double.self, forKey: .minX), minY: values.decode(Double.self, forKey: .minY),
                      maxX: values.decode(Double.self, forKey: .maxX), maxY: values.decode(Double.self, forKey: .maxY))
    }
    private enum CodingKeys: String, CodingKey {
        case minX = "min_x", minY = "min_y", maxX = "max_x", maxY = "max_y"
    }
}

nonisolated enum ClientMessage: Encodable, Sendable {
    case hello(SessionSecret)
    case subscribe(id: String, bounds: WireBounds)
    case create(requestID: String, stroke: StrokePayload)
    case delete(requestID: String, strokeID: UUID)

    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= WireLimits.maximumClientBytes else { throw DrawingDataError.limitExceeded }
        return data
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let secret):
            try values.encode("hello", forKey: .type)
            try values.encode(secret.base64URLValue, forKey: .sessionSecret)
        case .subscribe(let id, let bounds):
            try values.encode("viewport.subscribe", forKey: .type)
            try values.encode(WireLimits.identifier(id), forKey: .subscriptionID)
            try values.encode(bounds, forKey: .bounds)
        case .create(let requestID, let stroke):
            try values.encode("stroke.create", forKey: .type)
            try values.encode(WireLimits.identifier(requestID), forKey: .requestID)
            try values.encode(stroke, forKey: .stroke)
        case .delete(let requestID, let strokeID):
            try values.encode("stroke.delete", forKey: .type)
            try values.encode(WireLimits.identifier(requestID), forKey: .requestID)
            try values.encode(strokeID.uuidString.lowercased(), forKey: .strokeID)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, bounds, stroke
        case sessionSecret = "session_secret", subscriptionID = "subscription_id"
        case requestID = "request_id", strokeID = "stroke_id"
    }
}

nonisolated enum ServerMessage: Decodable, Equatable, Sendable {
    case hello(spawn: WorldPoint?)
    case snapshotBegin(id: String)
    case snapshotChunk(id: String, strokes: [ServerStroke])
    case snapshotEnd(id: String)
    case created(id: String, stroke: ServerStroke)
    case deleted(id: String, strokeID: UUID, sequence: Int64)
    case createAcknowledged(requestID: String, stroke: ServerStroke)
    case deleteAcknowledged(requestID: String, strokeID: UUID, sequence: Int64, alreadyDeleted: Bool)
    case error(requestID: String?, subscriptionID: String?, code: String)

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= WireLimits.maximumServerBytes else { throw DrawingDataError.limitExceeded }
        do { return try JSONDecoder().decode(Self.self, from: data) }
        catch let error as DrawingDataError { throw error }
        catch { throw DrawingDataError.invalidMessage }
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func id(_ key: CodingKeys) throws -> String { try WireLimits.identifier(values.decode(String.self, forKey: key)) }
        func strokeID() throws -> UUID { try StrokePayload.uuid(values.decode(String.self, forKey: .strokeID)) }
        func sequence() throws -> Int64 { try WireLimits.sequence(values.decode(Int64.self, forKey: .seq)) }
        switch try values.decode(String.self, forKey: .type) {
        case "hello.ack":
            let expectedVersion = decoder.userInfo[WireDecodingContext.protocolVersion] as? Int ?? 1
            guard try values.decode(Int.self, forKey: .protocolVersion) == expectedVersion else { throw DrawingDataError.unsupportedProtocol }
            var spawn: WorldPoint?
            if values.contains(.spawn) {
                let point = try values.nestedContainer(keyedBy: CodingKeys.self, forKey: .spawn)
                let candidate = WorldPoint(x: try point.decode(Double.self, forKey: .x), y: try point.decode(Double.self, forKey: .y))
                guard candidate.isValid else { throw DrawingDataError.invalidMessage }
                spawn = candidate
            }
            self = .hello(spawn: spawn)
        case "viewport.snapshot.begin": self = .snapshotBegin(id: try id(.subscriptionID))
        case "viewport.snapshot.end": self = .snapshotEnd(id: try id(.subscriptionID))
        case "viewport.snapshot.chunk":
            let subscriptionID = try id(.subscriptionID)
            var list = try values.nestedUnkeyedContainer(forKey: .strokes)
            guard let count = list.count, count <= 1000 else { throw DrawingDataError.limitExceeded }
            var strokes: [ServerStroke] = []
            strokes.reserveCapacity(count)
            let binary = decoder.userInfo[WireDecodingContext.protocolVersion] as? Int == 2
            var pointCount = 0
            while !list.isAtEnd {
                let stroke = try list.decode(ServerStroke.self)
                pointCount += stroke.payload.points.count
                guard !binary || pointCount <= 8192 else { throw DrawingDataError.limitExceeded }
                strokes.append(stroke)
            }
            self = .snapshotChunk(id: subscriptionID, strokes: strokes)
        case "stroke.created": self = .created(id: try id(.subscriptionID), stroke: try values.decode(ServerStroke.self, forKey: .stroke))
        case "stroke.deleted": self = .deleted(id: try id(.subscriptionID), strokeID: try strokeID(), sequence: try sequence())
        case "ack":
            let requestID = try id(.requestID)
            switch try values.decode(String.self, forKey: .operation) {
            case "stroke.create":
                let stroke = try values.decode(ServerStroke.self, forKey: .stroke)
                guard stroke.own else { throw DrawingDataError.invalidMessage }
                self = .createAcknowledged(requestID: requestID, stroke: stroke)
            case "stroke.delete":
                self = .deleteAcknowledged(requestID: requestID, strokeID: try strokeID(), sequence: try sequence(),
                                           alreadyDeleted: try values.decode(Bool.self, forKey: .alreadyDeleted))
            default: throw DrawingDataError.invalidMessage
            }
        case "error":
            self = .error(requestID: try values.decodeIfPresent(String.self, forKey: .requestID).map(WireLimits.identifier),
                          subscriptionID: try values.decodeIfPresent(String.self, forKey: .subscriptionID).map(WireLimits.identifier),
                          code: try id(.code))
        default: throw DrawingDataError.invalidMessage
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, spawn, x, y, strokes, stroke, seq, operation, code
        case protocolVersion = "protocol_version", subscriptionID = "subscription_id"
        case requestID = "request_id", strokeID = "stroke_id", alreadyDeleted = "already_deleted"
    }
}
