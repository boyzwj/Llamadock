import Foundation
import Testing
@testable import LlamadockCore

@Suite("Model directory FSEvents monitor")
struct ModelDirectoryChangeMonitorTests {
    @Test("reports a nested file-system change without polling")
    func reportsNestedChange() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(
                path: "LlamadockModelMonitor-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        let nested = root.appending(
            path: "nested",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: nested,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let monitor = FSEventsModelDirectoryChangeMonitor(
            latency: 0.05
        )
        let changes = monitor.changes(in: [root])
        let received = LockedChangeFlag()
        let listener = Task {
            for await _ in changes {
                received.markReceived()
            }
        }
        defer {
            listener.cancel()
        }

        let process = Process()
        process.executableURL = URL(
            filePath: "/usr/bin/touch",
            directoryHint: .notDirectory
        )
        process.arguments = [
            nested.appending(path: "model.gguf").path
        ]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        for _ in 0..<100 {
            if received.value {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(received.value)
    }

    @Test("an empty root set finishes immediately")
    func emptyRootsFinish() async {
        let changes = FSEventsModelDirectoryChangeMonitor()
            .changes(in: [])
        var iterator = changes.makeAsyncIterator()

        #expect(await iterator.next() == nil)
    }
}

private final class LockedChangeFlag:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var received = false

    var value: Bool {
        lock.withLock { received }
    }

    func markReceived() {
        lock.withLock {
            received = true
        }
    }
}
