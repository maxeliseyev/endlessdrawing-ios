import Foundation
@testable import Endless_Drawing

nonisolated enum M2TestSupport {
    static func environment(port: Int = 3000) throws -> DrawingEnvironment {
        try DrawingEnvironment(namespace: .development, socketURL: URL(string: "ws://127.0.0.1:\(port)/ws")!,
                               origin: "http://localhost:5173")
    }

    static func payload(id: UUID = UUID(), brush: BrushKind = .round) throws -> StrokePayload {
        try StrokePayload(id: id, points: [.zero, WorldPoint(x: 10, y: 5)], brush: brush,
                          width: 6, color: "#aBcDeF", opacity: 0.5)
    }

    static func object(_ payload: StrokePayload, sequence: Int64 = 1, own: Bool = true) throws -> [String: Any] {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as! [String: Any]
        object["seq"] = sequence; object["own"] = own
        return object
    }

    static func confirmed(_ payload: StrokePayload, sequence: Int64 = 1, own: Bool = true) throws -> ServerStroke {
        try JSONDecoder().decode(ServerStroke.self, from: JSONSerialization.data(withJSONObject: object(payload, sequence: sequence, own: own)))
    }
}
