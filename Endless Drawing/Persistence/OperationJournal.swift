import CryptoKit
import Foundation

nonisolated protocol JournalStorage: Sendable {
    func read(maximumBytes: Int) throws -> Data?
    func writeAtomically(_ data: Data) throws
}

nonisolated struct JournalFileStorage: JournalStorage {
    let url: URL

    static func applicationSupport(environment: DrawingEnvironment) throws -> Self {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        // Hash is only a filesystem locator, not encryption. In particular, do NOT include identityID:
        // losing a Keychain identity must expose a journal mismatch, not silently open a new empty file.
        let key = SHA256.hash(data: Data(environment.identityAccount.utf8)).map { String(format: "%02x", $0) }.joined()
        return Self(url: root.appendingPathComponent("EndlessDrawingOperations/v1", isDirectory: true)
            .appendingPathComponent(key, isDirectory: true).appendingPathComponent("operations.json"))
    }

    func read(maximumBytes: Int) throws -> Data? {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let count = values.fileSize, count <= maximumBytes else {
                throw DrawingDataError.limitExceeded
            }
            let data = try Data(contentsOf: url)
            guard data.count <= maximumBytes else { throw DrawingDataError.limitExceeded }
            return data
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
    }

    func writeAtomically(_ data: Data) throws {
        var directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.complete])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }
}

nonisolated struct JournalOperation: Codable, Equatable, Sendable, Identifiable {
    enum Payload: Codable, Equatable, Sendable {
        case create(StrokePayload)
        case delete(UUID)
        var strokeID: UUID {
            switch self { case .create(let stroke): stroke.id; case .delete(let id): id }
        }
    }
    let id: UUID
    let ordinal: Int64
    let payload: Payload
    var mayHaveBeenSent = false
    var cancelled = false

    func message(requestID: String) -> ClientMessage {
        switch payload {
        case .create(let stroke): .create(requestID: requestID, stroke: stroke)
        case .delete(let id): .delete(requestID: requestID, strokeID: id)
        }
    }
}

nonisolated struct JournalUndoEntry: Codable, Equatable, Sendable {
    let strokeID: UUID
    let ordinal: Int64
}

nonisolated struct JournalSnapshot: Codable, Equatable, Sendable {
    let version: Int
    let environment: DrawingEnvironment
    let identityID: UUID
    var nextOrdinal: Int64
    var operations: [JournalOperation]
    var undo: [JournalUndoEntry]

    init(environment: DrawingEnvironment, identityID: UUID) {
        version = 1; self.environment = environment; self.identityID = identityID
        nextOrdinal = 1; operations = []; undo = []
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        environment = try values.decode(DrawingEnvironment.self, forKey: .environment)
        identityID = try values.decode(UUID.self, forKey: .identityID)
        nextOrdinal = try values.decode(Int64.self, forKey: .nextOrdinal)
        func list<T: Decodable>(_ type: T.Type, key: CodingKeys, maximum: Int) throws -> [T] {
            var container = try values.nestedUnkeyedContainer(forKey: key)
            guard let count = container.count, count <= maximum else { throw DrawingDataError.limitExceeded }
            var result: [T] = []
            result.reserveCapacity(count)
            while !container.isAtEnd { result.append(try container.decode(T.self)) }
            return result
        }
        operations = try list(JournalOperation.self, key: .operations, maximum: 320)
        undo = try list(JournalUndoEntry.self, key: .undo, maximum: 500)
    }

    private enum CodingKeys: String, CodingKey { case version, environment, identityID, nextOrdinal, operations, undo }
}

