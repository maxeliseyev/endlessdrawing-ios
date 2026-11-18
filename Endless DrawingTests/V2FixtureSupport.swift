import CryptoKit
import Foundation
import Testing
@testable import Endless_Drawing

/// Semantic fixture values only; not a production decoder or an alternative to application guards.
nonisolated indirect enum FixtureValue: Codable, Equatable, Sendable {
    case object([String: FixtureValue]), array([FixtureValue]), string(String), bool(Bool), integer(Int64), double(Double)
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let result = try? value.decode(Bool.self) { self = .bool(result) }
        else if let result = try? value.decode(Int64.self) { self = .integer(result) }
        else if let result = try? value.decode(Double.self) { self = .double(result) }
        else if let result = try? value.decode(String.self) { self = .string(result) }
        else if let result = try? value.decode([FixtureValue].self) { self = .array(result) }
        else { self = .object(try value.decode([String: FixtureValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let map): try value.encode(map)
        case .array(let array): try value.encode(array)
        case .string(let text): try value.encode(text)
        case .bool(let bool): try value.encode(bool)
        case .integer(let integer): try value.encode(integer)
        case .double(let double): try value.encode(double)
        }
    }
    static func == (a: Self, b: Self) -> Bool {
        switch (a, b) {
        case (.object(let a), .object(let b)): a == b
        case (.array(let a), .array(let b)): a == b
        case (.string(let a), .string(let b)): a == b
        case (.bool(let a), .bool(let b)): a == b
        case (.integer(let a), .integer(let b)): a == b
        case (.double(let a), .double(let b)): a == b
        case (.integer(let a), .double(let b)), (.double(let b), .integer(let a)): Double(a) == b
        default: false
        }
    }
}

nonisolated enum V2Fixtures {
    private final class BundleToken: NSObject {}
    struct Sample: Decodable { let name: String; let value: FixtureValue }
    static func data(_ filename: String) throws -> Data {
        let bundle = Bundle(for: BundleToken.self)
        let url = try #require(bundle.url(forResource: filename, withExtension: nil, subdirectory: "ws-v2")
            ?? bundle.url(forResource: filename, withExtension: nil))
        return try Data(contentsOf: url)
    }
    static func samples() throws -> [Sample] { try JSONDecoder().decode([Sample].self, from: data("corpus.json")) }
}
