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
        let compact = (decoder.userInfo[WireDecodingContext.protocolVersion] as? Int ?? 1) >= 6
        guard !values.contains(compact ? .points : .path) else { throw DrawingDataError.invalidMessage }
        var list = try values.nestedUnkeyedContainer(forKey: compact ? .path : .points)
        var points: [WorldPoint] = []
        if compact {
            guard let count = list.count, (2...StrokeInput.maximumPoints * 2).contains(count), count.isMultiple(of: 2) else {
                throw DrawingDataError.invalidMessage
            }
            points.reserveCapacity(count / 2)
            var x: Int64 = 0, y: Int64 = 0
            while !list.isAtEnd {
                let dx = try list.decode(Int64.self), dy = try list.decode(Int64.self)
                guard (-WireLimits.maximumSequence...WireLimits.maximumSequence).contains(dx),
                      (-WireLimits.maximumSequence...WireLimits.maximumSequence).contains(dy) else { throw DrawingDataError.invalidMessage }
                let nextX = x.addingReportingOverflow(dx), nextY = y.addingReportingOverflow(dy)
                guard !nextX.overflow, !nextY.overflow,
                      (-16_000_000_000...16_000_000_000).contains(nextX.partialValue),
                      (-16_000_000_000...16_000_000_000).contains(nextY.partialValue) else { throw DrawingDataError.invalidMessage }
                x = nextX.partialValue; y = nextY.partialValue
                points.append(WorldPoint(x: Double(x) / 16, y: Double(y) / 16))
            }
        } else {
            guard let count = list.count, (1...StrokeInput.maximumPoints).contains(count) else { throw DrawingDataError.invalidMessage }
            points.reserveCapacity(count)
            while !list.isAtEnd { points.append(try list.decode(WorldPoint.self)) }
        }
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

    /// A v6 ack contains independently rounded points, not the exact journal payload.
    func matchesAcknowledgement(_ other: StrokePayload, compact: Bool) -> Bool {
        guard compact else { return self == other }
        guard id == other.id, brush == other.brush, width == other.width, color == other.color,
              opacity == other.opacity, points.count == other.points.count else { return false }
        return zip(points, other.points).allSatisfy { original, acknowledged in
            (original.x * 16).rounded() / 16 == acknowledged.x && (original.y * 16).rounded() / 16 == acknowledged.y
        }
    }

    private enum CodingKeys: String, CodingKey { case id, points, path, brush, width, color, opacity }
}

