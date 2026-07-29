import Foundation

public enum HealthCheckResult: Equatable, Sendable {
    case ready
    case starting(detail: String?)
    case degraded(reason: String)
    case unavailable(reason: String)
}

public protocol ServerHealthChecking: Sendable {
    func check(baseURL: URL) async -> HealthCheckResult
}

public struct LlamaServerHealthAdapter: ServerHealthChecking {
    private let client: any HTTPRequesting

    public init(
        client: any HTTPRequesting = URLSessionHTTPClient()
    ) {
        self.client = client
    }

    public func check(baseURL: URL) async -> HealthCheckResult {
        let healthURL = baseURL.appending(
            path: "health",
            directoryHint: .notDirectory
        )
        var request = URLRequest(url: healthURL)
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let response: HTTPResponse
        do {
            response = try await client.data(for: request)
        } catch {
            return .unavailable(reason: String(describing: error))
        }

        if let status = statusString(from: response.data) {
            let normalizedStatus = status.lowercased()
            if
                normalizedStatus == "ok"
                    || normalizedStatus == "ready"
                    || normalizedStatus.contains("ready")
            {
                return .ready
            }
            if
                normalizedStatus.contains("loading")
                    || normalizedStatus.contains("starting")
            {
                return .starting(detail: status)
            }
        }

        if response.statusCode == 200 {
            return .degraded(
                reason: "HTTP 200 health payload was not recognized."
            )
        }

        return .unavailable(
            reason: "Health endpoint returned HTTP \(response.statusCode)."
        )
    }

    private func statusString(from data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any],
            let status = dictionary["status"] as? String
        else {
            return nil
        }
        return status
    }
}
