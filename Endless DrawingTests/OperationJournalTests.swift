import Foundation
import Testing
@testable import Endless_Drawing

struct OperationJournalTests {
    private func file() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("drawing-journal-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("operations.json")
    }
    private func remove(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    @Test func defaultJournalLocationIsStableAndEndpointScopedNotOwnerScoped() throws {
        let environment = try M2TestSupport.environment()
        let first = try JournalFileStorage.applicationSupport(environment: environment)
        let second = try JournalFileStorage.applicationSupport(environment: environment)
        let other = try JournalFileStorage.applicationSupport(environment: M2TestSupport.environment(port: 3001))
        #expect(first.url == second.url)
        #expect(first.url != other.url)
        #expect(first.url.lastPathComponent == "operations.json")
        #expect(first.url.deletingLastPathComponent().lastPathComponent.utf8.count == 64)
    }

    @Test func unknownResultSurvivesRestartWithExactPayloadAndIdentity() async throws {
        let url = file(); defer { remove(url) }
        let environment = try M2TestSupport.environment(), owner = UUID()
        let journal = try await OperationJournal.open(environment: environment, identityID: owner, storage: JournalFileStorage(url: url))
        let payload = try M2TestSupport.payload()
        try await journal.enqueueCreate(payload)
        let attempt = try await journal.markMayHaveBeenSent(payload.id)
        let restored = try await OperationJournal.open(environment: environment, identityID: owner, storage: JournalFileStorage(url: url))
        let snapshot = await restored.snapshot()
        #expect(snapshot.operations == [attempt])
        #expect(snapshot.operations.first?.payload == .create(payload))
        #expect(snapshot.operations.first?.mayHaveBeenSent == true)
        let retry = try #require(snapshot.operations.first)
        #expect(try retry.message(requestID: "same-request").jsonData() == attempt.message(requestID: "same-request").jsonData())
        let disk = try String(contentsOf: url, encoding: .utf8)
        #expect(!disk.contains("session_secret") && !disk.contains("\"secret\""))
    }

    @Test func undoUnsentCreateRemovesItWithoutDelete() async throws {
        let url = file(); defer { remove(url) }
        let journal = try await OperationJournal.open(environment: M2TestSupport.environment(), identityID: UUID(), storage: JournalFileStorage(url: url))
        let payload = try M2TestSupport.payload()
        try await journal.enqueueCreate(payload)
        let undone = try await journal.undoNewest()
        let snapshot = await journal.snapshot()
        #expect(undone == payload.id)
        #expect(snapshot.operations.isEmpty && snapshot.undo.isEmpty)
    }

    @Test func undoUnknownCreateResolvesThenCompensatesWithDeleteAcrossRestart() async throws {
        let url = file(); defer { remove(url) }
        let environment = try M2TestSupport.environment(), owner = UUID()
        let journal = try await OperationJournal.open(environment: environment, identityID: owner, storage: JournalFileStorage(url: url))
        let payload = try M2TestSupport.payload()
        try await journal.enqueueCreate(payload)
        _ = try await journal.markMayHaveBeenSent(payload.id)
        try await journal.requestDelete(strokeID: payload.id)
        let restored = try await OperationJournal.open(environment: environment, identityID: owner, storage: JournalFileStorage(url: url))
        let cancelled = await restored.snapshot()
        #expect(cancelled.operations.first?.cancelled == true)
        let ack = try M2TestSupport.confirmed(payload)
        #expect(try await restored.acknowledgeCreate(operationID: payload.id, stroke: ack))
        let state = await restored.snapshot()
        let compensation = try #require(state.operations.first)
        #expect(state.operations.count == 1 && state.undo.isEmpty)
        #expect(compensation.payload == .delete(payload.id))
        #expect(compensation.mayHaveBeenSent == false)
        _ = try await restored.markMayHaveBeenSent(compensation.id)
        #expect(try await restored.acknowledgeDelete(operationID: compensation.id, strokeID: payload.id))
        #expect(try await restored.acknowledgeDelete(operationID: compensation.id, strokeID: payload.id) == false)
        #expect(await restored.snapshot().operations.isEmpty)
    }

    @Test func undoUsesDrawingOrderNotAckOrderOrPendingStatus() async throws {
        let url = file(); defer { remove(url) }
        let journal = try await OperationJournal.open(environment: M2TestSupport.environment(), identityID: UUID(), storage: JournalFileStorage(url: url))
        let older = try M2TestSupport.payload(), newer = try M2TestSupport.payload()
        for payload in [older, newer] {
            try await journal.enqueueCreate(payload)
            _ = try await journal.markMayHaveBeenSent(payload.id)
        }
        _ = try await journal.acknowledgeCreate(operationID: newer.id, stroke: M2TestSupport.confirmed(newer, sequence: 2))
        #expect(try await journal.undoNewest() == newer.id)
        let state = await journal.snapshot()
        #expect(state.operations.contains { $0.payload == .create(older) && !$0.cancelled })
        #expect(state.operations.contains { $0.payload == .delete(newer.id) })
        _ = try await journal.acknowledgeCreate(operationID: older.id, stroke: M2TestSupport.confirmed(older))
        let final = await journal.snapshot()
        #expect(final.undo.map(\.strokeID) == [older.id, newer.id])
        #expect(try await journal.undoNewest() == older.id)
    }

    @Test func duplicateAndMismatchedAcknowledgementsDoNotDropOperations() async throws {
        let url = file(); defer { remove(url) }
        let journal = try await OperationJournal.open(environment: M2TestSupport.environment(), identityID: UUID(), storage: JournalFileStorage(url: url))
        let payload = try M2TestSupport.payload()
        try await journal.enqueueCreate(payload)
        let own = try M2TestSupport.confirmed(payload)
        await #expect(throws: DrawingDataError.invalidTransition) { try await journal.acknowledgeCreate(operationID: payload.id, stroke: own) }
        _ = try await journal.markMayHaveBeenSent(payload.id)
        let foreign = try M2TestSupport.confirmed(payload, own: false)
        await #expect(throws: DrawingDataError.invalidTransition) { try await journal.acknowledgeCreate(operationID: payload.id, stroke: foreign) }
        let wrong = try M2TestSupport.confirmed(M2TestSupport.payload())
        await #expect(throws: DrawingDataError.invalidTransition) { try await journal.acknowledgeCreate(operationID: payload.id, stroke: wrong) }
        #expect(await journal.snapshot().operations.count == 1)
        #expect(try await journal.acknowledgeCreate(operationID: payload.id, stroke: own))
        #expect(try await journal.acknowledgeCreate(operationID: payload.id, stroke: own) == false)
        #expect(await journal.snapshot().undo.count == 1)
    }

    @Test func deletesAreDeduplicatedAndAckMustMatchStrokeID() async throws {
        let url = file(); defer { remove(url) }
        let journal = try await OperationJournal.open(environment: M2TestSupport.environment(), identityID: UUID(), storage: JournalFileStorage(url: url))
        let id = UUID()
        try await journal.requestDelete(strokeID: id)
        let first = await journal.snapshot()
        try await journal.requestDelete(strokeID: id)
        #expect(await journal.snapshot() == first)
        let operation = try #require(first.operations.first)
        _ = try await journal.markMayHaveBeenSent(operation.id)
        await #expect(throws: DrawingDataError.invalidTransition) { try await journal.acknowledgeDelete(operationID: operation.id, strokeID: UUID()) }
        #expect(await journal.snapshot().operations.count == 1)
        #expect(try await journal.acknowledgeDelete(operationID: operation.id, strokeID: id))
    }

    @Test func pendingCreateLimitRejectsNewWorkWithoutEvictingOldWork() async throws {
        let url = file(); defer { remove(url) }
        let journal = try await OperationJournal.open(environment: M2TestSupport.environment(), identityID: UUID(), storage: JournalFileStorage(url: url))
        for _ in 0..<64 { try await journal.enqueueCreate(M2TestSupport.payload()) }
        let before = await journal.snapshot()
        let additional = try M2TestSupport.payload()
        await #expect(throws: DrawingDataError.limitExceeded) { try await journal.enqueueCreate(additional) }
        #expect(await journal.snapshot() == before)
    }

    @Test func mismatchedOwnerOrEnvironmentNeverReplaysOrOverwritesJournal() async throws {
        let url = file(); defer { remove(url) }
        let environment = try M2TestSupport.environment(), owner = UUID()
        let journal = try await OperationJournal.open(environment: environment, identityID: owner, storage: JournalFileStorage(url: url))
        try await journal.enqueueCreate(M2TestSupport.payload())
        let before = try Data(contentsOf: url)
        await #expect(throws: DrawingDataError.identityMismatch) {
            try await OperationJournal.open(environment: environment, identityID: UUID(), storage: JournalFileStorage(url: url))
        }
        let other = try M2TestSupport.environment(port: 3001)
        await #expect(throws: DrawingDataError.identityMismatch) {
            try await OperationJournal.open(environment: other, identityID: owner, storage: JournalFileStorage(url: url))
        }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func corruptionAndUnsupportedVersionArePreservedInsteadOfStartingEmpty() async throws {
        let url = file(); defer { remove(url) }
        let environment = try M2TestSupport.environment(), owner = UUID()
        try JournalFileStorage(url: url).writeAtomically(Data("broken journal".utf8))
        await #expect(throws: DrawingDataError.corruptJournal) {
            try await OperationJournal.open(environment: environment, identityID: owner, storage: JournalFileStorage(url: url))
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "broken journal")
        let valid = try JSONEncoder().encode(JournalSnapshot(environment: environment, identityID: owner))
        var object = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        object["version"] = 99
        let unsupported = try JSONSerialization.data(withJSONObject: object)
        try JournalFileStorage(url: url).writeAtomically(unsupported)
        await #expect(throws: DrawingDataError.corruptJournal) {
            try await OperationJournal.open(environment: environment, identityID: owner, storage: JournalFileStorage(url: url))
        }
        #expect(try Data(contentsOf: url) == unsupported)
    }

    @Test func writeFailureDoesNotMarkUnsentOperationAsSentInMemory() async throws {
        let environment = try M2TestSupport.environment(), owner = UUID()
        let payload = try M2TestSupport.payload()
        var initial = JournalSnapshot(environment: environment, identityID: owner)
        initial.operations = [JournalOperation(id: payload.id, ordinal: 1, payload: .create(payload))]
        initial.nextOrdinal = 2
        let storage = RejectWrites(data: try JSONEncoder().encode(initial))
        let journal = try await OperationJournal.open(environment: environment, identityID: owner, storage: storage)
        await #expect(throws: WriteFailure.denied) { try await journal.markMayHaveBeenSent(payload.id) }
        #expect(await journal.snapshot() == initial)
        let additional = try M2TestSupport.payload()
        await #expect(throws: WriteFailure.denied) { try await journal.enqueueCreate(additional) }
        #expect(await journal.snapshot() == initial)
    }

    @Test func duplicateUUIDDoesNotReplaceImmutableDraft() async throws {
        let url = file(); defer { remove(url) }
        let journal = try await OperationJournal.open(environment: M2TestSupport.environment(), identityID: UUID(), storage: JournalFileStorage(url: url))
        let original = try M2TestSupport.payload()
        try await journal.enqueueCreate(original)
        let changed = try StrokePayload(id: original.id, points: [.zero], brush: .round, width: 64, color: "#FFFFFF", opacity: 1)
        await #expect(throws: DrawingDataError.invalidTransition) { try await journal.enqueueCreate(changed) }
        #expect(await journal.snapshot().operations.first?.payload == .create(original))
    }

    @Test func fileStorageExcludesJournalFromBackupAndRejectsOversizedFile() async throws {
        let url = file(); defer { remove(url) }
        let storage = JournalFileStorage(url: url)
        let environment = try M2TestSupport.environment(), owner = UUID()
        _ = try await OperationJournal.open(environment: environment, identityID: owner, storage: storage)
        let flags = try url.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(flags.isExcludedFromBackup == true)
        let large = Data(repeating: 0, count: OperationJournal.maximumBytes + 1)
        try storage.writeAtomically(large)
        await #expect(throws: DrawingDataError.limitExceeded) {
            try await OperationJournal.open(environment: environment, identityID: owner, storage: storage)
        }
        #expect(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == large.count)
    }

    @Test func cancelledCreateReservesCapacityForCompensatingDelete() async throws {
        let url = file(); defer { remove(url) }
        let environment = try M2TestSupport.environment(), owner = UUID()
        let payload = try M2TestSupport.payload()
        var initial = JournalSnapshot(environment: environment, identityID: owner)
        initial.operations = [JournalOperation(id: payload.id, ordinal: 1, payload: .create(payload), mayHaveBeenSent: true)]
        for index in 0..<256 {
            initial.operations.append(JournalOperation(id: UUID(), ordinal: Int64(index + 2), payload: .delete(UUID()), mayHaveBeenSent: true))
        }
        initial.nextOrdinal = 258
        try JournalFileStorage(url: url).writeAtomically(JSONEncoder().encode(initial))
        let journal = try await OperationJournal.open(environment: environment, identityID: owner, storage: JournalFileStorage(url: url))
        await #expect(throws: DrawingDataError.limitExceeded) { try await journal.requestDelete(strokeID: payload.id) }
        #expect(await journal.snapshot() == initial)
        let deleting = initial.operations[1]
        _ = try await journal.acknowledgeDelete(operationID: deleting.id, strokeID: deleting.payload.strokeID)
        try await journal.requestDelete(strokeID: payload.id)
        _ = try await journal.acknowledgeCreate(operationID: payload.id, stroke: M2TestSupport.confirmed(payload))
        let final = await journal.snapshot()
        #expect(final.operations.count == 256)
        #expect(final.operations.contains { $0.payload == .delete(payload.id) })
    }

    private enum WriteFailure: Error, Equatable { case denied }
    private nonisolated struct RejectWrites: JournalStorage {
        let data: Data
        func read(maximumBytes: Int) throws -> Data? { data }
        func writeAtomically(_ data: Data) throws { throw WriteFailure.denied }
    }
}
