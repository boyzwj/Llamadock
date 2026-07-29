import Foundation
import Testing
@testable import LlamadockCore

@Suite("Foundation process runner")
struct FoundationProcessRunnerTests {
    @Test("captures stdout without using a shell")
    func capturesStandardOutput() async throws {
        let runner = FoundationProcessRunner()
        let invocation = try ProcessInvocation(
            executableURL: URL(filePath: "/usr/bin/printf"),
            arguments: ["hello %s", "world"]
        )

        let result = try await runner.run(
            invocation,
            timeout: .seconds(2)
        )

        #expect(result.terminationStatus == 0)
        #expect(result.standardOutput == "hello world")
        #expect(result.standardError.isEmpty)
        #expect(!result.timedOut)
    }

    @Test("captures stderr and a non-zero exit status")
    func capturesStandardError() async throws {
        let runner = FoundationProcessRunner()
        let invocation = try ProcessInvocation(
            executableURL: URL(filePath: "/bin/ls"),
            arguments: ["/definitely-not-a-real-llamadock-path"]
        )

        let result = try await runner.run(
            invocation,
            timeout: .seconds(2)
        )

        #expect(result.terminationStatus != 0)
        #expect(result.standardError.contains("No such file or directory"))
        #expect(!result.timedOut)
    }

    @Test("terminates an owned probe when the timeout elapses")
    func terminatesTimedOutProcess() async throws {
        let runner = FoundationProcessRunner()
        let invocation = try ProcessInvocation(
            executableURL: URL(filePath: "/bin/sleep"),
            arguments: ["2"]
        )
        let clock = ContinuousClock()
        let start = clock.now

        let result = try await runner.run(
            invocation,
            timeout: .milliseconds(50)
        )

        #expect(result.timedOut)
        #expect(start.duration(to: clock.now) < .seconds(1))
    }
}
