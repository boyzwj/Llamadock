import CoreServices
import Dispatch
import Foundation

public protocol ModelDirectoryChangeMonitoring: Sendable {
    func changes(
        in roots: [URL]
    ) -> AsyncStream<Void>
}

public struct FSEventsModelDirectoryChangeMonitor:
    ModelDirectoryChangeMonitoring,
    Sendable
{
    private let latency: TimeInterval

    public init(
        latency: TimeInterval = 0.25
    ) {
        self.latency = min(max(latency, 0.01), 10)
    }

    public func changes(
        in roots: [URL]
    ) -> AsyncStream<Void> {
        let paths = uniquePaths(roots)
        guard !paths.isEmpty else {
            return AsyncStream { continuation in
                continuation.finish()
            }
        }

        return AsyncStream(
            bufferingPolicy: .bufferingNewest(1)
        ) { continuation in
            let session = FSEventsModelDirectoryMonitorSession(
                paths: paths,
                latency: latency,
                continuation: continuation
            )
            continuation.onTermination = {
                @Sendable _ in
                session.stop()
            }
            guard session.start() else {
                continuation.finish()
                return
            }
        }
    }

    private func uniquePaths(
        _ roots: [URL]
    ) -> [String] {
        var seen = Set<String>()
        return roots.compactMap { root in
            guard root.isFileURL else {
                return nil
            }
            let path = root.standardizedFileURL.path
            return seen.insert(path).inserted
                ? path
                : nil
        }
    }
}

private final class FSEventsModelDirectoryMonitorSession:
    @unchecked Sendable
{
    private let lock = NSLock()
    private let paths: [String]
    private let latency: TimeInterval
    private let queue = DispatchQueue(
        label: "io.github.boyzwj.LlamaDock.model-directory-events",
        qos: .utility
    )
    private var continuationBox:
        FSEventsModelDirectoryContinuationBox?
    private var stream: FSEventStreamRef?
    private var isStarted = false

    init(
        paths: [String],
        latency: TimeInterval,
        continuation: AsyncStream<Void>.Continuation
    ) {
        self.paths = paths
        self.latency = latency
        continuationBox = FSEventsModelDirectoryContinuationBox(
            continuation: continuation
        )
    }

    func start() -> Bool {
        lock.withLock {
            guard
                stream == nil,
                let continuationBox
            else {
                return false
            }

            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(
                    continuationBox
                ).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes
                    | kFSEventStreamCreateFlagNoDefer
                    | kFSEventStreamCreateFlagWatchRoot
                    | kFSEventStreamCreateFlagIgnoreSelf
                    | kFSEventStreamCreateFlagFileEvents
            )
            guard let createdStream = FSEventStreamCreate(
                kCFAllocatorDefault,
                modelDirectoryFSEventsCallback,
                &context,
                paths as CFArray,
                FSEventStreamEventId(
                    kFSEventStreamEventIdSinceNow
                ),
                latency,
                flags
            ) else {
                self.continuationBox = nil
                return false
            }

            FSEventStreamSetDispatchQueue(
                createdStream,
                queue
            )
            guard FSEventStreamStart(createdStream) else {
                FSEventStreamInvalidate(createdStream)
                FSEventStreamRelease(createdStream)
                self.continuationBox = nil
                return false
            }
            stream = createdStream
            isStarted = true
            return true
        }
    }

    func stop() {
        let state: (
            stream: FSEventStreamRef,
            wasStarted: Bool,
            box: FSEventsModelDirectoryContinuationBox?
        )? = lock.withLock {
            guard let stream else {
                continuationBox = nil
                return nil
            }
            let state = (
                stream: stream,
                wasStarted: isStarted,
                box: continuationBox
            )
            self.stream = nil
            isStarted = false
            continuationBox = nil
            return state
        }
        guard let state else {
            return
        }

        if state.wasStarted {
            FSEventStreamStop(state.stream)
        }
        FSEventStreamInvalidate(state.stream)
        FSEventStreamRelease(state.stream)
        _ = state.box
    }

    deinit {
        stop()
    }
}

private final class FSEventsModelDirectoryContinuationBox:
    @unchecked Sendable
{
    let continuation: AsyncStream<Void>.Continuation

    init(
        continuation: AsyncStream<Void>.Continuation
    ) {
        self.continuation = continuation
    }
}

private let modelDirectoryFSEventsCallback:
    FSEventStreamCallback =
{ _, clientInfo, eventCount, _, _, _ in
    guard
        eventCount > 0,
        let clientInfo
    else {
        return
    }
    let box = Unmanaged<
        FSEventsModelDirectoryContinuationBox
    >
    .fromOpaque(clientInfo)
    .takeUnretainedValue()
    box.continuation.yield()
}