/// Durable state machine only. It does not send requests or claim an operation is server-confirmed.
actor OperationJournal {
    static let maximumBytes = 16 * 1024 * 1024
    private let environment: DrawingEnvironment
    private let identityID: UUID
    private let storage: any JournalStorage
    private var state: JournalSnapshot
    private var revision: UInt64 = 0

    private init(environment: DrawingEnvironment, identityID: UUID, storage: any JournalStorage) {
        self.environment = environment; self.identityID = identityID; self.storage = storage
        state = JournalSnapshot(environment: environment, identityID: identityID)
    }

    nonisolated static func open(environment: DrawingEnvironment, identityID: UUID,
                                 storage: any JournalStorage) async throws -> OperationJournal {
        let journal = OperationJournal(environment: environment, identityID: identityID, storage: storage)
        try await journal.load()
        return journal
    }

    func snapshot() -> JournalSnapshot { state }
    func versionedSnapshot() -> (revision: UInt64, state: JournalSnapshot) { (revision, state) }

    @discardableResult
    func enqueueCreate(_ stroke: StrokePayload) throws -> UUID {
        // Reserve a full-length UUID request_id before writing the immutable payload.
        _ = try ClientMessage.create(requestID: UUID().uuidString, stroke: stroke).jsonData()
        return try transaction { next in
            guard !next.operations.contains(where: { $0.payload.strokeID == stroke.id }),
                  !next.undo.contains(where: { $0.strokeID == stroke.id }) else { throw DrawingDataError.invalidTransition }
            let ordinal = try Self.ordinal(&next)
            next.operations.append(JournalOperation(id: stroke.id, ordinal: ordinal, payload: .create(stroke)))
            return stroke.id
        }
    }

    /// Persist this before calling URLSession.send. A crash afterwards is an unknown result, not "unsent".
    func markMayHaveBeenSent(_ id: UUID) throws -> JournalOperation {
        try transaction { next in
            guard let index = next.operations.firstIndex(where: { $0.id == id }) else { throw DrawingDataError.invalidTransition }
            next.operations[index].mayHaveBeenSent = true
            return next.operations[index]
        }
    }

    /// Cancels a pending create or queues an idempotent delete. Authorization remains the server's job.
    func requestDelete(strokeID: UUID) throws {
        try transaction { next in try Self.requestDelete(strokeID: strokeID, state: &next) }
    }

    /// Most recently drawn action, independent of the order in which acknowledgements arrived.
    @discardableResult
    func undoNewest() throws -> UUID? {
        try transaction { next in
            let pending = next.operations.filter {
                if case .create = $0.payload { return !$0.cancelled }; return false
            }.max(by: { $0.ordinal < $1.ordinal })
            let deleting = Set(next.operations.compactMap { operation -> UUID? in
                if case .delete(let id) = operation.payload { return id }; return nil
            })
            let confirmed = next.undo.filter { !deleting.contains($0.strokeID) }.max(by: { $0.ordinal < $1.ordinal })
            let id: UUID?
            if let pending, pending.ordinal > (confirmed?.ordinal ?? 0) { id = pending.payload.strokeID }
            else { id = confirmed?.strokeID }
            if let id { try Self.requestDelete(strokeID: id, state: &next) }
            return id
        }
    }

    @discardableResult
    func acknowledgeCreate(operationID: UUID, stroke: ServerStroke) throws -> Bool {
        try transaction { next in
            guard let index = next.operations.firstIndex(where: { $0.id == operationID }) else { return false }
            let operation = next.operations[index]
            guard case .create(let draft) = operation.payload, draft == stroke.payload, stroke.own,
                  operation.mayHaveBeenSent else { throw DrawingDataError.invalidTransition }
            next.operations.remove(at: index)
            if operation.cancelled {
                try Self.appendDelete(strokeID: draft.id, state: &next)
            } else {
                next.undo.append(JournalUndoEntry(strokeID: draft.id, ordinal: operation.ordinal))
                next.undo.sort { $0.ordinal < $1.ordinal }
                if next.undo.count > 500 { next.undo.removeFirst(next.undo.count - 500) }
            }
            return true
        }
    }

    @discardableResult
    func acknowledgeDelete(operationID: UUID, strokeID: UUID) throws -> Bool {
        try transaction { next in
            guard let index = next.operations.firstIndex(where: { $0.id == operationID }) else { return false }
            let operation = next.operations[index]
            guard case .delete(let id) = operation.payload, id == strokeID,
                  operation.mayHaveBeenSent else { throw DrawingDataError.invalidTransition }
            next.operations.remove(at: index)
            next.undo.removeAll { $0.strokeID == id }
            return true
        }
    }

    /// Only a definitive server rejection may discard an unresolved operation. Never call on timeout.
    func reject(operationID: UUID, discardUndo: Bool = false) throws {
        try transaction { next in
            guard let index = next.operations.firstIndex(where: { $0.id == operationID }) else { return }
            let operation = next.operations.remove(at: index)
            if discardUndo { next.undo.removeAll { $0.strokeID == operation.payload.strokeID } }
        }
    }

    private func load() throws {
        if let data = try storage.read(maximumBytes: Self.maximumBytes) {
            let restored: JournalSnapshot
            do { restored = try JSONDecoder().decode(JournalSnapshot.self, from: data) }
            catch { throw DrawingDataError.corruptJournal }
            guard restored.environment == environment, restored.identityID == identityID else { throw DrawingDataError.identityMismatch }
            try Self.validate(restored)
            state = restored
        } else {
            // Bind even an empty journal to its identity before accepting any operations.
            try persist(state)
        }
    }

    private func transaction<T>(_ update: (inout JournalSnapshot) throws -> T) throws -> T {
        var next = state
        let result = try update(&next)
        try Self.validate(next)
        if next != state {
            try persist(next)
            state = next // failed writes leave the in-memory state unchanged, too
            revision &+= 1
        }
        return result
    }

    private func persist(_ snapshot: JournalSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(snapshot)
        guard data.count <= Self.maximumBytes else { throw DrawingDataError.limitExceeded }
        try storage.writeAtomically(data)
    }

    private static func ordinal(_ next: inout JournalSnapshot) throws -> Int64 {
        guard next.nextOrdinal > 0, next.nextOrdinal < Int64.max else { throw DrawingDataError.limitExceeded }
        let result = next.nextOrdinal
        next.nextOrdinal += 1
        return result
    }

    private static func requestDelete(strokeID: UUID, state: inout JournalSnapshot) throws {
        if let index = state.operations.firstIndex(where: { if case .create(let draft) = $0.payload { return draft.id == strokeID }; return false }) {
            if state.operations[index].mayHaveBeenSent { state.operations[index].cancelled = true }
            else { state.operations.remove(at: index) }
        } else if !state.operations.contains(where: { $0.payload == .delete(strokeID) }) {
            try appendDelete(strokeID: strokeID, state: &state)
        }
    }

    private static func appendDelete(strokeID: UUID, state: inout JournalSnapshot) throws {
        let ordinal = try ordinal(&state)
        state.operations.append(JournalOperation(id: UUID(), ordinal: ordinal, payload: .delete(strokeID)))
    }

    private static func validate(_ snapshot: JournalSnapshot) throws {
        guard snapshot.version == 1, snapshot.undo.count <= 500,
              Set(snapshot.operations.map(\.id)).count == snapshot.operations.count,
              Set(snapshot.undo.map(\.strokeID)).count == snapshot.undo.count else { throw DrawingDataError.corruptJournal }
        var creates: Set<UUID> = [], deletes: Set<UUID> = []
        var cancelled = 0
        for operation in snapshot.operations {
            switch operation.payload {
            case .create(let stroke):
                guard stroke.id == operation.id, creates.insert(stroke.id).inserted,
                      !operation.cancelled || operation.mayHaveBeenSent else { throw DrawingDataError.corruptJournal }
                if operation.cancelled { cancelled += 1 }
            case .delete(let id):
                guard !operation.cancelled, deletes.insert(id).inserted else { throw DrawingDataError.corruptJournal }
            }
        }
        guard creates.count <= 64, deletes.count + cancelled <= 256 else { throw DrawingDataError.limitExceeded }
        let ordinals = snapshot.operations.map(\.ordinal) + snapshot.undo.map(\.ordinal)
        guard ordinals.allSatisfy({ $0 > 0 && $0 < snapshot.nextOrdinal }), snapshot.nextOrdinal > 0,
              Set(ordinals).count == ordinals.count, creates.isDisjoint(with: deletes),
              creates.isDisjoint(with: Set(snapshot.undo.map(\.strokeID))),
              snapshot.operations.map(\.ordinal) == snapshot.operations.map(\.ordinal).sorted(),
              snapshot.undo.map(\.ordinal) == snapshot.undo.map(\.ordinal).sorted() else { throw DrawingDataError.corruptJournal }
    }
}
