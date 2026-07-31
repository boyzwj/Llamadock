import Foundation

public enum ModelScopeReferenceError:
    Error,
    Equatable,
    Sendable
{
    case emptyInput
    case missingRepository
    case unsupportedHost(String)
    case invalidRepositoryID(String)
    case invalidQuantization(String)
}

extension ModelScopeReferenceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            "Enter a ModelScope repository."
        case .missingRepository:
            "The ModelScope URL does not include a repository."
        case .unsupportedHost(let host):
            "Only modelscope.cn repository URLs are supported, not \(host)."
        case .invalidRepositoryID(let value):
            "Invalid ModelScope repository ID: \(value)."
        case .invalidQuantization(let value):
            "Invalid GGUF quantization label: \(value)."
        }
    }
}

public struct ModelScopeReferenceParser: Sendable {
    public init() {}

    public func parse(
        _ input: String
    ) throws -> HuggingFaceRepositoryReference {
        let trimmed = input.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else {
            throw ModelScopeReferenceError.emptyInput
        }
        if
            let components = URLComponents(string: trimmed),
            let scheme = components.scheme,
            !scheme.isEmpty
        {
            return try parseURL(components)
        }
        return try parseCompactReference(trimmed)
    }

    private func parseURL(
        _ components: URLComponents
    ) throws -> HuggingFaceRepositoryReference {
        let host = components.host?.lowercased() ?? ""
        guard
            ["modelscope.cn", "www.modelscope.cn"].contains(host),
            components.scheme?.lowercased() == "https"
        else {
            throw ModelScopeReferenceError.unsupportedHost(
                host.isEmpty ? "unknown host" : host
            )
        }
        let segments = components.path.split(
            separator: "/",
            omittingEmptySubsequences: true
        ).map(String.init)
        guard
            segments.count >= 3,
            segments[0] == "models"
        else {
            throw ModelScopeReferenceError.missingRepository
        }
        let repositoryID = "\(segments[1])/\(segments[2])"
        try validateRepositoryID(repositoryID)
        return HuggingFaceRepositoryReference(
            repositoryID: repositoryID,
            revision: "master"
        )
    }

    private func parseCompactReference(
        _ candidate: String
    ) throws -> HuggingFaceRepositoryReference {
        let value = candidate.trimmingCharacters(
            in: .whitespacesAndNewlines.union(
                CharacterSet(charactersIn: "\"'")
            )
        )
        let separator = value.lastIndex(of: ":")
        let repositoryID: String
        let quantization: String?
        if let separator, separator > value.startIndex {
            repositoryID = String(value[..<separator])
            let label = String(
                value[value.index(after: separator)...]
            )
            try validateQuantization(label)
            quantization = label
        } else {
            repositoryID = value
            quantization = nil
        }
        try validateRepositoryID(repositoryID)
        return HuggingFaceRepositoryReference(
            repositoryID: repositoryID,
            revision: "master",
            quantization: quantization
        )
    }

    private func validateRepositoryID(
        _ repositoryID: String
    ) throws {
        let segments = repositoryID.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard
            segments.count == 2,
            segments.allSatisfy({
                isSafeIdentifierComponent(String($0))
            })
        else {
            throw ModelScopeReferenceError.invalidRepositoryID(
                repositoryID
            )
        }
    }

    private func validateQuantization(
        _ quantization: String
    ) throws {
        guard
            !quantization.isEmpty,
            quantization.allSatisfy({
                $0.isLetter
                    || $0.isNumber
                    || $0 == "_"
                    || $0 == "-"
                    || $0 == "."
            })
        else {
            throw ModelScopeReferenceError.invalidQuantization(
                quantization
            )
        }
    }

    private func isSafeIdentifierComponent(
        _ value: String
    ) -> Bool {
        guard
            !value.isEmpty,
            value != ".",
            value != "..",
            value.count <= 128
        else {
            return false
        }
        return value.allSatisfy {
            $0.isLetter
                || $0.isNumber
                || $0 == "_"
                || $0 == "-"
                || $0 == "."
        }
    }
}
