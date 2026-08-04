import Darwin
import Foundation

public struct ServerOwnershipRecord:
    Codable,
    Equatable,
    Sendable
{
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let ownerProcessIdentifier: Int32
    public let processIdentifier: Int32
    public let processStartTime: Date
    public let executableURL: URL
    public let runtimeID: String
    public let profileID: UUID
    public let host: String
    public let port: UInt16

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        ownerProcessIdentifier: Int32,
        processIdentifier: Int32,
        processStartTime: Date,
        executableURL: URL,
        runtimeID: String,
        profileID: UUID,
        host: String,
        port: UInt16
    ) {
        self.schemaVersion = schemaVersion
        self.ownerProcessIdentifier = ownerProcessIdentifier
        self.processIdentifier = processIdentifier
        self.processStartTime = processStartTime
        self.executableURL = executableURL.standardizedFileURL
        self.runtimeID = runtimeID
        self.profileID = profileID
        self.host = host
        self.port = port
    }
}

public protocol ServerOwnershipStoring: Sendable {
    func load() async throws -> ServerOwnershipRecord?
    func save(_ record: ServerOwnershipRecord) async throws
    func remove() async throws
}

public actor JSONServerOwnershipStore: ServerOwnershipStoring {
    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        fileURL: URL,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
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

    public func load() throws -> ServerOwnershipRecord? {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let record = try decoder.decode(
            ServerOwnershipRecord.self,
            from: Data(contentsOf: fileURL)
        )
        guard
            record.schemaVersion
                == ServerOwnershipRecord.currentSchemaVersion
        else {
            throw ServerOwnershipStoreError.unsupportedSchemaVersion(
                record.schemaVersion
            )
        }
        return record
    }

    public func save(_ record: ServerOwnershipRecord) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(record).write(
            to: fileURL,
            options: .atomic
        )
    }

    public func remove() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }
        try fileManager.removeItem(at: fileURL)
    }
}

public enum ServerOwnershipStoreError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
}

extension ServerOwnershipStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            "Unsupported server ownership schema: \(version)"
        }
    }
}

public struct ServerProcessIdentity: Equatable, Sendable {
    public let processIdentifier: Int32
    public let parentProcessIdentifier: Int32
    public let processStartTime: Date
    public let executableURL: URL

    public init(
        processIdentifier: Int32,
        parentProcessIdentifier: Int32,
        processStartTime: Date,
        executableURL: URL
    ) {
        self.processIdentifier = processIdentifier
        self.parentProcessIdentifier = parentProcessIdentifier
        self.processStartTime = processStartTime
        self.executableURL = executableURL.standardizedFileURL
    }
}

public protocol ServerProcessInspecting: Sendable {
    func identity(
        processIdentifier: Int32
    ) -> ServerProcessIdentity?
    func terminate(processIdentifier: Int32)
    func forceTerminate(processIdentifier: Int32)
}

public struct DarwinServerProcessInspector: ServerProcessInspecting {
    public init() {}

    public func identity(
        processIdentifier: Int32
    ) -> ServerProcessIdentity? {
        guard processIdentifier > 1 else {
            return nil
        }

        var info = proc_bsdinfo()
        let infoSize = proc_pidinfo(
            processIdentifier,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_bsdinfo>.size)
        )
        guard infoSize == MemoryLayout<proc_bsdinfo>.size else {
            return nil
        }

        var pathBuffer = [CChar](repeating: 0, count: 4_096)
        let pathLength = proc_pidpath(
            processIdentifier,
            &pathBuffer,
            UInt32(pathBuffer.count)
        )
        guard pathLength > 0 else {
            return nil
        }

        let startTime = Date(
            timeIntervalSince1970:
                TimeInterval(info.pbi_start_tvsec)
                    + TimeInterval(info.pbi_start_tvusec) / 1_000_000
        )
        let pathBytes = pathBuffer.prefix { $0 != 0 }.map {
            UInt8(bitPattern: $0)
        }
        return ServerProcessIdentity(
            processIdentifier: processIdentifier,
            parentProcessIdentifier: Int32(info.pbi_ppid),
            processStartTime: startTime,
            executableURL: URL(
                filePath: String(decoding: pathBytes, as: UTF8.self),
                directoryHint: .notDirectory
            )
        )
    }

    public func terminate(processIdentifier: Int32) {
        kill(processIdentifier, SIGTERM)
    }

    public func forceTerminate(processIdentifier: Int32) {
        kill(processIdentifier, SIGKILL)
    }
}

public enum ServerOwnershipRecoveryResult: Equatable, Sendable {
    case noRecord
    case staleRecordRemoved
    case orphanTerminated(processIdentifier: Int32)
    case failed(reason: String)
}
