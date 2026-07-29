import Foundation

public enum ManagedRuntimeArchitecture:
    String,
    Codable,
    Equatable,
    Sendable
{
    case arm64
    case universal
}

public struct ManagedRuntimeRecord:
    Codable,
    Equatable,
    Identifiable,
    Sendable
{
    public let id: String
    public let tag: String
    public let build: Int
    public let architecture: ManagedRuntimeArchitecture
    public let installDirectory: URL
    public let llamaURL: URL
    public let serverURL: URL
    public let installedAt: Date
    public let validatedAt: Date
    public let versionOutput: String
    public let archiveSHA256: String

    public init(
        id: String,
        tag: String,
        build: Int,
        architecture: ManagedRuntimeArchitecture,
        installDirectory: URL,
        llamaURL: URL,
        serverURL: URL,
        installedAt: Date,
        validatedAt: Date,
        versionOutput: String,
        archiveSHA256: String
    ) {
        self.id = id
        self.tag = tag
        self.build = build
        self.architecture = architecture
        self.installDirectory = installDirectory.standardizedFileURL
        self.llamaURL = llamaURL.standardizedFileURL
        self.serverURL = serverURL.standardizedFileURL
        self.installedAt = installedAt
        self.validatedAt = validatedAt
        self.versionOutput = versionOutput
        self.archiveSHA256 = archiveSHA256
    }
}

public struct ManagedRuntimeRegistrySnapshot:
    Equatable,
    Sendable
{
    public let installations: [ManagedRuntimeRecord]
    public let activeRuntimeID: String?
    public let previousRuntimeID: String?

    public init(
        installations: [ManagedRuntimeRecord],
        activeRuntimeID: String?,
        previousRuntimeID: String?
    ) {
        self.installations = installations
        self.activeRuntimeID = activeRuntimeID
        self.previousRuntimeID = previousRuntimeID
    }
}

public enum ManagedRuntimeRegistryError:
    Error,
    Equatable,
    Sendable
{
    case unsupportedSchemaVersion(Int)
    case invalidRecord(id: String, reason: String)
    case pathOutsideRuntimeRoot(URL)
    case runtimeNotFound(String)
    case noPreviousRuntime
}

extension ManagedRuntimeRegistryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            "Unsupported managed runtime registry schema: \(version)"
        case .invalidRecord(let id, let reason):
            "Managed runtime \(id) is invalid: \(reason)"
        case .pathOutsideRuntimeRoot(let url):
            "Managed runtime path is outside the app-owned root: \(url.path)"
        case .runtimeNotFound(let id):
            "Managed runtime was not found: \(id)"
        case .noPreviousRuntime:
            "No previous managed runtime is available for rollback."
        }
    }
}

public protocol ManagedRuntimeRegistering: Sendable {
    func snapshot() async throws -> ManagedRuntimeRegistrySnapshot
    func register(_ record: ManagedRuntimeRecord) async throws
    func activate(_ id: String) async throws
    func rollback() async throws
}

