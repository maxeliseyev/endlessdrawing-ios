import Foundation
import Network
import Testing
@testable import Endless_Drawing

/// In-process loopback WebSocket peer for URLSession integration; not a backend replacement.
actor LocalWebSocketServer {
    enum Mode: Sendable { case binary, jsonFallback, legacy, missingProtocol, wrongVersion, wrongFrame, oversized, flood }
    struct Handshake: Sendable {
        var offers: [String] = []
        var origin: String?
        var cookie: String?
        var requests = 0
    }
    /// All state is protected by lock; Network's synchronous upgrade callback cannot await an actor.
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Handshake()
        func record(_ offers: [String], headers: [(name: String, value: String)]) {
            lock.withLock {
                // Network exposes absent offers as [""] and retains HTTP comma-separated OWS.
                value.offers = offers.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                value.origin = headers.first { $0.name.lowercased() == "origin" }?.value
                value.cookie = headers.first { $0.name.lowercased() == "cookie" }?.value
                value.requests += 1
            }
        }
        func snapshot() -> Handshake { lock.withLock { value } }
    }

    private let listener: NWListener
    private let queue: DispatchQueue
    private let capture: Capture
    private let mode: Mode
    private var connections: [NWConnection] = []
    private var starting: CheckedContinuation<UInt16, any Error>?

    init(mode: Mode) throws {
        self.mode = mode
        let queue = DispatchQueue(label: "endless.tests.websocket")
        let capture = Capture()
        self.queue = queue; self.capture = capture
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        options.maximumMessageSize = 4 * 1024 * 1024
        options.setClientRequestHandler(queue) { offers, headers in
            capture.record(offers, headers: headers)
            guard headers.contains(where: { $0.name.lowercased() == "origin" && $0.value == "http://localhost:5173" }) else {
                return .init(status: .reject, subprotocol: nil)
            }
            let selected: String?
            switch mode {
            case .legacy, .missingProtocol: selected = nil
            case .jsonFallback: selected = TransportProfile.jsonProtocol
            default: selected = TransportProfile.messagePackProtocol
            }
            return .init(status: .accept, subprotocol: selected)
        }
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            starting = continuation
            listener.stateUpdateHandler = { [weak self] state in Task { await self?.changed(state) } }
            listener.newConnectionHandler = { [weak self] connection in Task { await self?.accepted(connection) } }
            listener.start(queue: queue)
        }
    }

    func handshake() -> Handshake { capture.snapshot() }

    func stop() {
        listener.cancel()
        for connection in connections { connection.cancel() }
        connections.removeAll()
        starting?.resume(throwing: TransportFailure.notConnected); starting = nil
    }

    private func changed(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener.port { starting?.resume(returning: port.rawValue); starting = nil }
        case .failed, .cancelled:
            starting?.resume(throwing: TransportFailure.network); starting = nil
        default: break
        }
    }

    private func accepted(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        receive(connection)
    }

    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            let opcode = (context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata)?.opcode
            Task { await self?.received(data, opcode: opcode, error: error, connection: connection) }
        }
    }

    private struct Client: Decodable { let type: String; let subscription_id: String? }
    private struct Welcome: Encodable {
        let type = "hello.ack"
        let protocol_version: Int
    }
    private struct Marker: Encodable { let type: String; let subscription_id: String }

    private func received(_ data: Data?, opcode: NWProtocolWebSocket.Opcode?, error: NWError?, connection: NWConnection) {
        guard error == nil, opcode != .close else { connection.cancel(); return }
        guard let data, let opcode else { receive(connection); return }
        if opcode == .ping || opcode == .pong { receive(connection); return }
        do {
            let json = mode == .jsonFallback || mode == .legacy
            #expect(opcode == (json ? .text : .binary))
            let client = try json ? JSONDecoder().decode(Client.self, from: data) : BoundedMessagePack.decode(Client.self, from: data)
            if client.type == "hello" {
                let wrong = mode == .wrongVersion
                if mode == .oversized {
                    sendFrame(Data(repeating: 0, count: 256 * 1024 + 1), opcode: .binary, connection: connection)
                } else {
                    try send(Welcome(protocol_version: wrong ? 1 : (json ? 1 : 2)), json: json || mode == .wrongFrame, connection: connection)
                }
                if mode == .flood {
                    for index in 0..<40 { try send(Marker(type: "viewport.snapshot.begin", subscription_id: "v\(index)"), json: false, connection: connection) }
                }
            } else if client.type == "viewport.subscribe", let id = client.subscription_id {
                try send(Marker(type: "viewport.snapshot.begin", subscription_id: id), json: json, connection: connection)
                try send(Marker(type: "viewport.snapshot.end", subscription_id: id), json: json, connection: connection)
            }
            receive(connection)
        } catch {
            Issue.record("Loopback peer rejected an application message")
            connection.cancel()
        }
    }

    private func send<T: Encodable>(_ message: T, json: Bool, connection: NWConnection) throws {
        let data = try json ? JSONEncoder().encode(message) : BoundedMessagePack.encode(message, maximumBytes: 256 * 1024)
        sendFrame(data, opcode: json ? .text : .binary, connection: connection)
    }

    private func sendFrame(_ data: Data, opcode: NWProtocolWebSocket.Opcode, connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
        let context = NWConnection.ContentContext(identifier: UUID().uuidString, metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }
}