nonisolated struct ServerStroke: Decodable, Equatable, Sendable {
    let payload: StrokePayload
    let sequence: Int64
    let own: Bool
    /// v5+: this viewer's tag for the author (22 base64url characters), for local blocking.
    let author: String?

    init(payload: StrokePayload, sequence: Int64, own: Bool, author: String? = nil) throws {
        self.payload = payload; self.sequence = try WireLimits.sequence(sequence); self.own = own
        self.author = try author.map(Self.authorTag)
    }

    init(from decoder: Decoder) throws {
        payload = try StrokePayload(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sequence = try WireLimits.sequence(values.decode(Int64.self, forKey: .seq))
        own = try values.decode(Bool.self, forKey: .own)
        // Required in v5, absent before: a profile mismatch is a protocol error, never guessed.
        let version = decoder.userInfo[WireDecodingContext.protocolVersion] as? Int ?? 1
        if version >= 5 { author = try Self.authorTag(values.decode(String.self, forKey: .author)) }
        else if values.contains(.author) { throw DrawingDataError.invalidMessage }
        else { author = nil }
    }

    static func authorTag(_ value: String) throws -> String {
        guard value.utf8.count == 22, value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
            || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { throw DrawingDataError.invalidMessage }
        return value
    }

    private enum CodingKeys: String, CodingKey { case seq, own, author }
}

/// v5 report reasons (backend docs/protocol-v5-safety.md).
nonisolated enum ReportReason: String, CaseIterable, Codable, Sendable {
    case sexual, violence, hate, illegal, spam, other
}

nonisolated struct WireBounds: Codable, Equatable, Sendable {
    /// Overlap of two rectangles (v4 hint = visible window ∩ subscription); nil when they do not overlap.
    func intersection(_ other: WireBounds) -> WireBounds? {
        try? WireBounds(minX: max(minX, other.minX), minY: max(minY, other.minY),
                        maxX: min(maxX, other.maxX), maxY: min(maxY, other.maxY))
    }

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
    /// `visible` is the v4 priority hint (required there, forbidden before v4; the codec enforces it).
    case subscribe(id: String, bounds: WireBounds, visible: WireBounds? = nil)
    /// v3+: manifest of authoritative membership, geometry fetched only for unknown ids.
    case subscribeCached(id: String, bounds: WireBounds, visible: WireBounds? = nil)
    case fetch(subscriptionID: String, token: UUID, batch: Int, strokeIDs: [UUID], final: Bool)
    case create(requestID: String, stroke: StrokePayload)
    case delete(requestID: String, strokeID: UUID)
    /// v5: 1–20 strokes; the codec refuses it on earlier profiles.
    case report(requestID: String, strokeIDs: [UUID], reason: ReportReason, blockAuthor: Bool)

    static let maximumReportStrokes = 20

    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= WireLimits.maximumClientBytes else { throw DrawingDataError.limitExceeded }
        return data
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        func subscription(_ type: String, _ id: String, _ bounds: WireBounds, _ visible: WireBounds?) throws {
            try values.encode(type, forKey: .type)
            try values.encode(WireLimits.identifier(id), forKey: .subscriptionID)
            try values.encode(bounds, forKey: .bounds)
            if let visible {
                guard bounds.contains(visible) else { throw DrawingDataError.invalidMessage }
                try values.encode(visible, forKey: .visibleBounds)
            }
        }
        switch self {
        case .hello(let secret):
            try values.encode("hello", forKey: .type)
            try values.encode(secret.base64URLValue, forKey: .sessionSecret)
        case .subscribe(let id, let bounds, let visible):
            try subscription("viewport.subscribe", id, bounds, visible)
        case .subscribeCached(let id, let bounds, let visible):
            try subscription("viewport.subscribe.cached", id, bounds, visible)
        case .fetch(let id, let token, let batch, let strokeIDs, let final):
            guard (0...ManifestLimits.maximumBatchIndex).contains(batch), strokeIDs.count <= ManifestLimits.maximumIDsPerMessage else {
                throw DrawingDataError.limitExceeded
            }
            try values.encode("viewport.fetch", forKey: .type)
            try values.encode(WireLimits.identifier(id), forKey: .subscriptionID)
            try values.encode(token.uuidString.lowercased(), forKey: .snapshotToken)
            try values.encode(batch, forKey: .batch)
            try values.encode(strokeIDs.map { $0.uuidString.lowercased() }, forKey: .strokeIDs)
            try values.encode(final, forKey: .final)
        case .create(let requestID, let stroke):
            try values.encode("stroke.create", forKey: .type)
            try values.encode(WireLimits.identifier(requestID), forKey: .requestID)
            try values.encode(stroke, forKey: .stroke)
        case .delete(let requestID, let strokeID):
            try values.encode("stroke.delete", forKey: .type)
            try values.encode(WireLimits.identifier(requestID), forKey: .requestID)
            try values.encode(strokeID.uuidString.lowercased(), forKey: .strokeID)
        case .report(let requestID, let strokeIDs, let reason, let blockAuthor):
            guard (1...Self.maximumReportStrokes).contains(strokeIDs.count), Set(strokeIDs).count == strokeIDs.count else {
                throw DrawingDataError.invalidMessage
            }
            try values.encode("stroke.report", forKey: .type)
            try values.encode(WireLimits.identifier(requestID), forKey: .requestID)
            try values.encode(strokeIDs.map { $0.uuidString.lowercased() }, forKey: .strokeIDs)
            try values.encode(reason, forKey: .reason)
            try values.encode(blockAuthor, forKey: .blockAuthor)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, bounds, stroke, batch, final
        case sessionSecret = "session_secret", subscriptionID = "subscription_id", visibleBounds = "visible_bounds"
        case requestID = "request_id", strokeID = "stroke_id", snapshotToken = "snapshot_token", strokeIDs = "stroke_ids"
        case reason, blockAuthor = "block_author"
    }
}

/// v3 manifest admission bounds (protocol-v3-manifest.md).
nonisolated enum ManifestLimits {
    static let maximumStrokes = 20_000
    static let maximumPoints = 1_000_000
    static let maximumIDsPerMessage = 1000
    static let maximumBatchIndex = 20
}

nonisolated enum SnapshotFallbackReason: String, Sendable { case busy, sceneLimit = "scene_limit" }

nonisolated enum ServerMessage: Decodable, Equatable, Sendable {
    case hello(spawn: WorldPoint?)
    case snapshotBegin(id: String)
    case snapshotChunk(id: String, strokes: [ServerStroke])
    case snapshotEnd(id: String)
    case manifestBegin(id: String, token: UUID, strokeCount: Int, pointCount: Int)
    case manifestChunk(id: String, token: UUID, strokeIDs: [UUID])
    case manifestEnd(id: String, token: UUID)
    case fetchEnd(id: String, token: UUID, batch: Int)
    case snapshotFallback(id: String, reason: SnapshotFallbackReason)
    case created(id: String, stroke: ServerStroke)
    case deleted(id: String, strokeID: UUID, sequence: Int64)
    case createAcknowledged(requestID: String, stroke: ServerStroke)
    case deleteAcknowledged(requestID: String, strokeID: UUID, sequence: Int64, alreadyDeleted: Bool)
    case reportAcknowledged(requestID: String, reportID: UUID)
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
        let version = decoder.userInfo[WireDecodingContext.protocolVersion] as? Int ?? 1
        func manifest() throws -> (id: String, token: UUID) {
            guard version >= 3 else { throw DrawingDataError.invalidMessage } // never accepted on v1/v2 sockets
            return (try id(.subscriptionID), try StrokePayload.uuid(values.decode(String.self, forKey: .snapshotToken)))
        }
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
            let binary = version >= 2
            var pointCount = 0
            while !list.isAtEnd {
                let stroke = try list.decode(ServerStroke.self)
                pointCount += stroke.payload.points.count
                guard !binary || pointCount <= 8192 else { throw DrawingDataError.limitExceeded }
                strokes.append(stroke)
            }
            self = .snapshotChunk(id: subscriptionID, strokes: strokes)
        case "viewport.manifest.begin":
            let (subscription, token) = try manifest()
            let count = try values.decode(Int.self, forKey: .strokeCount), points = try values.decode(Int.self, forKey: .pointCount)
            guard (0...ManifestLimits.maximumStrokes).contains(count), points >= count,
                  points <= min(ManifestLimits.maximumPoints, count * StrokeInput.maximumPoints) else { throw DrawingDataError.invalidMessage }
            self = .manifestBegin(id: subscription, token: token, strokeCount: count, pointCount: points)
        case "viewport.manifest.chunk":
            let (subscription, token) = try manifest()
            var list = try values.nestedUnkeyedContainer(forKey: .strokeIDs)
            guard let count = list.count, count <= ManifestLimits.maximumIDsPerMessage else { throw DrawingDataError.limitExceeded }
            var ids: [UUID] = []
            ids.reserveCapacity(count)
            while !list.isAtEnd { ids.append(try StrokePayload.uuid(list.decode(String.self))) }
            self = .manifestChunk(id: subscription, token: token, strokeIDs: ids)
        case "viewport.manifest.end":
            let (subscription, token) = try manifest()
            self = .manifestEnd(id: subscription, token: token)
        case "viewport.fetch.end":
            let (subscription, token) = try manifest()
            let batch = try values.decode(Int.self, forKey: .batch)
            guard (0...ManifestLimits.maximumBatchIndex).contains(batch) else { throw DrawingDataError.invalidMessage }
            self = .fetchEnd(id: subscription, token: token, batch: batch)
        case "viewport.snapshot.fallback":
            guard version >= 3, let reason = SnapshotFallbackReason(rawValue: try values.decode(String.self, forKey: .reason)) else {
                throw DrawingDataError.invalidMessage
            }
            self = .snapshotFallback(id: try id(.subscriptionID), reason: reason)
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
            case "stroke.report":
                guard version >= 5 else { throw DrawingDataError.invalidMessage }
                self = .reportAcknowledged(requestID: requestID, reportID: try StrokePayload.uuid(values.decode(String.self, forKey: .reportID)))
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
        case type, spawn, x, y, strokes, stroke, seq, operation, code, batch, reason
        case protocolVersion = "protocol_version", subscriptionID = "subscription_id"
        case requestID = "request_id", strokeID = "stroke_id", alreadyDeleted = "already_deleted", reportID = "report_id"
        case snapshotToken = "snapshot_token", strokeCount = "stroke_count", pointCount = "point_count", strokeIDs = "stroke_ids"
    }
}
