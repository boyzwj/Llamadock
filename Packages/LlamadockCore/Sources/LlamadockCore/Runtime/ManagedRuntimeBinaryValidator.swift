import Foundation

public enum ManagedRuntimeValidationError:
    Error,
    Equatable,
    Sendable
{
    case malformedMachO(URL)
    case unsupportedArchitecture(URL)
    case binaryNotFound(String)
    case binaryNotExecutable(URL)
    case duplicateBinary(name: String, paths: [URL])
    case probeFailed(String)
    case versionDoesNotMatch(build: Int)
    case pathOutsideExtractionRoot(URL)
}

extension ManagedRuntimeValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .malformedMachO(let url):
            "The runtime binary is not a valid Mach-O file: \(url.path)"
        case .unsupportedArchitecture(let url):
            "The runtime binary does not contain arm64 code: \(url.path)"
        case .binaryNotFound(let name):
            "The runtime archive does not contain \(name)."
        case .binaryNotExecutable(let url):
            "The runtime binary is not executable: \(url.path)"
        case .duplicateBinary(let name, let paths):
            "The runtime archive contains multiple \(name) binaries: "
                + paths.map(\.path).joined(separator: ", ")
        case .probeFailed(let reason):
            "The extracted runtime failed validation: \(reason)"
        case .versionDoesNotMatch(let build):
            "The runtime version output does not match build \(build)."
        case .pathOutsideExtractionRoot(let url):
            "The runtime binary is outside the extraction root: \(url.path)"
        }
    }
}

public struct MachOBinaryInspector: Sendable {
    private static let cpuTypeArm64: UInt32 = 0x0100_000c

    public init() {}

    public func architecture(
        of url: URL
    ) throws -> ManagedRuntimeArchitecture {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 4_096) ?? Data()
        guard data.count >= 8 else {
            throw ManagedRuntimeValidationError.malformedMachO(url)
        }

        let magic = Array(data.prefix(4))
        if magic == [0xcf, 0xfa, 0xed, 0xfe]
            || magic == [0xce, 0xfa, 0xed, 0xfe]
        {
            return try thinArchitecture(
                data: data,
                byteOrder: .little,
                url: url
            )
        }
        if magic == [0xfe, 0xed, 0xfa, 0xcf]
            || magic == [0xfe, 0xed, 0xfa, 0xce]
        {
            return try thinArchitecture(
                data: data,
                byteOrder: .big,
                url: url
            )
        }
        if magic == [0xca, 0xfe, 0xba, 0xbe] {
            return try fatArchitecture(
                data: data,
                byteOrder: .big,
                is64Bit: false,
                url: url
            )
        }
        if magic == [0xbe, 0xba, 0xfe, 0xca] {
            return try fatArchitecture(
                data: data,
                byteOrder: .little,
                is64Bit: false,
                url: url
            )
        }
        if magic == [0xca, 0xfe, 0xba, 0xbf] {
            return try fatArchitecture(
                data: data,
                byteOrder: .big,
                is64Bit: true,
                url: url
            )
        }
        if magic == [0xbf, 0xba, 0xfe, 0xca] {
            return try fatArchitecture(
                data: data,
                byteOrder: .little,
                is64Bit: true,
                url: url
            )
        }

