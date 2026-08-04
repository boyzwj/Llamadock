import Foundation
import Testing
@testable import LlamadockCore

@Suite("Server process controller")
struct ServerProcessControllerTests {
    @Test("starts one owned process and becomes ready from health")
    func startsAndBecomesReady() async throws {
        let handle = FakeManagedProcessHandle(processIdentifier: 4_242)
        let launcher = FakeServerProcessLauncher(handles: [handle])
        let health = StaticHealthChecker(result: .ready)
        let controller = ServerProcessController(
            launcher: launcher,
            healthChecker: health,
            endpointChecker: StaticEndpointChecker(result: .available)
        )
        let invocation = try makeInvocation()
        let profileID = UUID()

        try await controller.start(
            profileID: profileID,
            runtimeID: "custom:test",
            invocation: invocation,
            host: "127.0.0.1",
            port: 8_080,
            readinessTimeout: .seconds(1)
        )

        var snapshot = await controller.snapshot()
        #expect(snapshot.state == .ready)
        #expect(snapshot.run?.processIdentifier == 4_242)
        #expect(snapshot.run?.profileID == profileID)
        #expect(snapshot.run?.runtimeID == "custom:test")
        #expect(snapshot.run?.command == invocation)
        #expect(
            snapshot.run?.baseURL
                == URL(string: "http://127.0.0.1:8080")!
        )
        #expect(await launcher.recordedInvocations() == [invocation])

