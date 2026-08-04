import Foundation
import Testing
@testable import LlamadockCore

@Suite("Managed runtime binary validation")
struct ManagedRuntimeBinaryValidatorTests {
    @Test("accepts arm64 Mach-O and rejects x86_64")
    func inspectsMachOArchitecture() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let arm64URL = root.appending(path: "arm64")
        let x86URL = root.appending(path: "x86")
        try thinMachO(cpuType: 0x0100_000c).write(
            to: arm64URL
        )
        try thinMachO(cpuType: 0x0100_0007).write(
            to: x86URL
        )

        #expect(
            try MachOBinaryInspector()
                .architecture(of: arm64URL)
                == .arm64
        )
        #expect(
            throws: ManagedRuntimeValidationError
                .unsupportedArchitecture(x86URL)
        ) {
            try MachOBinaryInspector()
                .architecture(of: x86URL)
        }
    }

    @Test("accepts a universal Mach-O that contains arm64")
    func inspectsUniversalMachO() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let universalURL = root.appending(path: "universal")
        try fatMachO(
            cpuTypes: [0x0100_0007, 0x0100_000c]
        )
        .write(to: universalURL)

        #expect(
            try MachOBinaryInspector()
                .architecture(of: universalURL)
                == .universal
        )
    }

    @Test("locates one executable llama and llama-server at bounded depth")
    func locatesBinaries() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let releaseRoot = root.appending(
            path: "llama-b10176",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: releaseRoot,
            withIntermediateDirectories: true
        )
        let llamaURL = releaseRoot.appending(path: "llama")
        let serverURL = releaseRoot.appending(
            path: "llama-server"
        )
        try thinMachO(cpuType: 0x0100_000c).write(to: llamaURL)
        try thinMachO(cpuType: 0x0100_000c).write(to: serverURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: llamaURL.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: serverURL.path
        )

        let pair = try ManagedRuntimeBinaryLocator()
            .locate(in: root)

        #expect(pair.llamaURL == llamaURL)
        #expect(pair.serverURL == serverURL)
        #expect(
            FileManager.default.isExecutableFile(
                atPath: llamaURL.path
            )
        )
    }

    @Test("builds a record only after runtime probe validation")
    func validatesPreparedRuntime() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let extractedRoot = root.appending(
            path: "extracted",
            directoryHint: .isDirectory
        )
        let releaseRoot = extractedRoot.appending(
            path: "llama-b10176",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: releaseRoot,
            withIntermediateDirectories: true
        )
        for name in ["llama", "llama-server"] {
            let url = releaseRoot.appending(path: name)
            try thinMachO(cpuType: 0x0100_000c).write(to: url)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: url.path
            )
        }
        let intendedInstallDirectory = root.appending(
            path: "b10176-macos-arm64",
            directoryHint: .isDirectory
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let validator = PreparedManagedRuntimeValidator(
            runtimeProbe: ValidRuntimeProbe()
        )

        let record = try await validator.validate(
            extractedRoot: extractedRoot,
            intendedInstallDirectory: intendedInstallDirectory,
            release: makeRelease(),
            archiveSHA256: String(repeating: "a", count: 64),
            now: now
        )

        #expect(record.id == "managed:b10176:macos-arm64")
        #expect(record.architecture == .arm64)
        #expect(record.installDirectory == intendedInstallDirectory)
        #expect(
            record.llamaURL.path
                == intendedInstallDirectory
                    .appending(path: "llama-b10176/llama")
                    .path
        )
        #expect(
            record.serverURL.path
                == intendedInstallDirectory
                    .appending(path: "llama-b10176/llama-server")
                    .path
        )
        #expect(record.installedAt == now)
        #expect(record.validatedAt == now)
        #expect(record.versionOutput == "version: 10176")
        #expect(
            record.capabilities?.supportedFlags.contains(
                "--model"
            ) == true
        )
    }

    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appending(
                path: "LlamadockBinaryTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
    }

    private func thinMachO(
        cpuType: UInt32
    ) -> Data {
        var bytes: [UInt8] = [
            0xcf, 0xfa, 0xed, 0xfe,
        ]
        bytes.append(contentsOf: [
            UInt8(cpuType & 0xff),
            UInt8((cpuType >> 8) & 0xff),
            UInt8((cpuType >> 16) & 0xff),
            UInt8((cpuType >> 24) & 0xff),
        ])
        bytes.append(contentsOf: repeatElement(0, count: 24))
        return Data(bytes)
    }

    private func fatMachO(
        cpuTypes: [UInt32]
    ) -> Data {
        var bytes: [UInt8] = [
            0xca, 0xfe, 0xba, 0xbe,
        ]
        appendBigEndian(
            UInt32(cpuTypes.count),
            to: &bytes
        )
        for cpuType in cpuTypes {
            appendBigEndian(cpuType, to: &bytes)
            bytes.append(
                contentsOf: repeatElement(0, count: 16)
            )
        }
        return Data(bytes)
    }

    private func appendBigEndian(
        _ value: UInt32,
        to bytes: inout [UInt8]
    ) {
        bytes.append(
            contentsOf: [
                UInt8((value >> 24) & 0xff),
                UInt8((value >> 16) & 0xff),
                UInt8((value >> 8) & 0xff),
                UInt8(value & 0xff),
            ]
        )
    }

    private func makeRelease() -> ManagedRuntimeRelease {
        ManagedRuntimeRelease(
            buildTag: LlamaBuildTag(
                tag: "b10176",
                build: 10_176
            ),
            publishedAt: Date(
                timeIntervalSince1970: 1_799_999_000
            ),
            asset: GitHubRuntimeReleaseAsset(
                id: 1,
                name: "llama-b10176-bin-macos-arm64.tar.gz",
                downloadURL: URL(
                    string: "https://github.com/ggml-org/llama.cpp/releases/download/b10176/runtime.tar.gz"
                )!,
                size: 10,
                contentType: "application/gzip",
                digest: nil
            )
        )
    }
}

private struct ValidRuntimeProbe: RuntimeCandidateProbing {
    func probe(
        _ candidate: RuntimeCandidate,
        detectedAt: Date
    ) async -> RuntimeProbeReport {
        RuntimeProbeReport(
            candidate: candidate,
            validation: .valid,
            serverVersionOutput: "version: 10176",
            llamaVersionOutput: "version: 10176",
            capabilities: RuntimeCapabilitiesParser().parse(
                "--model FNAME --host HOST --port PORT",
                detectedAt: detectedAt
            ),
            warning: nil
        )
    }
}
