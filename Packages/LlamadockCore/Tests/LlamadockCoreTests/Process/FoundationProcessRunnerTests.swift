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

    @Test("concurrent verbose probes do not starve the cooperative executor")
    func completesConcurrentVerboseProbes() async throws {
        let runner = FoundationProcessRunner()
        let invocation = try ProcessInvocation(
            executableURL: URL(filePath: "/usr/bin/seq"),
            arguments: ["1", "20000"]
        )
        let clock = ContinuousClock()
        let start = clock.now

        let results = try await withThrowingTaskGroup(
            of: ProcessResult.self
        ) { group in
            for _ in 0..<12 {
                group.addTask {
                    try await runner.run(
                        invocation,
                        timeout: .seconds(2)
                    )
                }
            }

            return try await group.reduce(into: []) {
                $0.append($1)
            }
        }

        #expect(results.count == 12)
        #expect(results.allSatisfy { !$0.timedOut })
        #expect(
            results.allSatisfy {
                $0.terminationStatus == 0
                    && $0.standardOutput.hasSuffix("20000\n")
            }
        )
        #expect(start.duration(to: clock.now) < .seconds(4))
    }

    @Test("bounds a process launch that does not begin")
    func timesOutBlockedLaunch() async throws {
        let launchQueue = DispatchQueue(
            label: "io.github.boyzwj.LlamaDock.blocked-launch"
        )
        launchQueue.suspend()
        defer { launchQueue.resume() }
        let runner = FoundationProcessRunner(
            launchQueue: launchQueue
        )
        let invocation = try ProcessInvocation(
            executableURL: URL(filePath: "/usr/bin/printf"),
            arguments: ["never launched before timeout"]
        )
        let clock = ContinuousClock()
        let start = clock.now

        let result = try await runner.run(
            invocation,
            timeout: .milliseconds(50)
        )

        #expect(result.timedOut)
        #expect(result.standardOutput.isEmpty)
        #expect(start.duration(to: clock.now) < .seconds(1))
    }
}
