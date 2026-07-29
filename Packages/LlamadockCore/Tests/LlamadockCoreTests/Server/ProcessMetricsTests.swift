import Foundation
import Testing
@testable import LlamadockCore

@Suite("Owned process metrics")
struct ProcessMetricsTests {
    @Test("computes bounded CPU deltas and reports memory")
    func computesMetrics() throws {
        let inspector = FixtureProcessTaskInspector(
            samples: [
                ProcessTaskCounters(
                    userNanoseconds: 1_000_000_000,
                    systemNanoseconds: 500_000_000,
                    residentMemoryBytes: 100,
                    virtualMemoryBytes: 200,
                    threadCount: 3
                ),
                ProcessTaskCounters(
                    userNanoseconds: 2_000_000_000,
                    systemNanoseconds: 1_000_000_000,
                    residentMemoryBytes: 150,
                    virtualMemoryBytes: 250,
                    threadCount: 4
                ),
            ]
        )
        let reader = ProcessMetricsReader(
            inspector: inspector,
            processorCount: 4,
            minimumInterval: 0
        )
        let first = try #require(
            reader.sample(
                processIdentifier: 42,
                now: Date(timeIntervalSince1970: 10)
            )
        )
        #expect(first.cpuPercent == nil)
        #expect(first.residentMemoryBytes == 100)

        let second = try #require(
            reader.sample(
                processIdentifier: 42,
                now: Date(timeIntervalSince1970: 11)
            )
        )
        #expect(second.cpuPercent == 150)
        #expect(second.residentMemoryBytes == 150)
        #expect(second.virtualMemoryBytes == 250)
        #expect(second.threadCount == 4)
    }

    @Test("throttles task inspection to the default interval")
    func throttlesInspection() throws {
        let inspector = FixtureProcessTaskInspector(
            samples: [
                ProcessTaskCounters(
                    userNanoseconds: 1,
                    systemNanoseconds: 1,
                    residentMemoryBytes: 100,
                    virtualMemoryBytes: 200,
                    threadCount: 3
                ),
                ProcessTaskCounters(
                    userNanoseconds: 2,
                    systemNanoseconds: 2,
                    residentMemoryBytes: 300,
                    virtualMemoryBytes: 400,
                    threadCount: 4
                ),
            ]
        )
        let reader = ProcessMetricsReader(
            inspector: inspector,
            processorCount: 4,
            minimumInterval: 2
        )
        let startedAt = Date(timeIntervalSince1970: 10)
        let first = try #require(
            reader.sample(
                processIdentifier: 42,
                now: startedAt
            )
        )
        let cached = try #require(
            reader.sample(
                processIdentifier: 42,
                now: startedAt.addingTimeInterval(1)
            )
        )
        let refreshed = try #require(
            reader.sample(
                processIdentifier: 42,
                now: startedAt.addingTimeInterval(2)
            )
        )

        #expect(cached == first)
        #expect(refreshed.residentMemoryBytes == 300)
    }

    @Test("resets deltas and rejects unavailable processes")
    func resetsAndRejectsMissingProcess() throws {
        let inspector = FixtureProcessTaskInspector(
            samples: [
                ProcessTaskCounters(
                    userNanoseconds: 1,
                    systemNanoseconds: 1,
                    residentMemoryBytes: 2,
                    virtualMemoryBytes: 3,
                    threadCount: 1
                ),
                ProcessTaskCounters(
                    userNanoseconds: 2,
                    systemNanoseconds: 2,
                    residentMemoryBytes: 2,
                    virtualMemoryBytes: 3,
                    threadCount: 1
                ),
            ]
        )
        let reader = ProcessMetricsReader(
            inspector: inspector,
            processorCount: 4,
            minimumInterval: 0
        )
        #expect(
            reader.sample(
                processIdentifier: 42,
                now: .distantPast
            )?.cpuPercent == nil
        )
        reader.reset()
        #expect(
            reader.sample(
                processIdentifier: 42,
                now: .distantFuture
            )?.cpuPercent == nil
        )
        #expect(
            reader.sample(
                processIdentifier: 42,
                now: Date()
            ) == nil
        )
    }
}

private final class FixtureProcessTaskInspector:
    ProcessTaskInspecting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var samples: [ProcessTaskCounters]

    init(
        samples: [ProcessTaskCounters]
    ) {
        self.samples = samples
    }

    func counters(
        for processIdentifier: Int32
    ) -> ProcessTaskCounters? {
        lock.lock()
        defer { lock.unlock() }
        guard !samples.isEmpty else {
            return nil
        }
        return samples.removeFirst()
    }
}
