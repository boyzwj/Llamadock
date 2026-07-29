import Foundation

public enum CapabilityDetection: String, Codable, Sendable {
    case detected
    case unknown
}

public enum RuntimeFlagSupport: String, Codable, Equatable, Sendable {
    case supported
    case unsupported
    case unknown
}

public struct RuntimeCapabilities: Codable, Equatable, Sendable {
    public let supportedFlags: Set<String>
    public let rawHelpHash: String
    public let supportsWebUI: Bool
    public let supportsMetrics: Bool
    public let supportsPropsEndpoint: Bool
    public let detectedAt: Date
    public let detection: CapabilityDetection

    public init(
        supportedFlags: Set<String>,
        rawHelpHash: String,
        supportsWebUI: Bool,
        supportsMetrics: Bool,
        supportsPropsEndpoint: Bool,
        detectedAt: Date,
        detection: CapabilityDetection
    ) {
        self.supportedFlags = supportedFlags
        self.rawHelpHash = rawHelpHash
        self.supportsWebUI = supportsWebUI
        self.supportsMetrics = supportsMetrics
        self.supportsPropsEndpoint = supportsPropsEndpoint
        self.detectedAt = detectedAt
        self.detection = detection
    }

    public func support(
        for flag: String
    ) -> RuntimeFlagSupport {
        guard detection == .detected else {
            return .unknown
        }
        return supportedFlags.contains(flag)
            ? .supported
            : .unsupported
    }
}

public struct RuntimeCapabilitiesParser: Sendable {
    public init() {}

    public func parse(
        _ rawHelp: String,
        detectedAt: Date = Date()
    ) -> RuntimeCapabilities {
        let supportedFlags = extractLongFlags(from: rawHelp)
        let lowercasedHelp = rawHelp.lowercased()

        return RuntimeCapabilities(
            supportedFlags: supportedFlags,
            rawHelpHash: stableHash(rawHelp),
            supportsWebUI: supportedFlags.contains("--webui")
                || supportedFlags.contains("--no-webui")
                || lowercasedHelp.contains("webui"),
            supportsMetrics: supportedFlags.contains("--metrics"),
            supportsPropsEndpoint: supportedFlags.contains("--props")
                || lowercasedHelp.contains("/props"),
            detectedAt: detectedAt,
            detection: supportedFlags.isEmpty ? .unknown : .detected
        )
    }

    private func extractLongFlags(from rawHelp: String) -> Set<String> {
        let pattern = #"--[A-Za-z0-9][A-Za-z0-9-]*"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let range = NSRange(rawHelp.startIndex..., in: rawHelp)
        return Set(
            expression.matches(in: rawHelp, range: range).compactMap { match in
                guard let swiftRange = Range(match.range, in: rawHelp) else {
                    return nil
                }
                return String(rawHelp[swiftRange])
            }
        )
    }

    private func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}
