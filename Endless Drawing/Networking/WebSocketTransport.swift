import Foundation
import Synchronization

/// One active socket, one receive loop, one bounded serial send path. No scene or retry policy here.
actor WebSocketTransport {
    struct Connection: Sendable {
        let id: UUID
        let profile: TransportProfile
        /// Exactly one consumer. WorldSession must also check id before applying an event.
        let messages: AsyncThrowingStream<ServerMessage, any Error>
    }

    private enum Outgoing: Sendable {
        case packet(WebSocketPacket), ping
        var byteCount: Int { if case .packet(let packet) = self { packet.byteCount } else { 0 } }
    }
    private struct Send: Sendable {
        let id = UUID()
        let body: Outgoing
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let environment: DrawingEnvironment
    private let policy: TransportPolicy
    private var generation = UUID()
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var codec: SessionCodec?
    private var opening: CheckedContinuation<Connection, any Error>?
    private var incoming: AsyncThrowingStream<ServerMessage, any Error>.Continuation?
    private var receiver: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var sendWatchdog: Task<Void, Never>?
    private var queued: [Send] = []
    private var activeSend: Send?
    private var queuedBytes = 0 // includes the active send

    init(environment: DrawingEnvironment, policy: TransportPolicy = .negotiated) {
        self.environment = environment; self.policy = policy
    }

    deinit {
        watchdog?.cancel(); sendWatchdog?.cancel(); receiver?.cancel(); sender?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        opening?.resume(throwing: TransportFailure.notConnected)
        incoming?.finish()
        activeSend?.continuation.resume(throwing: TransportFailure.notConnected)
        for send in queued { send.continuation.resume(throwing: TransportFailure.notConnected) }
    }

    func connect() async throws -> Connection {
        try Task.checkCancellation()
        close(failure: nil)
        let id = generation
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = ["Origin": environment.origin]
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 8
        let delegate = SocketDelegate(
            opened: { [weak self] task, profile in Task { await self?.didOpen(task, selected: profile, id: id) } },
            ended: { [weak self] task, failure in Task { await self?.didEnd(task, failure: failure, id: id) } })
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = policy == .legacyJSONV1
            ? session.webSocketTask(with: environment.webSocketRequest())
            : session.webSocketTask(with: environment.socketURL, protocols: policy.offeredProtocols)
        // No valid large JSON body precedes selected profile / client hello. Start negotiated mode tight.
        task.maximumMessageSize = policy == .legacyJSONV1 ? WireLimits.maximumServerBytes : TransportProfile.messagePackV2.maximumServerBytes
        self.session = session
        socket = task
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                opening = continuation
                watchdog = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(8)) } catch { return }
                    await self?.expire(id: id)
                }
                task.resume()
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func send(_ message: ClientMessage) async throws {
        guard let codec else { throw TransportFailure.notConnected }
        try await enqueue(.packet(codec.encode(message)))
    }

    var isConnected: Bool { codec != nil }

    func ping() async throws { try await enqueue(.ping) }

    func disconnect() { close(failure: nil) }

    private func didOpen(_ task: URLSessionWebSocketTask, selected: String?, id: UUID) {
        guard id == generation, task === socket else { return }
        do {
            let profile = try policy.selected(selected)
            let codec = SessionCodec(profile: profile)
            self.codec = codec
            task.maximumMessageSize = profile.maximumServerBytes
            watchdog?.cancel(); watchdog = nil
            let (stream, continuation) = AsyncThrowingStream<ServerMessage, any Error>.makeStream(bufferingPolicy: .bufferingOldest(16))
            continuation.onTermination = { [weak self] _ in Task { await self?.cancel(id: id) } }
            incoming = continuation
            receiver = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        let message = try await task.receive()
                        guard let self, await self.receive(message, id: id) else { return }
                    }
                } catch {
                    await self?.receiveFailed(socketFailure(error), id: id)
                }
            }
            let continuationToResume = opening
            opening = nil
            continuationToResume?.resume(returning: Connection(id: id, profile: profile, messages: stream))
        } catch let failure as TransportFailure { close(failure: failure) }
        catch { close(failure: .unexpectedProfile) }
    }

    private func receive(_ message: URLSessionWebSocketTask.Message, id: UUID) -> Bool {
        guard id == generation, let codec, let incoming else { return false }
        do {
            let packet: WebSocketPacket
            switch message {
            case .string(let text): packet = .text(text)
            case .data(let bytes): packet = .binary(bytes)
            @unknown default: throw TransportFailure.wrongMessageType
            }
            let decoded = try codec.decode(packet)
            switch incoming.yield(decoded) {
            case .enqueued: return true
            case .dropped: close(failure: .queueFull); return false
            case .terminated: close(failure: nil); return false
            @unknown default: close(failure: .network); return false
            }
        } catch let failure as TransportFailure { close(failure: failure) }
        catch { close(failure: .malformedMessage) }
        return false
    }

    private func enqueue(_ body: Outgoing) async throws {
        try Task.checkCancellation()
        guard socket != nil, codec != nil else { throw TransportFailure.notConnected }
        guard queued.count + (activeSend == nil ? 0 : 1) < 32,
              queuedBytes + body.byteCount <= 512 * 1024 else { throw TransportFailure.queueFull }
        let id = generation
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queued.append(Send(body: body, continuation: continuation))
                queuedBytes += body.byteCount
                if sender == nil, let task = socket {
                    sender = Task { [weak self] in await self?.drain(task, id: id) }
                }
            }
        } onCancel: {
            // Once sending may have started, cancellation leaves the mutation result unknown.
            Task { await self.cancel(id: id) }
        }
    }

    private func drain(_ task: URLSessionWebSocketTask, id: UUID) async {
        while id == generation, !queued.isEmpty {
            let send = queued.removeFirst()
            activeSend = send
            sendWatchdog = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(12)) } catch { return }
                await self?.expireSend(connectionID: id, sendID: send.id)
            }
            do {
                switch send.body {
                case .packet(.text(let text)): try await task.send(.string(text))
                case .packet(.binary(let bytes)): try await task.send(.data(bytes))
                case .ping:
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                        let reply = PingReply(continuation)
                        task.sendPing { error in reply.complete(error) }
                    }
                }
            } catch {
                guard id == generation else { return }
                close(failure: .network)
                return
            }
            guard id == generation else { return } // close() already resumed the continuation
            sendWatchdog?.cancel(); sendWatchdog = nil
            activeSend = nil
            queuedBytes -= send.body.byteCount
            send.continuation.resume()
        }
        if id == generation { sender = nil }
    }

    private func didEnd(_ task: URLSessionTask, failure: TransportFailure, id: UUID) {
        guard id == generation, task === socket else { return }
        close(failure: failure)
    }

    private func receiveFailed(_ failure: TransportFailure, id: UUID) {
        guard id == generation else { return }
        close(failure: failure)
    }

    private func expire(id: UUID) {
        guard id == generation, opening != nil else { return }
        close(failure: .timedOut)
    }

    private func expireSend(connectionID: UUID, sendID: UUID) {
        guard connectionID == generation, activeSend?.id == sendID else { return }
        close(failure: .timedOut)
    }

    private func cancel(id: UUID) {
        guard id == generation else { return }
        close(failure: nil)
    }

    private func close(failure: TransportFailure?) {
        generation = UUID() // invalidate old delegate callbacks before cancelling URLSession
        watchdog?.cancel(); watchdog = nil
        sendWatchdog?.cancel(); sendWatchdog = nil
        receiver?.cancel(); receiver = nil
        sender?.cancel(); sender = nil
        let pendingOpen = opening; opening = nil
        let pendingSends = queued; queued.removeAll()
        let pendingActive = activeSend; activeSend = nil
        queuedBytes = 0
        let stream = incoming; incoming = nil
        codec = nil
        let task = socket; socket = nil
        let previousSession = session; session = nil
        task?.cancel(with: URLSessionWebSocketTask.CloseCode(rawValue: failure?.closeCode ?? 1000) ?? .protocolError, reason: nil)
        previousSession?.finishTasksAndInvalidate() // let the requested Close frame finish, rather than aborting it
        pendingOpen?.resume(throwing: failure ?? TransportFailure.notConnected)
        pendingActive?.continuation.resume(throwing: failure ?? TransportFailure.notConnected)
        for send in pendingSends { send.continuation.resume(throwing: failure ?? TransportFailure.notConnected) }
        if let failure { stream?.finish(throwing: failure) } else { stream?.finish() }
    }
}

