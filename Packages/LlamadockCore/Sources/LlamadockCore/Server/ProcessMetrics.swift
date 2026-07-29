import Darwin
import Foundation

public struct ProcessTaskCounters:
    Equatable,
    Sendable
{
    public let userNanoseconds: UInt64
    public let systemNanoseconds: UInt64
    public let residentMemoryBytes: UInt64
    public let virtualMemoryBytes: UInt64
    public let threadCount: Int

    public init(
        userNanoseconds: UInt64,
        systemNanoseconds: UInt64,
        residentMemoryBytes: UInt64,
        virtualMemoryBytes: UInt64,
        threadCount: Int
    ) {
        self.userNanoseconds = userNanoseconds
        self.systemNanoseconds = systemNanoseconds
        self.residentMemoryBytes = residentMemoryBytes
        self.virtualMemoryBytes = virtualMemoryBytes
        self.threadCount = threadCount
    }
}

public protocol ProcessTaskInspecting: Sendable {
    func counters(
        for processIdentifier: Int32
    ) -> ProcessTaskCounters?
}

public struct DarwinProcessTaskInspector:
    ProcessTaskInspecting,
    Sendable
{
    public init() {}

    public func counters(
        for processIdentifier: Int32
    ) -> ProcessTaskCounters? {
        guard processIdentifier > 0 else {
            return nil
        }
        var info = proc_taskinfo()
        let expectedSize = MemoryLayout<proc_taskinfo>.size
        let result = withUnsafeMutablePointer(
            to: &info
        ) { pointer in
            proc_pidinfo(
                processIdentifier,
                PROC_PIDTASKINFO,
                0,
                pointer,
                Int32(expectedSize)
            )
        }
        guard result == Int32(expectedSize) else {
            return nil
        }
        return ProcessTaskCounters(
            userNanoseconds: info.pti_total_user,
            systemNanoseconds: info.pti_total_system,
            residentMemoryBytes: info.pti_resident_size,
            virtualMemoryBytes: info.pti_virtual_size,
            threadCount: max(Int(info.pti_threadnum), 0)
        )
    }
}

public struct ServerProcessMetrics:
    Equatable,
    Sendable
{
    public let sampledAt: Date
    public let cpuPercent: Double?
    public let residentMemoryBytes: UInt64
    public let virtualMemoryBytes: UInt64
    public let threadCount: Int

    public init(
        sampledAt: Date,
        cpuPercent: Double?,
        residentMemoryBytes: UInt64,
        virtualMemoryBytes: UInt64,
        threadCount: Int
    ) {
        self.sampledAt = sampledAt
        self.cpuPercent = cpuPercent
        self.residentMemoryBytes = residentMemoryBytes
        self.virtualMemoryBytes = virtualMemoryBytes
        self.threadCount = threadCount
    }
}

public protocol ProcessMetricsReading: Sendable {
    func sample(
        processIdentifier: Int32,
        now: Date
    ) -> ServerProcessMetrics?

    func reset()
}

public final class ProcessMetricsReader:
    ProcessMetricsReading,
    @unchecked Sendable
{
    private struct PreviousSample {
        let processIdentifier: Int32
        let sampledAt: Date
        let cpuNanoseconds: UInt64
    }

    private let inspector: any ProcessTaskInspecting
    private let processorCount: Int
    private let minimumInterval: TimeInterval
    private let lock = NSLock()
    private var previous: PreviousSample?
    private var latest: ServerProcessMetrics?

    public init(
        inspector: any ProcessTaskInspecting =
            DarwinProcessTaskInspector(),
        processorCount: Int =
            ProcessInfo.processInfo.processorCount
    ) {
        self.inspector = inspector
        self.processorCount = max(processorCount, 1)
        self.minimumInterval = 2
    }

    public init(
        inspector: any ProcessTaskInspecting,
        processorCount: Int,
        minimumInterval: TimeInterval
    ) {
        self.inspector = inspector
        self.processorCount = max(processorCount, 1)
        self.minimumInterval = max(minimumInterval, 0)
    }

    public func sample(
        processIdentifier: Int32,
        now: Date = Date()
    ) -> ServerProcessMetrics? {
        lock.lock()
        defer { lock.unlock() }

        if
            let previous,
            previous.processIdentifier == processIdentifier,
            let latest,
            now >= latest.sampledAt,
            now.timeIntervalSince(latest.sampledAt)
                < minimumInterval
        {
            return latest
        }
        guard
            let counters = inspector.counters(
                for: processIdentifier
            )
        else {
            return nil
        }
        let cpuSum = counters.userNanoseconds
            .addingReportingOverflow(
                counters.systemNanoseconds
            )
        guard !cpuSum.overflow else {
            return nil
        }

        let previous = self.previous
        self.previous = PreviousSample(
            processIdentifier: processIdentifier,
            sampledAt: now,
            cpuNanoseconds: cpuSum.partialValue
        )

        let cpuPercent: Double?
        if
            let previous,
            previous.processIdentifier == processIdentifier,
            cpuSum.partialValue >= previous.cpuNanoseconds
        {
            let elapsed = now.timeIntervalSince(
                previous.sampledAt
            )
            if elapsed > 0 {
                let usedNanoseconds = cpuSum.partialValue
                    - previous.cpuNanoseconds
                let rawPercent = Double(usedNanoseconds)
                    / (elapsed * 1_000_000_000)
                    * 100
                cpuPercent = min(
                    max(rawPercent, 0),
                    Double(processorCount * 100)
                )
            } else {
                cpuPercent = nil
            }
        } else {
            cpuPercent = nil
        }

        let metrics = ServerProcessMetrics(
            sampledAt: now,
            cpuPercent: cpuPercent,
            residentMemoryBytes:
                counters.residentMemoryBytes,
            virtualMemoryBytes:
                counters.virtualMemoryBytes,
            threadCount: counters.threadCount
        )
        latest = metrics
        return metrics
    }

    public func reset() {
        lock.lock()
        previous = nil
        latest = nil
        lock.unlock()
    }
}