        await handle.emit(
            .output(
                source: .standardError,
                message: "Authorization: Bearer secret",
                timestamp: .distantPast
            )
        )
        for _ in 0..<20 {
            await Task.yield()
            snapshot = await controller.snapshot()
            if !snapshot.logs.isEmpty {
                break
            }
        }
        #expect(
            snapshot.logs.map(\.message)
                == ["Authorization: Bearer <redacted>"]
        )
    }

    @Test("fails if the owned process exits before readiness")
    func failsOnEarlyExit() async throws {
        let handle = FakeManagedProcessHandle(
            processIdentifier: 4_243,
            isRunning: false
        )
        let controller = ServerProcessController(
            launcher: FakeServerProcessLauncher(handles: [handle]),
            healthChecker: StaticHealthChecker(
                result: .unavailable(reason: "connection refused")
            ),
            endpointChecker: StaticEndpointChecker(result: .available)
        )

        try await controller.start(
            profileID: UUID(),
            runtimeID: "custom:test",
            invocation: try makeInvocation(),
            host: "127.0.0.1",
            port: 8_080,
            readinessTimeout: .seconds(1)
        )

        #expect(
            await controller.snapshot().state
                == .failed(reason: "Process exited before readiness.")
        )
    }

    @Test("stop terminates only the handle created by this controller")
    func stopsOwnedProcess() async throws {
        let handle = FakeManagedProcessHandle(processIdentifier: 4_244)
        let controller = ServerProcessController(
            launcher: FakeServerProcessLauncher(handles: [handle]),
            healthChecker: StaticHealthChecker(result: .ready),
            endpointChecker: StaticEndpointChecker(result: .available)
        )
        try await controller.start(
            profileID: UUID(),
            runtimeID: "custom:test",
            invocation: try makeInvocation(),
            host: "127.0.0.1",
            port: 8_080,
            readinessTimeout: .seconds(1)
        )

        await controller.stop(gracePeriod: .seconds(1))

        #expect(await handle.terminateCount == 1)
        #expect(await handle.forceTerminateCount == 0)
        #expect(await controller.snapshot().state == .stopped)
    }

    @Test("rejects a second start while an owned process is active")
    func rejectsSecondStart() async throws {
        let handle = FakeManagedProcessHandle(processIdentifier: 4_245)
        let controller = ServerProcessController(
            launcher: FakeServerProcessLauncher(handles: [handle]),
            healthChecker: StaticHealthChecker(result: .ready),
            endpointChecker: StaticEndpointChecker(result: .available)
        )
        try await controller.start(
            profileID: UUID(),
            runtimeID: "custom:test",
            invocation: try makeInvocation(),
            host: "127.0.0.1",
            port: 8_080
        )

        await #expect(
            throws: ServerProcessError.alreadyRunning
        ) {
            try await controller.start(
                profileID: UUID(),
                runtimeID: "custom:test",
                invocation: try makeInvocation(),
                host: "127.0.0.1",
                port: 8_081
            )
        }
    }

    @Test("can start again after an owned process fails")
    func restartsAfterFailure() async throws {
        let failedHandle = FakeManagedProcessHandle(
            processIdentifier: 4_246,
            isRunning: false
        )
        let replacementHandle = FakeManagedProcessHandle(
            processIdentifier: 4_247
        )
        let launcher = FakeServerProcessLauncher(
            handles: [failedHandle, replacementHandle]
        )
        let controller = ServerProcessController(
            launcher: launcher,
            healthChecker: StaticHealthChecker(result: .ready),
            endpointChecker: StaticEndpointChecker(result: .available)
        )
        let invocation = try makeInvocation()

        try await controller.start(
            profileID: UUID(),
            runtimeID: "custom:test",
            invocation: invocation,
            host: "127.0.0.1",
            port: 8_080,
            readinessTimeout: .seconds(1)
        )
        #expect(
            await controller.snapshot().state
                == .failed(reason: "Process exited before readiness.")
        )

        try await controller.start(
            profileID: UUID(),
            runtimeID: "custom:test",
            invocation: invocation,
            host: "127.0.0.1",
            port: 8_081,
            readinessTimeout: .seconds(1)
        )

        let snapshot = await controller.snapshot()
        #expect(snapshot.state == .ready)
        #expect(snapshot.run?.processIdentifier == 4_247)
        #expect(
            snapshot.run?.baseURL
                == URL(string: "http://127.0.0.1:8081")!
        )
        #expect(
            await launcher.recordedInvocations()
                == [invocation, invocation]
        )
    }

    @Test("stop during readiness polling remains stopped")
    func stopsWhileStarting() async throws {
        let handle = FakeManagedProcessHandle(processIdentifier: 4_248)
        let controller = ServerProcessController(
            launcher: FakeServerProcessLauncher(handles: [handle]),
            healthChecker: StaticHealthChecker(
                result: .unavailable(reason: "connection refused")
            ),
            endpointChecker: StaticEndpointChecker(result: .available)
        )
        let invocation = try makeInvocation()
        let startTask = Task {
            try await controller.start(
                profileID: UUID(),
                runtimeID: "custom:test",
                invocation: invocation,
                host: "127.0.0.1",
                port: 8_080,
                readinessTimeout: .seconds(1)
            )
        }

        for _ in 0..<100 {
            if await controller.snapshot().state == .starting {
                break
            }
            await Task.yield()
        }
        #expect(await controller.snapshot().state == .starting)

        await controller.stop(gracePeriod: .milliseconds(10))
        try await startTask.value

        #expect(await controller.snapshot().state == .stopped)
        #expect(await handle.terminateCount == 1)
    }

    @Test("rejects an occupied endpoint before launching")
    func rejectsOccupiedEndpoint() async throws {
        let reason = "127.0.0.1:8080 is already in use."
        let launcher = FakeServerProcessLauncher(handles: [])
        let controller = ServerProcessController(
            launcher: launcher,
            healthChecker: StaticHealthChecker(result: .ready),
            endpointChecker: StaticEndpointChecker(
                result: .unavailable(reason: reason)
            )
        )

        await #expect(
            throws: ServerProcessError.endpointUnavailable(
                host: "127.0.0.1",
                port: 8_080,
                reason: reason
            )
        ) {
            try await controller.start(
                profileID: UUID(),
                runtimeID: "custom:test",
                invocation: try makeInvocation(),
                host: "127.0.0.1",
                port: 8_080
            )
        }
        #expect(await launcher.recordedInvocations().isEmpty)
        #expect(
            await controller.snapshot().state
                == .failed(reason: reason)
        )
    }

    @Test("publishes metrics only for the owned process")
    func publishesOwnedProcessMetrics() async throws {
        let handle = FakeManagedProcessHandle(
            processIdentifier: 4_249
        )
        let metrics = ServerProcessMetrics(
            sampledAt: .distantPast,
            cpuPercent: 42,
            residentMemoryBytes: 1_024,
            virtualMemoryBytes: 2_048,
            threadCount: 3
        )
        let reader = StaticProcessMetricsReader(
            metrics: metrics
        )
        let controller = ServerProcessController(
            launcher: FakeServerProcessLauncher(
                handles: [handle]
            ),
            healthChecker: StaticHealthChecker(
                result: .ready
            ),
            endpointChecker: StaticEndpointChecker(
                result: .available
            ),
            metricsReader: reader
        )

        try await controller.start(
            profileID: UUID(),
            runtimeID: "custom:test",
            invocation: try makeInvocation(),
            host: "127.0.0.1",
            port: 8_080,
            readinessTimeout: .seconds(1)
        )

        #expect(await controller.snapshot().metrics == metrics)
        #expect(reader.sampledProcessIdentifiers == [4_249])

        await controller.stop()
        #expect(await controller.snapshot().metrics == nil)
        #expect(reader.resetCount >= 2)
    }

    @Test("persists ownership while running and removes it on stop")
    func persistsOwnershipUntilStop() async throws {
        let processStartTime = Date(timeIntervalSince1970: 1_785_315_100)
        let executableURL = URL(filePath: "/custom/bin/llama-server")
        let handle = FakeManagedProcessHandle(processIdentifier: 4_250)
        let store = FakeServerOwnershipStore()
        let inspector = FakeServerProcessInspector(
            identities: [
                4_250: ServerProcessIdentity(
                    processIdentifier: 4_250,
                    parentProcessIdentifier: 100,
                    processStartTime: processStartTime,
                    executableURL: executableURL
                )
            ]
        )
        let controller = ServerProcessController(
            launcher: FakeServerProcessLauncher(handles: [handle]),
            healthChecker: StaticHealthChecker(result: .ready),
            endpointChecker: StaticEndpointChecker(result: .available),
            ownershipStore: store,
            processInspector: inspector
        )
        let profileID = UUID()

        try await controller.start(
            profileID: profileID,
            runtimeID: "custom:test",
            invocation: try makeInvocation(),
            host: "127.0.0.1",
            port: 8_080,
            readinessTimeout: .seconds(1)
        )

        let record = await store.record
        #expect(record?.processIdentifier == 4_250)
        #expect(record?.processStartTime == processStartTime)
        #expect(record?.executableURL == executableURL)
        #expect(record?.runtimeID == "custom:test")
        #expect(record?.profileID == profileID)

        await controller.stop()
        #expect(await store.record == nil)
    }

    @Test("terminates a matching orphan and clears its record")
    func recoversMatchingOrphan() async {
        let record = makeOwnershipRecord(processIdentifier: 4_251)
        let store = FakeServerOwnershipStore(record: record)
        let inspector = FakeServerProcessInspector(
            identities: [
                4_251: ServerProcessIdentity(
                    processIdentifier: 4_251,
                    parentProcessIdentifier: 1,
                    processStartTime: record.processStartTime,
                    executableURL: record.executableURL
                )
            ]
        )
        let controller = ServerProcessController(
            ownershipStore: store,
            processInspector: inspector
        )

        let result = await controller.recoverOrphanedServer(
            gracePeriod: .milliseconds(10)
        )

        #expect(result == .orphanTerminated(processIdentifier: 4_251))
        #expect(inspector.terminatedProcessIdentifiers == [4_251])
        #expect(await store.record == nil)
    }

    @Test("never signals a reused PID that does not match the record")
    func ignoresReusedProcessIdentifier() async {
        let record = makeOwnershipRecord(processIdentifier: 4_252)
        let store = FakeServerOwnershipStore(record: record)
        let inspector = FakeServerProcessInspector(
            identities: [
                4_252: ServerProcessIdentity(
                    processIdentifier: 4_252,
                    parentProcessIdentifier: 1,
                    processStartTime: record.processStartTime
                        .addingTimeInterval(60),
                    executableURL: record.executableURL
                )
            ]
        )
        let controller = ServerProcessController(
            ownershipStore: store,
            processInspector: inspector
        )

        let result = await controller.recoverOrphanedServer()

        #expect(result == .staleRecordRemoved)
        #expect(inspector.terminatedProcessIdentifiers.isEmpty)
        #expect(await store.record == nil)
    }

    @Test("force terminates an orphan that ignores graceful termination")
    func forceTerminatesUnresponsiveOrphan() async {
        let record = makeOwnershipRecord(processIdentifier: 4_253)
        let store = FakeServerOwnershipStore(record: record)
        let inspector = FakeServerProcessInspector(
            identities: [
                4_253: ServerProcessIdentity(
                    processIdentifier: 4_253,
                    parentProcessIdentifier: 1,
                    processStartTime: record.processStartTime,
                    executableURL: record.executableURL
                )
            ],
            ignoresTerminate: true
        )
        let controller = ServerProcessController(
            ownershipStore: store,
            processInspector: inspector
        )

        let result = await controller.recoverOrphanedServer(
            gracePeriod: .milliseconds(1)
        )

        #expect(result == .orphanTerminated(processIdentifier: 4_253))
        #expect(inspector.terminatedProcessIdentifiers == [4_253])
        #expect(inspector.forceTerminatedProcessIdentifiers == [4_253])
        #expect(await store.record == nil)
    }

    @Test("does not terminate a server that still has a live owner")
    func preservesServerWithLiveOwner() async {
        let record = makeOwnershipRecord(processIdentifier: 4_254)
        let store = FakeServerOwnershipStore(record: record)
        let inspector = FakeServerProcessInspector(
            identities: [
                4_254: ServerProcessIdentity(
                    processIdentifier: 4_254,
                    parentProcessIdentifier: 999,
                    processStartTime: record.processStartTime,
                    executableURL: record.executableURL
                )
            ]
        )
        let controller = ServerProcessController(
            ownershipStore: store,
            processInspector: inspector
        )

        let result = await controller.recoverOrphanedServer()

        guard case .failed(let reason) = result else {
            Issue.record("Expected a live-owner recovery failure")
            return
        }
        #expect(reason.contains("still owned by process 999"))
        #expect(inspector.terminatedProcessIdentifiers.isEmpty)
        #expect(await store.record == record)
    }

    private func makeInvocation() throws -> ProcessInvocation {
        try ProcessInvocation(
            executableURL: URL(filePath: "/custom/bin/llama-server"),
            arguments: [
                "--model", "/Models/model.gguf",
                "--host", "127.0.0.1",
                "--port", "8080",
            ]
        )
    }

    private func makeOwnershipRecord(
        processIdentifier: Int32
    ) -> ServerOwnershipRecord {
        ServerOwnershipRecord(
            ownerProcessIdentifier: 100,
            processIdentifier: processIdentifier,
            processStartTime: Date(timeIntervalSince1970: 1_785_315_100),
            executableURL: URL(filePath: "/custom/bin/llama-server"),
            runtimeID: "custom:test",
            profileID: UUID(),
            host: "127.0.0.1",
            port: 8_080
        )
    }
}

