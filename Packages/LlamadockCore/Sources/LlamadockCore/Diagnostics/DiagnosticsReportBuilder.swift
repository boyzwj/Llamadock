import Foundation

public struct DiagnosticsEntry:
    Equatable,
    Sendable
{
    public let label: String
    public let value: String

    public init(
        _ label: String,
        _ value: String
    ) {
        self.label = label
        self.value = value
    }
}

public struct DiagnosticsSection:
    Equatable,
    Sendable
{
    public let title: String
    public let entries: [DiagnosticsEntry]

    public init(
        title: String,
        entries: [DiagnosticsEntry]
    ) {
        self.title = title
        self.entries = entries
    }
}

public struct DiagnosticsReportBuilder: Sendable {
    public init() {}

    public func makeReport(
        product: String,
        version: String,
        build: String,
        generatedAt: Date = Date(),
        sections: [DiagnosticsSection]
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]

        var lines = [
            "\(singleLine(product)) Diagnostics",
            "Generated: \(formatter.string(from: generatedAt))",
            "Version: \(singleLine(version)) (\(singleLine(build)))",
        ]
        for section in sections {
            lines.append("")
            lines.append("[\(singleLine(section.title))]")
            for entry in section.entries {
                let label = singleLine(entry.label)
                let value = LogRedactor.redact(entry.value)
                    .replacingOccurrences(
                        of: "\r\n",
                        with: "\n"
                    )
                    .replacingOccurrences(
                        of: "\r",
                        with: "\n"
                    )
                let valueLines = value.split(
                    separator: "\n",
                    omittingEmptySubsequences: false
                )
                lines.append(
                    "\(label): \(valueLines.first ?? "")"
                )
                lines.append(
                    contentsOf: valueLines.dropFirst().map {
                        "  \($0)"
                    }
                )
            }
        }
        lines.append("")
        lines.append(
            "Privacy: credentials, Authorization headers, signed URL queries, prompts, and server log contents are excluded."
        )
        return lines.joined(separator: "\n")
    }

    private func singleLine(
        _ value: String
    ) -> String {
        value.replacingOccurrences(
            of: "\n",
            with: " "
        ).replacingOccurrences(
            of: "\r",
            with: " "
        )
    }
}
