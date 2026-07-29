import Foundation
import Security

public enum HuggingFaceTokenStoreError:
    Error,
    Equatable,
    Sendable
{
    case emptyToken
    case invalidToken
    case invalidStoredData
    case keychain(status: Int32, message: String)
}

extension HuggingFaceTokenStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyToken:
            "Enter a Hugging Face token."
        case .invalidToken:
            "The Hugging Face token contains whitespace or is too long."
        case .invalidStoredData:
            "The Hugging Face token in Keychain is not valid UTF-8."
        case .keychain(let status, let message):
            "Keychain error \(status): \(message)"
        }
    }
}

public protocol HuggingFaceTokenStoring: Sendable {
    func token() throws -> String?
    func saveToken(_ token: String) throws
    func deleteToken() throws
}

public protocol SecureCredentialBackend: Sendable {
    func data(
        service: String,
        account: String
    ) throws -> Data?

    func save(
        _ data: Data,
        service: String,
        account: String
    ) throws

    func delete(
        service: String,
        account: String
    ) throws
}

public struct KeychainHuggingFaceTokenStore:
    HuggingFaceTokenStoring,
    Sendable
{
    public static let defaultService =
        "io.github.boyzwj.LlamaDock.huggingface"
    public static let defaultAccount = "access-token"

    private let backend: any SecureCredentialBackend
    private let service: String
    private let account: String

    public init(
        backend: any SecureCredentialBackend = KeychainCredentialBackend(),
        service: String = Self.defaultService,
        account: String = Self.defaultAccount
    ) {
        self.backend = backend
        self.service = service
        self.account = account
    }

    public func token() throws -> String? {
        guard
            let data = try backend.data(
                service: service,
                account: account
            )
        else {
            return nil
        }
        guard let value = String(data: data, encoding: .utf8) else {
            throw HuggingFaceTokenStoreError.invalidStoredData
        }
        return try normalizedToken(value)
    }

    public func saveToken(
        _ token: String
    ) throws {
        let normalized = try normalizedToken(token)
        try backend.save(
            Data(normalized.utf8),
            service: service,
            account: account
        )
    }

    public func deleteToken() throws {
        try backend.delete(
            service: service,
            account: account
        )
    }

    private func normalizedToken(
        _ token: String
    ) throws -> String {
        let normalized = token.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalized.isEmpty else {
            throw HuggingFaceTokenStoreError.emptyToken
        }
        guard
            normalized.utf8.count <= 4_096,
            !normalized.contains(where: {
                $0.isWhitespace || $0.isNewline
            })
        else {
            throw HuggingFaceTokenStoreError.invalidToken
        }
        return normalized
    }
}

public struct KeychainCredentialBackend:
    SecureCredentialBackend,
    Sendable
{
    public init() {}

    public func data(
        service: String,
        account: String
    ) throws -> Data? {
        var query = baseQuery(
            service: service,
            account: account
        )
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            query as CFDictionary,
            &result
        )
        if status == errSecItemNotFound {
            return nil
        }
        try validate(status)
        guard let data = result as? Data else {
            throw HuggingFaceTokenStoreError.invalidStoredData
        }
        return data
    }

    public func save(
        _ data: Data,
        service: String,
        account: String
    ) throws {
        let query = baseQuery(
            service: service,
            account: account
        )
        var item = query
        item[kSecValueData as String] = data
        let addStatus = SecItemAdd(
            item as CFDictionary,
            nil
        )
        if addStatus != errSecDuplicateItem {
            try validate(addStatus)
            return
        }

        let attributes: [String: Any] = [
            kSecValueData as String: data,
        ]
        try validate(
            SecItemUpdate(
                query as CFDictionary,
                attributes as CFDictionary
            )
        )
    }

    public func delete(
        service: String,
        account: String
    ) throws {
        let status = SecItemDelete(
            baseQuery(
                service: service,
                account: account
            ) as CFDictionary
        )
        if status == errSecItemNotFound {
            return
        }
        try validate(status)
    }

    private func baseQuery(
        service: String,
        account: String
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func validate(
        _ status: OSStatus
    ) throws {
        guard status == errSecSuccess else {
            let message = SecCopyErrorMessageString(
                status,
                nil
            ) as String? ?? "Unknown Keychain failure"
            throw HuggingFaceTokenStoreError.keychain(
                status: status,
                message: message
            )
        }
    }
}
