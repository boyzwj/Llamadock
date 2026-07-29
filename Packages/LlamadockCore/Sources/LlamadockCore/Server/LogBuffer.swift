import Foundation

public enum LogSource: String, Codable, Sendable {
    case standardOutput
    case standardError
    case system
}

public struct LogEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let source: LogSource
    public let message: String

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        source: LogSource,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.message = message
    }
}

public struct BoundedLogBuffer: Sendable {
    public private(set) var events: [LogEvent] = []
    public private(set) var utf8ByteCount = 0

    private let maxEntries: Int
    private let maxUTF8Bytes: Int

    public init(
        maxEntries: Int = 5_000,
        maxUTF8Bytes: Int = 5 * 1_024 * 1_024
    ) {
        self.maxEntries = max(1, maxEntries)
        self.maxUTF8Bytes = max(1, maxUTF8Bytes)
    }

    public mutating func append(_ event: LogEvent) {
        let redactedMessage = LogRedactor.redact(event.message)
        let boundedMessage = boundedTail(of: redactedMessage)
        let boundedEvent = LogEvent(
            id: event.id,
            timestamp: event.timestamp,
            source: event.source,
            message: boundedMessage
        )

        events.append(boundedEvent)
        utf8ByteCount += boundedMessage.utf8.count
        enforceLimits()
    }

    public mutating func removeAll(keepingCapacity: Bool = true) {
        events.removeAll(keepingCapacity: keepingCapacity)
        utf8ByteCount = 0
    }

    private mutating func enforceLimits() {
        while
            events.count > maxEntries
                || utf8ByteCount > maxUTF8Bytes
        {
            let removed = events.removeFirst()
            utf8ByteCount -= removed.message.utf8.count
        }
    }

    private func boundedTail(of message: String) -> String {
        guard message.utf8.count > maxUTF8Bytes else {
            return message
        }

        var reversedCharacters: [Character] = []
        var byteCount = 0
        for character in message.reversed() {
            let characterByteCount = String(character).utf8.count
            guard byteCount + characterByteCount <= maxUTF8Bytes else {
                break
            }
            reversedCharacters.append(character)
            byteCount += characterByteCount
        }

        return String(reversedCharacters.reversed())
    }
}

public enum LogRedactor {
    public static func redact(_ value: String) -> String {
        var redacted = replacing(
            in: value,
            pattern: #"(?i)(Authorization\s*:\s*Bearer\s+)[^\s]+"#,
            template: "$1<redacted>"
        )
        redacted = replacing(
            in: redacted,
            pattern: #"(?i)\b(HF_TOKEN|HUGGING_FACE_HUB_TOKEN)\s*=\s*[^\s]+"#,
            template: "$1=<redacted>"
        )
        redacted = replacing(
            in: redacted,
            pattern: #"(?i)\bhf_[A-Za-z0-9_-]{8,}\b"#,
            template: "<redacted-hf-token>"
        )
        redacted = replacing(
            in: redacted,
            pattern: #"(https?://[^\s?]+)\?[^\s]+"#,
            template: "$1?<redacted>"
        )
        return redacted
    }

    private static func replacing(
        in value: String,
        pattern: String,
        template: String
    ) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: pattern
        ) else {
            return value
        }

        return expression.stringByReplacingMatches(
            in: value,
            range: NSRange(value.startIndex..., in: value),
            withTemplate: template
        )
    }
}
