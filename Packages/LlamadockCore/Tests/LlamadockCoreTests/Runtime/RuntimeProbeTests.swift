import Foundation
import Testing
@testable import LlamadockCore

@Suite("Runtime probe")
struct RuntimeProbeTests {
    @Test("runs version and help against the absolute server executable")
    func probesVersionAndCapabilities() async throws {
        let detectedAt = Date(timeIntervalSince1970: 1_785_315_100)
        let runner = QueueProcessRunner(
            responses: [
                ProcessResult(
                    terminationStatus: 0,
                    standardOutput: "llama-server version b1234",
                    standardError: ""
                ),
                ProcessResult(
                    terminationStatus: 0,
                    standardOutput: "--model FNAME\n--metrics\n--no-webui",
                    standardError: ""
                ),
            ]
        )
        let serverURL = URL(filePath: "/custom/bin/llama-server")
        let probe = RuntimeProbe(processRunner: runner)

        let report = await probe.probe(
            RuntimeCandidate(
                source: .custom,
                llamaURL: nil,
                serverURL: serverURL
            ),
            detectedAt: detectedAt
        )

        #expect(report.validation == .valid)
        #expect(report.serverVersionOutput == "llama-server version b1234")
        #expect(report.capabilities?.supportedFlags.contains("--model") == true)
        #expect(report.capabilities?.supportsMetrics == true)
        #expect(report.capabilities?.detectedAt == detectedAt)
        let invocations = await runner.recordedInvocations()
        #expect(invocations.map(\.executableURL) == [serverURL, serverURL])
        #expect(
            invocations.map(\.arguments)
                == [
                    ["--version"],
                    ["--help"],
                ]
        )
    }

    @Test("falls back with devices disabled after device initialization fails")
    func fallsBackWithDevicesDisabled() async {
        let runner = QueueProcessRunner(
            responses: [
                ProcessResult(
                    terminationStatus: 1,
                    standardOutput: "",
                    standardError: "failed to initialize Metal device"
                ),
                ProcessResult(
                    terminationStatus: 0,
                    standardOutput: "llama-server version b999",
                    standardError: ""
                ),
                ProcessResult(
                    terminationStatus: 0,
                    standardOutput: "--model FNAME\n--host HOST\n--port PORT",
                    standardError: ""
                ),
            ]
        )
        let probe = RuntimeProbe(processRunner: runner)

        let report = await probe.probe(customCandidate)

        #expect(report.validation == .valid)
        #expect(report.serverVersionOutput == "llama-server version b999")
        #expect(report.capabilities?.detection == .detected)
        #expect(
            await runner.recordedInvocations().map(\.arguments)
                == [
                    ["--version"],
                    ["--device", "none", "--version"],
                    ["--help"],
                ]
        )
    }

    @Test("reports a failed version probe with visible stderr")
    func reportsVersionFailure() async {
        let runner = QueueProcessRunner(
            responses: [
                ProcessResult(
                    terminationStatus: 2,
                    standardOutput: "",
                    standardError: "dyld: missing library"
                )
            ]
        )
        let probe = RuntimeProbe(processRunner: runner)

        let report = await probe.probe(customCandidate)

        #expect(
            report.validation
                == .invalid(reason: "Version probe exited with code 2: dyld: missing library")
        )
        #expect(report.capabilities == nil)
    }

    @Test("reports a timeout without attempting help")
    func reportsTimeout() async {
        let runner = QueueProcessRunner(
            responses: [
                ProcessResult(
                    terminationStatus: 9,
                    standardOutput: "",
                    standardError: "",
                    timedOut: true
                ),
                ProcessResult(
                    terminationStatus: 9,
                    standardOutput: "",
                    standardError: "",
                    timedOut: true
                )
            ]
        )
        let probe = RuntimeProbe(processRunner: runner)

        let report = await probe.probe(customCandidate)

        #expect(report.validation == .invalid(reason: "Version probe timed out after 5 seconds."))
        #expect(
            await runner.recordedInvocations().map(\.arguments)
                == [
                    ["--version"],
                    ["--device", "none", "--version"],
                ]
        )
    }

    @Test("retries a timed out ordinary probe with devices disabled")
    func retriesTimedOutVersionProbe() async {
        let runner = QueueProcessRunner(
            responses: [
                ProcessResult(
                    terminationStatus: 9,
                    standardOutput: "",
                    standardError: "",
                    timedOut: true
                ),
                ProcessResult(
                    terminationStatus: 0,
                    standardOutput: "llama-server version b1234",
                    standardError: ""
                ),
                ProcessResult(
                    terminationStatus: 0,
                    standardOutput: "--model FNAME\n--models-preset PATH",
                    standardError: ""
                ),
            ]
        )
        let probe = RuntimeProbe(processRunner: runner)

        let report = await probe.probe(customCandidate)

        #expect(report.validation == .valid)
        #expect(report.serverVersionOutput == "llama-server version b1234")
        #expect(
            await runner.recordedInvocations().map(\.arguments)
                == [
                    ["--version"],
                    ["--device", "none", "--version"],
                    ["--help"],
                ]
        )
    }

    @Test("keeps a valid version when help cannot be parsed")
    func keepsValidVersionWithUnknownCapabilities() async {
        let runner = QueueProcessRunner(
            responses: [
                ProcessResult(
                    terminationStatus: 0,
                    standardOutput: "version b1234",
                    standardError: ""
                ),
                ProcessResult(
                    terminationStatus: 1,
                    standardOutput: "",
                    standardError: "help unavailable"
                ),
            ]
        )
        let probe = RuntimeProbe(processRunner: runner)

        let report = await probe.probe(customCandidate)

        #expect(report.validation == .valid)
        #expect(report.capabilities?.detection == .unknown)
        #expect(report.warning == "Capability probe exited with code 1: help unavailable")
    }

    @Test("rejects a candidate without llama-server")
    func rejectsMissingServer() async {
        let runner = QueueProcessRunner(responses: [])
        let probe = RuntimeProbe(processRunner: runner)

        let report = await probe.probe(
            RuntimeCandidate(
                source: .custom,
                llamaURL: URL(filePath: "/custom/bin/llama"),
                serverURL: nil
            )
        )

        #expect(report.validation == .invalid(reason: "llama-server executable was not found."))
        #expect(await runner.recordedInvocations().isEmpty)
    }

    @Test("restores a validated managed runtime without launching it")
    func restoresValidatedManagedRuntime() async {
        let runner = QueueProcessRunner(responses: [])
        let probe = RuntimeProbe(processRunner: runner)
        let root = URL(
            filePath: "/managed/b1234-macos-arm64",
            directoryHint: .isDirectory
        )
        let llamaURL = root.appending(path: "llama")
        let serverURL = root.appending(path: "llama-server")
        let validatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let capabilities = RuntimeCapabilitiesParser().parse(
            "--models-preset PATH --host HOST --port PORT",
            detectedAt: validatedAt
        )
        let record = ManagedRuntimeRecord(
            id: "managed:b1234:macos-arm64",
            tag: "b1234",
            build: 1_234,
            architecture: .arm64,
            installDirectory: root,
            llamaURL: llamaURL,
            serverURL: serverURL,
            installedAt: validatedAt,
            validatedAt: validatedAt,
            versionOutput: "version: 1234",
            archiveSHA256: String(repeating: "a", count: 64),
            capabilities: capabilities
        )

        let report = probe.restoreValidatedManagedRuntime(
            record,
            fileSystem: ProbeFileSystem(
                executables: [llamaURL, serverURL]
            )
        )

        #expect(report.validation == .valid)
        #expect(report.serverVersionOutput == record.versionOutput)
        #expect(report.capabilities == capabilities)
        #expect(report.warning == nil)
        #expect(await runner.recordedInvocations().isEmpty)
    }

    private var customCandidate: RuntimeCandidate {
        RuntimeCandidate(
            source: .custom,
            llamaURL: nil,
            serverURL: URL(filePath: "/custom/bin/llama-server")
        )
    }
}

private actor QueueProcessRunner: ProcessRunning {
    private var responses: [ProcessResult]
    private var invocations: [ProcessInvocation] = []

    init(responses: [ProcessResult]) {
        self.responses = responses
    }

    func run(
        _ invocation: ProcessInvocation,
        timeout: Duration
    ) async throws -> ProcessResult {
        invocations.append(invocation)
        return responses.removeFirst()
    }

    func recordedInvocations() -> [ProcessInvocation] {
        invocations
    }
}

private struct ProbeFileSystem: FileSystemInspecting {
    let executables: Set<URL>

    func isExecutableFile(at url: URL) -> Bool {
        executables.contains(url)
    }
}