/// URLSession may call a `sendPing` handler more than once for the same ping. On iPad (iOS 27.2,
/// TestFlight 0.6.0 (11)) a second, failing call trapped in `CheckedContinuation.resume(throwing:)`;
/// the simulator does not reproduce it. Only the first outcome counts; later calls are dropped.
nonisolated final class PingReply: Sendable {
    private let continuation: CheckedContinuation<Void, any Error>
    private let resumed = Mutex(false)
    init(_ continuation: CheckedContinuation<Void, any Error>) { self.continuation = continuation }

    /// Returns false when an earlier call already resumed the continuation.
    @discardableResult func complete(_ error: (any Error)?) -> Bool {
        let first = resumed.withLock { resumed in
            defer { resumed = true }
            return !resumed
        }
        guard first else { return false }
        if error != nil { continuation.resume(throwing: TransportFailure.network) } else { continuation.resume() }
        return true
    }
}

/// Classify by public SDK code only; never retain or expose raw NSError/userInfo/reason bodies.
private nonisolated func socketFailure(_ error: any Error) -> TransportFailure {
    let error = error as NSError
    if error.domain == NSURLErrorDomain, error.code == URLError.dataLengthExceedsMaximum.rawValue { return .messageTooLarge }
    // URLSession's WebSocket message-size ceiling is surfaced as POSIX EMSGSIZE on iOS 18/27.
    if error.domain == NSPOSIXErrorDomain, error.code == Int(POSIXError.Code.EMSGSIZE.rawValue) { return .messageTooLarge }
    return .network
}

/// Only immutable Sendable callbacks cross Foundation's delegate queue into the transport actor.
private nonisolated final class SocketDelegate: NSObject, URLSessionWebSocketDelegate {
    let opened: @Sendable (URLSessionWebSocketTask, String?) -> Void
    let ended: @Sendable (URLSessionTask, TransportFailure) -> Void
    init(opened: @escaping @Sendable (URLSessionWebSocketTask, String?) -> Void,
         ended: @escaping @Sendable (URLSessionTask, TransportFailure) -> Void) {
        self.opened = opened; self.ended = ended
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        opened(webSocketTask, `protocol`)
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        ended(webSocketTask, closeCode.rawValue == 1009 ? .messageTooLarge : .network)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error { ended(task, socketFailure(error)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil) // no cross-host credentials/Origin forwarding or redirect-based codec downgrade
    }
}
