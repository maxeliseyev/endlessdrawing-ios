import Foundation
import Security
import Testing
@testable import Endless_Drawing

struct IdentityStoreTests {
    @Test func secretIsExactly32BytesCanonicalAndRedacted() throws {
        let secret = try SessionSecret(bytes: Data(repeating: 0, count: 32))
        #expect(secret.base64URLValue.utf8.count == 43)
        #expect(!secret.base64URLValue.contains("="))
        #expect(try SessionSecret(base64URL: secret.base64URLValue) == secret)
        #expect(!String(reflecting: secret).contains(secret.base64URLValue))
        #expect(throws: DrawingDataError.invalidMessage) { try SessionSecret(bytes: Data(repeating: 0, count: 31)) }
        #expect(throws: DrawingDataError.invalidMessage) { try SessionSecret(base64URL: secret.base64URLValue + "=") }
        #expect(throws: DrawingDataError.invalidMessage) { try SessionSecret(base64URL: String(repeating: "A", count: 42) + "B") }
    }

    @Test func actualKeychainRestoresOwnerAndSeparatesEnvironments() async throws {
        let service = "endless-drawing.tests.\(UUID().uuidString)"
        let keychain = SystemIdentityKeychain(service: service)
        defer {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        }
        let firstEnvironment = try M2TestSupport.environment()
        let secondEnvironment = try M2TestSupport.environment(port: 3001)
        let first = try await IdentityStore(environment: firstEnvironment, keychain: keychain).loadOrCreate()
        let restored = try await IdentityStore(environment: firstEnvironment, keychain: keychain).loadOrCreate()
        let other = try await IdentityStore(environment: secondEnvironment, keychain: keychain).loadOrCreate()
        #expect(first == restored)
        #expect(first.id != other.id && first.secret != other.secret)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: firstEnvironment.identityAccount,
                                   kSecReturnAttributes as String: true]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        #expect(status == errSecSuccess)
        let attributes = try #require(result as? [String: Any])
        #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }

    @Test func concurrentStoresAgreeOnOneOwner() async throws {
        let service = "endless-drawing.tests.\(UUID().uuidString)"
        let keychain = SystemIdentityKeychain(service: service)
        defer {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        }
        let environment = try M2TestSupport.environment()
        async let a = IdentityStore(environment: environment, keychain: keychain).loadOrCreate()
        async let b = IdentityStore(environment: environment, keychain: keychain).loadOrCreate()
        let (first, second) = try await (a, b)
        #expect(first == second)
    }

    @Test func lockedKeychainNeverGeneratesReplacementIdentity() async throws {
        let store = IdentityStore(environment: try M2TestSupport.environment(), keychain: RefusingKeychain(data: nil, failure: .keychain(errSecInteractionNotAllowed)))
        await #expect(throws: IdentityFailure.keychain(errSecInteractionNotAllowed)) { try await store.loadOrCreate() }
    }

    @Test func malformedRecordNeverGetsOverwritten() async throws {
        let store = IdentityStore(environment: try M2TestSupport.environment(), keychain: RefusingKeychain(data: Data("corrupted".utf8), failure: nil))
        await #expect(throws: IdentityFailure.corruptRecord) { try await store.loadOrCreate() }
    }

    private nonisolated struct RefusingKeychain: IdentityKeychain {
        let data: Data?
        let failure: IdentityFailure?
        func read(account: String) throws -> Data? {
            if let failure { throw failure }
            return data
        }
        func add(_ data: Data, account: String) throws -> Bool {
            Issue.record("Must not generate or overwrite an owner when Keychain is locked or corrupted")
            throw IdentityFailure.corruptRecord
        }
    }
}
