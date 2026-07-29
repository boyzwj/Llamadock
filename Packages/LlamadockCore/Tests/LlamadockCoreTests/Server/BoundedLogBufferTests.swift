import Foundation
import Testing
@testable import LlamadockCore

@Suite("Bounded log buffer")
struct BoundedLogBufferTests {
    @Test("evicts oldest events when the entry limit is exceeded")
    func enforcesEntryLimit() {
        var buffer = BoundedLogBuffer(maxEntries: 3, maxUTF8Bytes: 1_000)

        for index in 1...4 {
            buffer.append(
                LogEvent(
                    timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                    source: .standardOutput,
                    message: "line \(index)"
                )
            )
        }

        #expect(buffer.events.map(\.message) == ["line 2", "line 3", "line 4"])
    }

    @Test("evicts oldest events when the byte limit is exceeded")
    func enforcesByteLimit() {
        var buffer = BoundedLogBuffer(maxEntries: 10, maxUTF8Bytes: 10)

        buffer.append(event("12345"))
        buffer.append(event("67890"))
        buffer.append(event("abc"))

        #expect(buffer.events.map(\.message) == ["67890", "abc"])
        #expect(buffer.utf8ByteCount == 8)
    }

    @Test("retains a bounded tail of one oversized event")
    func truncatesOversizedEvent() {
        var buffer = BoundedLogBuffer(maxEntries: 10, maxUTF8Bytes: 5)

        buffer.append(event("0123456789"))

        #expect(buffer.events.map(\.message) == ["56789"])
        #expect(buffer.utf8ByteCount == 5)
    }

    private func event(_ message: String) -> LogEvent {
        LogEvent(
            timestamp: .distantPast,
            source: .standardError,
            message: message
        )
    }
}
