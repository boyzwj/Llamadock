import Foundation

public struct HTTPResponse: Equatable, Sendable {
    public let statusCode: Int
    public let data: Data
    public let headers: [String: String]

    public init(
        statusCode: Int,
        data: Data,
        headers: [String: String] = [:]
    ) {
        self.statusCode = statusCode
        self.data = data
        self.headers = headers
    }

    public func value(
        forHTTPHeaderField field: String
    ) -> String? {
        headers.first { key, _ in
            key.caseInsensitiveCompare(field) == .orderedSame
        }?.value
    }
}

public protocol HTTPRequesting: Sendable {
    func data(for request: URLRequest) async throws -> HTTPResponse
}

public enum HTTPClientError: Error, Sendable {
    case nonHTTPResponse
}

public struct URLSessionHTTPClient: HTTPRequesting {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPClientError.nonHTTPResponse
        }
        return HTTPResponse(
            statusCode: httpResponse.statusCode,
            data: data,
            headers: httpResponse.allHeaderFields.reduce(
                into: [String: String]()
            ) { headers, entry in
                guard
                    let key = entry.key as? String,
                    let value = entry.value as? String
                else {
                    return
                }
                headers[key] = value
            }
        )
    }
}
