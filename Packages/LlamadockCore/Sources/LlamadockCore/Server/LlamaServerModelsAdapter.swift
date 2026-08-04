import Foundation

public enum LlamaServerModelState: Equatable, Sendable {
    case unloaded
    case loading
    case loaded
    case sleeping
    case downloading
    case failed
    case unknown(String)

    public init(value: String, failed: Bool) {
        if failed {
            self = .failed
            return
        }
        switch value.lowercased() {
        case "unloaded":
            self = .unloaded
        case "loading":
            self = .loading
        case "loaded":
            self = .loaded
        case "sleeping":
            self = .sleeping
        case "downloading":
            self = .downloading
        default:
            self = .unknown(value)
        }
    }
}

public struct LlamaServerModel: Equatable, Identifiable, Sendable {
    public let id: String
    public let path: String?
    public let state: LlamaServerModelState

    public init(
        id: String,
        path: String?,
        state: LlamaServerModelState
    ) {
        self.id = id
        self.path = path
        self.state = state
    }
}

public enum LlamaServerModelsError: Error, Equatable, Sendable {
    case unexpectedStatus(Int)
    case malformedResponse
}

public struct LlamaServerModelsAdapter: Sendable {
    private let client: any HTTPRequesting

    public init(
        client: any HTTPRequesting = URLSessionHTTPClient()
    ) {
        self.client = client
    }

    public func models(
        baseURL: URL
    ) async throws -> [LlamaServerModel] {
        let url = baseURL.appending(
            path: "models",
            directoryHint: .notDirectory
        )
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let response = try await client.data(for: request)
        guard response.statusCode == 200 else {
            throw LlamaServerModelsError.unexpectedStatus(
                response.statusCode
            )
        }
        guard
            let object = try? JSONSerialization.jsonObject(
                with: response.data
            ),
            let dictionary = object as? [String: Any],
            let records = dictionary["data"] as? [[String: Any]]
        else {
            throw LlamaServerModelsError.malformedResponse
        }

        return try records.map { record in
            guard
                let id = record["id"] as? String,
                let status = record["status"] as? [String: Any],
                let value = status["value"] as? String
            else {
                throw LlamaServerModelsError.malformedResponse
            }
            return LlamaServerModel(
                id: id,
                path: record["path"] as? String,
                state: LlamaServerModelState(
                    value: value,
                    failed: status["failed"] as? Bool ?? false
                )
            )
        }
    }
}