        throw ManagedRuntimeValidationError.malformedMachO(url)
    }

    private func thinArchitecture(
        data: Data,
        byteOrder: ByteOrder,
        url: URL
    ) throws -> ManagedRuntimeArchitecture {
        let cpuType = try readUInt32(
            data,
            offset: 4,
            byteOrder: byteOrder,
            url: url
        )
        guard cpuType == Self.cpuTypeArm64 else {
            throw ManagedRuntimeValidationError
                .unsupportedArchitecture(url)
        }
        return .arm64
    }

    private func fatArchitecture(
        data: Data,
        byteOrder: ByteOrder,
        is64Bit: Bool,
        url: URL
    ) throws -> ManagedRuntimeArchitecture {
        let count = try readUInt32(
            data,
            offset: 4,
            byteOrder: byteOrder,
            url: url
        )
        guard count > 0, count <= 128 else {
            throw ManagedRuntimeValidationError.malformedMachO(url)
        }

        let stride = is64Bit ? 32 : 20
        var hasArm64 = false
        for index in 0..<Int(count) {
            let cpuType = try readUInt32(
                data,
                offset: 8 + index * stride,
                byteOrder: byteOrder,
                url: url
            )
            hasArm64 = hasArm64
                || cpuType == Self.cpuTypeArm64
        }
        guard hasArm64 else {
            throw ManagedRuntimeValidationError
                .unsupportedArchitecture(url)
        }
        return count > 1 ? .universal : .arm64
    }

    private func readUInt32(
        _ data: Data,
        offset: Int,
        byteOrder: ByteOrder,
        url: URL
    ) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else {
            throw ManagedRuntimeValidationError.malformedMachO(url)
        }
        let bytes = data[offset..<(offset + 4)]
        switch byteOrder {
        case .little:
            return bytes.enumerated().reduce(0) { value, entry in
                value | UInt32(entry.element) << UInt32(entry.offset * 8)
            }
        case .big:
            return bytes.reduce(0) { value, byte in
                value << 8 | UInt32(byte)
            }
        }
    }

    private enum ByteOrder {
        case little
        case big
    }
}

public struct ManagedRuntimeBinaryPair: Equatable, Sendable {
    public let llamaURL: URL
    public let serverURL: URL

    public init(
        llamaURL: URL,
        serverURL: URL
    ) {
        self.llamaURL = llamaURL
        self.serverURL = serverURL
    }
}

public protocol PreparedManagedRuntimeValidating: Sendable {
    func validate(
        extractedRoot: URL,
        intendedInstallDirectory: URL,
        release: ManagedRuntimeRelease,
        archiveSHA256: String,
        now: Date
    ) async throws -> ManagedRuntimeRecord
}

public struct ManagedRuntimeBinaryLocator:
    @unchecked Sendable
{
    private let fileManager: FileManager
    private let maximumDepth: Int
    private let repairExecutableBits: Bool

    public init(
        fileManager: FileManager = .default,
        maximumDepth: Int = 4,
        repairExecutableBits: Bool = true
    ) {
        self.fileManager = fileManager
        self.maximumDepth = maximumDepth
        self.repairExecutableBits = repairExecutableBits
    }

    public func locate(
        in root: URL
    ) throws -> ManagedRuntimeBinaryPair {
        let candidates = try candidates(in: root)
        return ManagedRuntimeBinaryPair(
            llamaURL: try unique(
                named: "llama",
                candidates: candidates
            ),
            serverURL: try unique(
                named: "llama-server",
                candidates: candidates
            )
        )
    }

    private func candidates(
        in root: URL
    ) throws -> [URL] {
        let rootPath = root.standardizedFileURL.path
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else {
            return []
        }

        var matches: [URL] = []
        for case let url as URL in enumerator {
            let relativePath = String(
                url.standardizedFileURL.path
                    .dropFirst(rootPath.count)
                    .drop(while: { $0 == "/" })
            )
            let depth = relativePath.split(separator: "/").count
            let values = try url.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ]
            )
            if depth > maximumDepth {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard
                url.lastPathComponent == "llama"
                    || url.lastPathComponent == "llama-server",
                values.isRegularFile == true,
                values.isSymbolicLink != true
            else {
                continue
            }
            try ensureExecutable(url)
            matches.append(url.standardizedFileURL)
        }
        return matches
    }

    private func ensureExecutable(
        _ url: URL
    ) throws {
        guard !fileManager.isExecutableFile(atPath: url.path) else {
            return
        }
        guard repairExecutableBits else {
            throw ManagedRuntimeValidationError
                .binaryNotExecutable(url)
        }

        let attributes = try fileManager.attributesOfItem(
            atPath: url.path
        )
        let permissions = (attributes[.posixPermissions] as? NSNumber)?
            .intValue
            ?? 0o644
        try fileManager.setAttributes(
            [.posixPermissions: permissions | 0o111],
            ofItemAtPath: url.path
        )
        guard fileManager.isExecutableFile(atPath: url.path) else {
            throw ManagedRuntimeValidationError
                .binaryNotExecutable(url)
        }
    }

    private func unique(
        named name: String,
        candidates: [URL]
    ) throws -> URL {
        let matches = candidates
            .filter { $0.lastPathComponent == name }
            .sorted { $0.path < $1.path }
        guard let match = matches.first else {
            throw ManagedRuntimeValidationError.binaryNotFound(name)
        }
        guard matches.count == 1 else {
            throw ManagedRuntimeValidationError.duplicateBinary(
                name: name,
                paths: matches
            )
        }
        return match
    }
}

