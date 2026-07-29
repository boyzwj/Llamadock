import Foundation

public enum RuntimeValidation: Equatable, Sendable {
    case valid
    case invalid(reason: String)
}

public struct RuntimeProbeReport: Equatable, Sendable {
    public let candidate: RuntimeCandidate
    public let validation: RuntimeValidation
    public let serverVersionOutput: String?
    public let llamaVersionOutput: String?
    public let capabilities: RuntimeCapabilities?
    public let warning: String?

    public init(
        candidate: RuntimeCandidate,
        validation: RuntimeValidation,
        serverVersionOutput: String?,
        llamaVersionOutput: String?,
        capabilities: RuntimeCapabilities?,
        warning: String?
    ) {
        self.candidate = candidate
        self.validation = validation
        self.serverVersionOutput = serverVersionOutput
        self.llamaVersionOutput = llamaVersionOutput
        self.capabilities = capabilities
        self.warning = warning
    }
}

public protocol RuntimeCandidateProbing: Sendable {
    func probe(
        _ candidate: RuntimeCandidate,
        detectedAt: Date
    ) async -> RuntimeProbeReport
}

public struct RuntimeProbe: Sendable {
    private let processRunner: any ProcessRunning
    private let capabilitiesParser: RuntimeCapabilitiesParser
    private let timeoutSeconds: Int

    public init(
        processRunner: any ProcessRunning = FoundationProcessRunner(),
        capabilitiesParser: RuntimeCapabilitiesParser = RuntimeCapabilitiesParser(),
        timeoutSeconds: Int = 5
    ) {
        self.processRunner = processRunner
        self.capabilitiesParser = capabilitiesParser
        self.timeoutSeconds = timeoutSeconds
    }

    public func probe(
        _ candidate: RuntimeCandidate,
        detectedAt: Date = Date()
    ) async -> RuntimeProbeReport {
        guard let serverURL = candidate.serverURL else {
            return RuntimeProbeReport(
                candidate: candidate,
                validation: .invalid(
                    reason: "llama-server executable was not found."
                ),
                serverVersionOutput: nil,
                llamaVersionOutput: nil,
                capabilities: nil,
                warning: nil
            )
        }

        let versionResult: ProcessResult
        do {
            versionResult = try await runProbe(
                executableURL: serverURL,
                arguments: ["--version"]
            )
        } catch {
            return invalidReport(
                candidate: candidate,
                reason: "Version probe failed: \(error.localizedDescription)"
            )
        }

        if versionResult.timedOut {
            return invalidReport(
                candidate: candidate,
                reason: "Version probe timed out after \(timeoutSeconds) seconds."
            )
        }

        guard versionResult.terminationStatus == 0 else {
            return invalidReport(
                candidate: candidate,
                reason: "Version probe exited with code "
                    + "\(versionResult.terminationStatus): "
                    + diagnosticOutput(versionResult)
            )
        }

        let serverVersionOutput = visibleOutput(versionResult)
        let capabilityOutcome = await probeCapabilities(
            serverURL: serverURL,
            detectedAt: detectedAt
        )
        let llamaVersionOutput = await probeLlamaVersion(
            candidate.llamaURL
        )

        return RuntimeProbeReport(
            candidate: candidate,
            validation: .valid,
            serverVersionOutput: serverVersionOutput,
            llamaVersionOutput: llamaVersionOutput,
            capabilities: capabilityOutcome.capabilities,
            warning: capabilityOutcome.warning
        )
    }

    private func probeCapabilities(
        serverURL: URL,
        detectedAt: Date
    ) async -> (capabilities: RuntimeCapabilities, warning: String?) {
        let result: ProcessResult
        do {
            result = try await runProbe(
                executableURL: serverURL,
                arguments: ["--help"]
            )
        } catch {
            let message = "Capability probe failed: \(error.localizedDescription)"
            return (
                capabilitiesParser.parse(message, detectedAt: detectedAt),
                message
            )
        }

        if result.timedOut {
            let message = "Capability probe timed out after \(timeoutSeconds) seconds."
            return (
                capabilitiesParser.parse("", detectedAt: detectedAt),
                message
            )
        }

        guard result.terminationStatus == 0 else {
            let message = "Capability probe exited with code "
                + "\(result.terminationStatus): "
                + diagnosticOutput(result)
            return (
                capabilitiesParser.parse("", detectedAt: detectedAt),
                message
            )
        }

        return (
            capabilitiesParser.parse(
                visibleOutput(result),
                detectedAt: detectedAt
            ),
            nil
        )
    }

    private func probeLlamaVersion(_ llamaURL: URL?) async -> String? {
        guard let llamaURL else {
            return nil
        }

        guard
            let result = try? await runProbe(
                executableURL: llamaURL,
                arguments: ["--version"]
            ),
            !result.timedOut,
            result.terminationStatus == 0
        else {
            return nil
        }

        return visibleOutput(result)
    }

    private func runProbe(
        executableURL: URL,
        arguments: [String]
    ) async throws -> ProcessResult {
        let deviceDisabledArguments = [
            "--device",
            "none",
        ] + arguments
        let primaryResult = try await processRunner.run(
            try ProcessInvocation(
                executableURL: executableURL,
                arguments: deviceDisabledArguments
            ),
            timeout: .seconds(timeoutSeconds)
        )

        guard shouldRetryWithoutDeviceFlag(primaryResult) else {
            return primaryResult
        }

        return try await processRunner.run(
            try ProcessInvocation(
                executableURL: executableURL,
                arguments: arguments
            ),
            timeout: .seconds(timeoutSeconds)
        )
    }

    private func shouldRetryWithoutDeviceFlag(
        _ result: ProcessResult
    ) -> Bool {
        guard result.terminationStatus != 0, !result.timedOut else {
            return false
        }

        let output = [
            result.standardOutput,
            result.standardError,
        ]
        .joined(separator: "\n")
        .lowercased()
        guard output.contains("device") else {
            return false
        }

        return [
            "unknown",
            "unrecognized",
            "invalid argument",
            "invalid option",
            "unsupported",
        ].contains { output.contains($0) }
    }

    private func invalidReport(
        candidate: RuntimeCandidate,
        reason: String
    ) -> RuntimeProbeReport {
        RuntimeProbeReport(
            candidate: candidate,
            validation: .invalid(reason: reason),
            serverVersionOutput: nil,
            llamaVersionOutput: nil,
            capabilities: nil,
            warning: nil
        )
    }

    private func diagnosticOutput(_ result: ProcessResult) -> String {
        let standardError = result.standardError.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if !standardError.isEmpty {
            return standardError
        }

        let standardOutput = result.standardOutput.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return standardOutput.isEmpty ? "No diagnostic output." : standardOutput
    }

    private func visibleOutput(_ result: ProcessResult) -> String {
        [result.standardOutput, result.standardError]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

extension RuntimeProbe: RuntimeCandidateProbing {}
