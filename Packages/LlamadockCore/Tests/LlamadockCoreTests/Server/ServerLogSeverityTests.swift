import Foundation
import Testing
@testable import LlamadockCore

@Suite("Server log severity")
struct ServerLogSeverityTests {
    @Test("infers llama.cpp severity from its elapsed-time prefix")
    func infersSeverity() {
        #expect(event("0.00.031.816 D cmn debug").inferredSeverity == .debug)
        #expect(event("0.00.031.816 I srv model loaded").inferredSeverity == .info)
        #expect(event("0.00.031.816 W srv no API key").inferredSeverity == .warning)
        #expect(event("0.00.031.816 E srv failed").inferredSeverity == .error)
    }

    @Test("uses the highest severity in a multiline process chunk")
    func usesHighestSeverity() {
        let message = """
            0.00.031.816 I srv model loaded
            0.00.032.078 W srv CORS allows all origins
            0.00.032.080 W srv no API key is set
            """

        #expect(event(message).inferredSeverity == .warning)
    }

    @Test("does not mistake the stderr channel for an error level")
    func leavesUnstructuredStderrUnclassified() {
        #expect(
            event("diagnostic text written to stderr").inferredSeverity == nil
        )
        #expect(event("I srv missing timestamp").inferredSeverity == nil)
    }

    private func event(_ message: String) -> LogEvent {
        LogEvent(
            timestamp: .distantPast,
            source: .standardError,
            message: message
        )
    }
}
