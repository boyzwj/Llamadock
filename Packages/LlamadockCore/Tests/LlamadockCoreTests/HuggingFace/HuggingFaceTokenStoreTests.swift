import Foundation
import Testing
@testable import LlamadockCore

@Suite("Hugging Face Keychain token store")
struct HuggingFaceTokenStoreTests {
    @Test("normalizes and round-trips a token through the secure backend")
    func roundTripsToken() throws {
        let backend = InMemoryCredentialBackend()
        let store = KeychainHuggingFaceTokenStore(
            backend: backend
        )

        try store.saveToken("  hf_test_value  \n")

        #expect(try store.token() == "hf_test_value")
        #expect(
            backend.data(
                for: KeychainHuggingFaceTokenStore.defaultService,
                account: KeychainHuggingFaceTokenStore.defaultAccount
            ) == Data("hf_test_value".utf8)
        )
    }

    @Test("rejects empty, whitespace-bearing, and oversized tokens")
    func rejectsInvalidTokens() {
        let store = KeychainHuggingFaceTokenStore(
            backend: InMemoryCredentialBackend()
        )

        #expect(throws: HuggingFaceTokenStoreError.emptyToken) {
            try store.saveToken(" \n ")
        }
        #expect(throws: HuggingFaceTokenStoreError.invalidToken) {
            try store.saveToken("hf_not valid")
        }
        #expect(throws: HuggingFaceTokenStoreError.invalidToken) {
            try store.saveToken(
                String(repeating: "x", count: 4_097)
            )
        }
    }

    @Test("deletes idempotently and rejects corrupt stored data")
    func deletesAndRejectsCorruption() throws {
        let backend = InMemoryCredentialBackend()
        let store = KeychainHuggingFaceTokenStore(
            backend: backend
        )
        backend.set(
            Data([0xFF]),
            service: KeychainHuggingFaceTokenStore.defaultService,
            account: KeychainHuggingFaceTokenStore.defaultAccount
        )

        #expect(
            throws: HuggingFaceTokenStoreError.invalidStoredData
        ) {
            try store.token()
        }

        try store.deleteToken()
        try store.deleteToken()
        #expect(try store.token() == nil)
    }
}

private final class InMemoryCredentialBackend:
    SecureCredentialBackend,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func data(
        service: String,
        account: String
    ) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[key(service: service, account: account)]
    }

    func save(
        _ data: Data,
        service: String,
        account: String
    ) throws {
        set(data, service: service, account: account)
    }

    func delete(
        service: String,
        account: String
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(
            forKey: key(service: service, account: account)
        )
    }

    func set(
        _ data: Data,
        service: String,
        account: String
    ) {
        lock.lock()
        defer { lock.unlock() }
        values[key(service: service, account: account)] = data
    }

    func data(
        for service: String,
        account: String
    ) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[key(service: service, account: account)]
    }

    private func key(
        service: String,
        account: String
    ) -> String {
        "\(service)\u{0}\(account)"
    }
}
