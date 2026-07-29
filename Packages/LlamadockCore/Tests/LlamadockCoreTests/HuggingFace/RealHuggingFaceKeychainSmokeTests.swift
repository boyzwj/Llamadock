import Foundation
import Testing
@testable import LlamadockCore

@Suite("Real Hugging Face Keychain smoke")
struct RealHuggingFaceKeychainSmokeTests {
    @Test("writes, reads, and removes an isolated generic password")
    func roundTripsIsolatedItem() throws {
        guard
            ProcessInfo.processInfo.environment[
                "LLAMADOCK_KEYCHAIN_SMOKE"
            ] == "1"
        else {
            return
        }

        let service = KeychainHuggingFaceTokenStore.defaultService
            + ".smoke."
            + UUID().uuidString
        let store = KeychainHuggingFaceTokenStore(
            service: service
        )
        defer {
            try? store.deleteToken()
        }

        try store.saveToken("hf_llamadock_smoke_value")
        try store.saveToken("hf_llamadock_smoke_replacement")
        #expect(
            try store.token() == "hf_llamadock_smoke_replacement"
        )
        try store.deleteToken()
        #expect(try store.token() == nil)
    }
}
