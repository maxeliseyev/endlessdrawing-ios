import Foundation
import Security

/// Not Codable: a session secret must never accidentally enter the operation journal.
nonisolated struct SessionSecret: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let value: String
    var base64URLValue: String { value }
    var description: String { "<session secret>" }
    var debugDescription: String { description }

    init(bytes: Data) throws {
        guard bytes.count == 32 else { throw DrawingDataError.invalidMessage }
        value = bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    init(base64URL: String) throws {
        guard base64URL.utf8.count == 43,
              base64URL.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
              let bytes = Data(base64Encoded: base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "=") else {
            throw DrawingDataError.invalidMessage
        }
        try self.init(bytes: bytes)
        guard value == base64URL else { throw DrawingDataError.invalidMessage }
    }
}

nonisolated struct DrawingIdentity: Sendable, Equatable {
    let id: UUID
    let secret: SessionSecret
}

nonisolated enum IdentityFailure: Error, Equatable, Sendable {
    case keychain(OSStatus), random(OSStatus), corruptRecord
}

nonisolated protocol IdentityKeychain: Sendable {
    func read(account: String) throws -> Data?
    /// False means another writer has already installed an identity. Never overwrite it.
    func add(_ data: Data, account: String) throws -> Bool
}

nonisolated struct SystemIdentityKeychain: IdentityKeychain {
    let service: String
    init(service: String = "maximeliseyev.endlessdrawing.identity.v1") { self.service = service }

    func read(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw IdentityFailure.keychain(status) }
        guard let data = result as? Data else { throw IdentityFailure.corruptRecord }
        return data
    }

    func add(_ data: Data, account: String) throws -> Bool {
        var query = baseQuery(account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem { return false }
        guard status == errSecSuccess else { throw IdentityFailure.keychain(status) }
        return true
    }

    private func baseQuery(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
}

actor IdentityStore {
    private let environment: DrawingEnvironment
    private let keychain: any IdentityKeychain

    init(environment: DrawingEnvironment, keychain: any IdentityKeychain = SystemIdentityKeychain()) {
        self.environment = environment
        self.keychain = keychain
    }

    func loadOrCreate() throws -> DrawingIdentity {
        if let data = try keychain.read(account: environment.identityAccount) { return try decode(data) }
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw IdentityFailure.random(status) }
        let identity = DrawingIdentity(id: UUID(), secret: try SessionSecret(bytes: bytes))
        let record = Record(version: 1, environment: environment, id: identity.id, secret: identity.secret.base64URLValue)
        if try keychain.add(JSONEncoder().encode(record), account: environment.identityAccount) { return identity }
        // A competing store won. Reuse its secret rather than changing the owner.
        guard let existing = try keychain.read(account: environment.identityAccount) else { throw IdentityFailure.corruptRecord }
        return try decode(existing)
    }

    private func decode(_ data: Data) throws -> DrawingIdentity {
        guard data.count <= 4096 else { throw IdentityFailure.corruptRecord }
        do {
            let record = try JSONDecoder().decode(Record.self, from: data)
            guard record.version == 1, record.environment == environment else { throw IdentityFailure.corruptRecord }
            return DrawingIdentity(id: record.id, secret: try SessionSecret(base64URL: record.secret))
        } catch { throw IdentityFailure.corruptRecord }
    }

    private nonisolated struct Record: Codable {
        let version: Int
        let environment: DrawingEnvironment
        let id: UUID
        let secret: String
    }
}