private struct StaticEndpointChecker: ServerEndpointChecking {
    let result: ServerEndpointAvailability

    func check(
        host: String,
        port: UInt16
    ) -> ServerEndpointAvailability {
        result
    }
}

private actor FakeServerProcessLauncher: ServerProcessLaunching {
    private var handles: [FakeManagedProcessHandle]
    private var invocations: [ProcessInvocation] = []

    init(handles: [FakeManagedProcessHandle]) {
        self.handles = handles
    }

    func launch(
        _ invocation: ProcessInvocation
    ) async throws -> any ManagedServerProcess {
        invocations.append(invocation)
        return handles.removeFirst()
    }

    func recordedInvocations() -> [ProcessInvocation] {
        invocations
    }
}

private actor FakeManagedProcessHandle: ManagedServerProcess {
    let processIdentifier: Int32
    private var running: Bool
    private let stream: AsyncStream<ManagedProcessEvent>
    private let continuation: AsyncStream<ManagedProcessEvent>.Continuation
    private(set) var terminateCount = 0
    private(set) var forceTerminateCount = 0

    init(
        processIdentifier: Int32,
        isRunning: Bool = true
    ) {
        self.processIdentifier = processIdentifier
        self.running = isRunning
        let pair = AsyncStream<ManagedProcessEvent>.makeStream()
        self.stream = pair.stream
        self.continuation = pair.continuation
    }

    func events() -> AsyncStream<ManagedProcessEvent> {
        stream
    }

    func isRunning() -> Bool {
        running
    }

    func terminate() {
        terminateCount += 1
        running = false
        continuation.yield(.terminated(status: 0))
        continuation.finish()
    }

    func forceTerminate() {
        forceTerminateCount += 1
        running = false
        continuation.yield(.terminated(status: 9))
        continuation.finish()
    }

    func emit(_ event: ManagedProcessEvent) {
        continuation.yield(event)
    }
}