public actor JSONManagedRuntimeRegistry:
    ManagedRuntimeRegistering
{
    private static let currentSchemaVersion = 1

    private let fileURL: URL
    private let runtimesRoot: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        fileURL: URL,
        runtimesRoot: URL,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.runtimesRoot = runtimesRoot.standardizedFileURL
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func snapshot() throws -> ManagedRuntimeRegistrySnapshot {
        let document = try loadDocument()
        return ManagedRuntimeRegistrySnapshot(
            installations: document.installations,
            activeRuntimeID: document.activeRuntimeID,
            previousRuntimeID: document.previousRuntimeID
        )
    }

    public func register(
        _ record: ManagedRuntimeRecord
    ) throws {
        try validate(record)
        var document = try loadDocument()
        document.installations.removeAll { $0.id == record.id }
        document.installations.append(record)
        document.installations.sort { lhs, rhs in
            if lhs.build == rhs.build {
                return lhs.id < rhs.id
            }
            return lhs.build < rhs.build
        }
        try save(document)
    }

    public func activate(
        _ id: String
    ) throws {
        var document = try loadDocument()
        guard document.installations.contains(
            where: { $0.id == id }
        ) else {
            throw ManagedRuntimeRegistryError.runtimeNotFound(id)
        }
        guard document.activeRuntimeID != id else {
            return
        }

        document.previousRuntimeID = document.activeRuntimeID
        document.activeRuntimeID = id
        try save(document)
    }

    public func rollback() throws {
        var document = try loadDocument()
        guard
            let previous = document.previousRuntimeID,
            document.installations.contains(
                where: { $0.id == previous }
            )
        else {
            throw ManagedRuntimeRegistryError.noPreviousRuntime
        }

        let active = document.activeRuntimeID
        document.activeRuntimeID = previous
        document.previousRuntimeID = active
        try save(document)
    }

    private func loadDocument() throws -> RegistryDocument {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return RegistryDocument(
                schemaVersion: Self.currentSchemaVersion,
                installations: [],
                activeRuntimeID: nil,
                previousRuntimeID: nil
            )
        }

        let document = try decoder.decode(
            RegistryDocument.self,
            from: Data(contentsOf: fileURL)
        )
        guard
            document.schemaVersion == Self.currentSchemaVersion
        else {
            throw ManagedRuntimeRegistryError
                .unsupportedSchemaVersion(
                    document.schemaVersion
                )
        }
        try validate(document)
        return document
    }

    private func validate(
        _ document: RegistryDocument
    ) throws {
        var ids = Set<String>()
        for record in document.installations {
            try validate(record)
            guard ids.insert(record.id).inserted else {
                throw ManagedRuntimeRegistryError.invalidRecord(
                    id: record.id,
                    reason: "duplicate ID"
                )
            }
        }
        for id in [
            document.activeRuntimeID,
            document.previousRuntimeID,
        ].compactMap({ $0 }) {
            guard ids.contains(id) else {
                throw ManagedRuntimeRegistryError.runtimeNotFound(id)
            }
        }
        if
            let active = document.activeRuntimeID,
            active == document.previousRuntimeID
        {
            throw ManagedRuntimeRegistryError.invalidRecord(
                id: active,
                reason: "active and previous must differ"
            )
        }
    }

    private func validate(
        _ record: ManagedRuntimeRecord
    ) throws {
        guard
            record.build > 0,
            record.tag == "b\(record.build)",
            record.id
                == "managed:\(record.tag):macos-arm64"
        else {
            throw ManagedRuntimeRegistryError.invalidRecord(
                id: record.id,
                reason: "ID, tag, build, and architecture do not match"
            )
        }
        guard
            record.archiveSHA256.count == 64,
            record.archiveSHA256.allSatisfy(\.isHexDigit)
        else {
            throw ManagedRuntimeRegistryError.invalidRecord(
                id: record.id,
                reason: "archive SHA-256 is invalid"
            )
        }

        let installDirectory = record.installDirectory
            .standardizedFileURL
        guard
            installDirectory.deletingLastPathComponent()
                == runtimesRoot
        else {
            throw ManagedRuntimeRegistryError
                .pathOutsideRuntimeRoot(installDirectory)
        }
        for url in [record.llamaURL, record.serverURL] {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(installDirectory.path + "/") else {
                throw ManagedRuntimeRegistryError
                    .pathOutsideRuntimeRoot(url)
            }
        }
    }

    private func save(
        _ document: RegistryDocument
    ) throws {
        try validate(document)
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(document)
        try atomicallyWrite(data)
    }

    private func atomicallyWrite(
        _ data: Data
    ) throws {
        let directory = fileURL.deletingLastPathComponent()
        let temporaryURL = directory.appending(
            path: ".registry.\(UUID().uuidString).tmp",
            directoryHint: .notDirectory
        )

        do {
            try data.write(
                to: temporaryURL,
                options: .withoutOverwriting
            )
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(
                    fileURL,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try fileManager.moveItem(
                    at: temporaryURL,
                    to: fileURL
                )
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }
}

private struct RegistryDocument: Codable {
    let schemaVersion: Int
    var installations: [ManagedRuntimeRecord]
    var activeRuntimeID: String?
    var previousRuntimeID: String?
}
