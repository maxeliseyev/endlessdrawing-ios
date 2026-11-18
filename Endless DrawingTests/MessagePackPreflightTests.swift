import Foundation
import Testing
@testable import Endless_Drawing

struct MessagePackPreflightTests {
    private func root(_ value: [UInt8]) -> Data { Data([0x81, 0xa1, 0x78] + value) }

    @Test func rejectsForbiddenTagsUnsafeIntegersAndNonFiniteDoubles() {
        let invalid: [[UInt8]] = [
            [0xc0], [0xc1], [0xc4, 0], [0xc5, 0, 0], [0xc6, 0, 0, 0, 0],
            [0xc7, 0, 0], [0xd4, 0, 0], [0xd6, 0xff, 0, 0, 0, 0],
            [0xca, 0x3f, 0x80, 0, 0],
            [0xcb, 0x7f, 0xf0, 0, 0, 0, 0, 0, 0],
            [0xcb, 0x7f, 0xf8, 0, 0, 0, 0, 0, 0],
            [0xcf, 0, 0x20, 0, 0, 0, 0, 0, 0],
            [0xd3, 0x80, 0, 0, 0, 0, 0, 0, 0]
        ]
        for value in invalid {
            #expect(throws: TransportFailure.malformedMessage) { try MessagePackPreflight.validate(root(value)) }
        }
    }

    @Test func rejectsDuplicateNonStringDangerousKeysAndInvalidUTF8() throws {
        for bytes: [UInt8] in [[0x82, 0xa1, 0x61, 1, 0xa1, 0x61, 2], [0x81, 1, 1], [0x81, 0xa1, 0xff, 1], [0x81, 0xa1, 0x78, 0xa1, 0xff]] {
            #expect(throws: TransportFailure.malformedMessage) { try MessagePackPreflight.validate(Data(bytes)) }
        }
        for key in ["__proto__", "prototype", "constructor"] {
            let bytes = Data([0x81, UInt8(0xa0 + key.utf8.count)] + key.utf8 + [1])
            #expect(throws: TransportFailure.malformedMessage) { try MessagePackPreflight.validate(bytes) }
        }
    }

    @Test func rejectsHugeLengthHeadersBeforeAllocation() {
        for value: [UInt8] in [[0xdd, 0xff, 0xff, 0xff, 0xff], [0xdf, 0xff, 0xff, 0xff, 0xff],
                               [0xdb, 0xff, 0xff, 0xff, 0xff], [0xdc, 0x07, 0xd1]] {
            #expect(throws: TransportFailure.malformedMessage) { try MessagePackPreflight.validate(root(value)) }
        }
        let longString = root([0xda, 1, 1] + Array(repeating: 0x61, count: 257))
        #expect(throws: TransportFailure.malformedMessage) { try MessagePackPreflight.validate(longString) }
        #expect(throws: TransportFailure.malformedMessage) { try MessagePackPreflight.validate(Data([0xde, 0, 17])) }
    }

    @Test func enforcesDepthAndTotalNodeBudgets() throws {
        try MessagePackPreflight.validate(root(Array(repeating: 0x91, count: 7) + [1]))
        #expect(throws: TransportFailure.malformedMessage) {
            try MessagePackPreflight.validate(root(Array(repeating: 0x91, count: 8) + [1]))
        }
        var nodes: [UInt8] = [0xdc, 0, 33]
        for _ in 0..<33 { nodes += [0xdc, 0x07, 0xd0] + Array(repeating: 1, count: 2000) }
        #expect(throws: TransportFailure.malformedMessage) { try MessagePackPreflight.validate(root(nodes)) }
    }

    @Test func requiresOneTopLevelMapWithoutTrailingObject() throws {
        try MessagePackPreflight.validate(Data([0x80]))
        for bytes: [UInt8] in [[], [1], [0x90], [0xa0], [0x80, 0x80], [0x80, 0]] {
            #expect(throws: TransportFailure.malformedMessage) { try MessagePackPreflight.validate(Data(bytes)) }
        }
    }

    @Test func everyTruncatedGoldenMessageFailsBoundedly() throws {
        for sample in try V2Fixtures.samples() {
            let bytes = try V2Fixtures.data("\(sample.name).rust.msgpack")
            for count in 0..<bytes.count {
                #expect(throws: TransportFailure.malformedMessage) { try MessagePackPreflight.validate(Data(bytes.prefix(count))) }
            }
        }
    }
}