private actor StaticHealthChecker: ServerHealthChecking {
    let result: HealthCheckResult

    init(result: HealthCheckResult) {
        self.result = result
    }

    func check(baseURL: URL) -> HealthCheckResult {
        result
    }
}

private final class StaticProcessMetricsReader:
    ProcessMetricsReading,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let metrics: ServerProcessMetrics
    private var sampledIDs: [Int32] = []
    private var resets = 0

    init(
        metrics: ServerProcessMetrics
    ) {
        self.metrics = metrics
    }

    func sample(
        processIdentifier: Int32,
        now: Date
    ) -> ServerProcessMetrics? {
        lock.lock()
        sampledIDs.append(processIdentifier)
        lock.unlock()
        return metrics
    }

    func reset() {
        lock.lock()
        resets += 1
        lock.unlock()
    }

    var sampledProcessIdentifiers: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return sampledIDs
    }

    var resetCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return resets
    }
}

private actor FakeServerOwnershipStore: ServerOwnershipStoring {
    private(set) var record: ServerOwnershipRecord?

    init(record: ServerOwnershipRecord? = nil) {
        self.record = record
    }

    func load() -> ServerOwnershipRecord? {
        record
    }

    func save(_ record: ServerOwnershipRecord) {
        self.record = record
    }

    func remove() {
        record = nil
    }
}

private final class FakeServerProcessInspector:
    ServerProcessInspecting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var identities: [Int32: ServerProcessIdentity]
    private var terminatedIDs: [Int32] = []
    private var forceTerminatedIDs: [Int32] = []
    private let ignoresTerminate: Bool

    init(
        identities: [Int32: ServerProcessIdentity],
        ignoresTerminate: Bool = false
    ) {
        self.identities = identities
        self.ignoresTerminate = ignoresTerminate
    }

    func identity(
        processIdentifier: Int32
    ) -> ServerProcessIdentity? {
        lock.withLock {
            identities[processIdentifier]
        }
    }

    func terminate(processIdentifier: Int32) {
        lock.withLock {
            terminatedIDs.append(processIdentifier)
            if !ignoresTerminate {
                identities[processIdentifier] = nil
            }
        }
    }

    func forceTerminate(processIdentifier: Int32) {
        lock.withLock {
            forceTerminatedIDs.append(processIdentifier)
            identities[processIdentifier] = nil
        }
    }

    var terminatedProcessIdentifiers: [Int32] {
        lock.withLock { terminatedIDs }
    }

    var forceTerminatedProcessIdentifiers: [Int32] {
        lock.withLock { forceTerminatedIDs }
    }
}
