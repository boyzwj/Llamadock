import Foundation
import Testing
@testable import LlamadockCore

@Suite("Runtime capabilities parser")
struct RuntimeCapabilitiesParserTests {
    @Test("extracts long flags and derived endpoint capabilities")
    func extractsFlags() {
        let detectedAt = Date(timeIntervalSince1970: 1_785_315_000)
        let help = """
        usage: llama-server [options]
          -m, --model FNAME
              --ctx-size N
              --flash-attn [on|off]
              --metrics
              --no-webui
        HTTP endpoints include /health and /props.
        """

        let capabilities = RuntimeCapabilitiesParser().parse(
            help,
            detectedAt: detectedAt
        )

        #expect(
            capabilities.supportedFlags
                == [
                    "--model",
                    "--ctx-size",
                    "--flash-attn",
                    "--metrics",
                    "--no-webui",
                ]
        )
        #expect(capabilities.detection == .detected)
        #expect(capabilities.supportsWebUI)
        #expect(capabilities.supportsMetrics)
        #expect(capabilities.supportsPropsEndpoint)
        #expect(capabilities.detectedAt == detectedAt)
        #expect(capabilities.rawHelpHash.count == 16)
        #expect(capabilities.support(for: "--ctx-size") == .supported)
        #expect(capabilities.support(for: "--unknown-flag") == .unsupported)
    }

    @Test("marks an unrecognized help format as unknown")
    func marksUnrecognizedHelpUnknown() {
        let capabilities = RuntimeCapabilitiesParser().parse(
            "llama server help format changed",
            detectedAt: .distantPast
        )

        #expect(capabilities.supportedFlags.isEmpty)
        #expect(capabilities.detection == .unknown)
        #expect(!capabilities.supportsWebUI)
        #expect(!capabilities.supportsMetrics)
        #expect(!capabilities.supportsPropsEndpoint)
        #expect(capabilities.support(for: "--model") == .unknown)
    }

    @Test("uses a stable hash for the same raw help")
    func stableHash() {
        let parser = RuntimeCapabilitiesParser()

        let first = parser.parse("  --model FNAME\n", detectedAt: .distantPast)
        let second = parser.parse("  --model FNAME\n", detectedAt: .distantFuture)
        let changed = parser.parse("  --model PATH\n", detectedAt: .distantPast)

        #expect(first.rawHelpHash == second.rawHelpHash)
        #expect(first.rawHelpHash != changed.rawHelpHash)
    }
}