public struct PreparedManagedRuntimeValidator:
    PreparedManagedRuntimeValidating,
    Sendable
{
    private let locator: ManagedRuntimeBinaryLocator
    private let binaryInspector: MachOBinaryInspector
    private let runtimeProbe: any RuntimeCandidateProbing

    public init(
        locator: ManagedRuntimeBinaryLocator =
            ManagedRuntimeBinaryLocator(),
        binaryInspector: MachOBinaryInspector =
            MachOBinaryInspector(),
        runtimeProbe: any RuntimeCandidateProbing =
            RuntimeProbe(timeoutSeconds: 30)
    ) {
        self.locator = locator
        self.binaryInspector = binaryInspector
        self.runtimeProbe = runtimeProbe
    }

    public func validate(
        extractedRoot: URL,
        intendedInstallDirectory: URL,
        release: ManagedRuntimeRelease,
        archiveSHA256: String,
        now: Date = Date()
    ) async throws -> ManagedRuntimeRecord {
        let binaries = try locator.locate(in: extractedRoot)
        let llamaArchitecture = try binaryInspector.architecture(
            of: binaries.llamaURL
        )
        let serverArchitecture = try binaryInspector.architecture(
            of: binaries.serverURL
        )
        let architecture: ManagedRuntimeArchitecture =
            llamaArchitecture == .universal
                && serverArchitecture == .universal
            ? .universal
            : .arm64

        let candidate = RuntimeCandidate(
            source: .managed,
            llamaURL: binaries.llamaURL,
            serverURL: binaries.serverURL
        )
        let report = await runtimeProbe.probe(
            candidate,
            detectedAt: now
        )
        guard report.validation == .valid else {
            let reason: String
            if case .invalid(let value) = report.validation {
                reason = value
            } else {
                reason = "unknown validation failure"
            }
            throw ManagedRuntimeValidationError.probeFailed(reason)
        }
        guard
            let serverVersion = report.serverVersionOutput,
            let llamaVersion = report.llamaVersionOutput
        else {
            throw ManagedRuntimeValidationError.probeFailed(
                "Both llama and llama-server must return a version."
            )
        }
        let buildString = String(release.build)
        guard
            serverVersion.contains(buildString),
            llamaVersion.contains(buildString)
        else {
            throw ManagedRuntimeValidationError
                .versionDoesNotMatch(build: release.build)
        }

        let finalLlamaURL = try finalURL(
            for: binaries.llamaURL,
            extractedRoot: extractedRoot,
            installDirectory: intendedInstallDirectory
        )
        let finalServerURL = try finalURL(
            for: binaries.serverURL,
            extractedRoot: extractedRoot,
            installDirectory: intendedInstallDirectory
        )

        return ManagedRuntimeRecord(
            id: "managed:\(release.tag):macos-arm64",
            tag: release.tag,
            build: release.build,
            architecture: architecture,
            installDirectory: intendedInstallDirectory,
            llamaURL: finalLlamaURL,
            serverURL: finalServerURL,
            installedAt: now,
            validatedAt: now,
            versionOutput: serverVersion,
            archiveSHA256: archiveSHA256
        )
    }

    private func finalURL(
        for binaryURL: URL,
        extractedRoot: URL,
        installDirectory: URL
    ) throws -> URL {
        let rootPath = extractedRoot.standardizedFileURL.path
        let binaryPath = binaryURL.standardizedFileURL.path
        guard binaryPath.hasPrefix(rootPath + "/") else {
            throw ManagedRuntimeValidationError
                .pathOutsideExtractionRoot(binaryURL)
        }
        let relativePath = String(
            binaryPath.dropFirst(rootPath.count + 1)
        )
        return installDirectory.appending(
            path: relativePath,
            directoryHint: .notDirectory
        )
    }
}
