import Foundation
import Testing
@testable import LlamadockCore

@Suite("Diagnostics report builder")
struct DiagnosticsReportBuilderTests {
    @Test("renders readable sections while redacting secrets")
    func rendersAndRedacts() {
        let report = DiagnosticsReportBuilder().makeReport(
            product: "LlamaDock",
            version: "1.0.0",
            build: "7",
            generatedAt: Date(timeIntervalSince1970: 0),
            sections: [
                DiagnosticsSection(
                    title: "Download",
                    entries: [
                        DiagnosticsEntry(
                            "State",
                            "failed\nAuthorization: Bearer hf_secret_value"
                        ),
                        DiagnosticsEntry(
                            "URL",
                            "https://cdn.example/model.gguf?token=secret"
                        ),
                    ]
                ),
            ]
        )

        #expect(report.contains("LlamaDock Diagnostics"))
        #expect(report.contains("[Download]"))
        #expect(report.contains("State: failed"))
        #expect(report.contains("Authorization: Bearer <redacted>"))
        #expect(
            report.contains(
                "https://cdn.example/model.gguf?<redacted>"
            )
        )
        #expect(!report.contains("hf_secret_value"))
        #expect(!report.contains("token=secret"))
        #expect(
            report.contains(
                "prompts, and server log contents are excluded"
            )
        )
    }
}
