import Foundation

public enum HuggingFaceReferenceError:
    Error,
    Equatable,
    Sendable
{
    case emptyInput
    case missingRepository
    case unsupportedHost(String)
    case invalidRepositoryID(String)
    case invalidRevision(String)
    case invalidQuantization(String)
    case unterminatedQuote
}

extension HuggingFaceReferenceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            "Enter a Hugging Face repository or llama -hf command."
        case .missingRepository:
            "The command does not include a repository after -hf."
        case .unsupportedHost(let host):
            "Only huggingface.co repository URLs are supported, not \(host)."
        case .invalidRepositoryID(let value):
            "Invalid Hugging Face repository ID: \(value)."
        case .invalidRevision(let value):
            "Invalid Hugging Face revision: \(value)."
        case .invalidQuantization(let value):
            "Invalid GGUF quantization label: \(value)."
        case .unterminatedQuote:
            "The pasted command contains an unterminated quote."
        }
    }
}

public struct HuggingFaceReferenceParser: Sendable {
    public init() {}

    public func parse(
        _ input: String
    ) throws -> HuggingFaceRepositoryReference {
        let trimmed = input.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else {
            throw HuggingFaceReferenceError.emptyInput
        }

        let candidate = try repositoryCandidate(from: trimmed)
        if
            let components = URLComponents(string: candidate),
            let scheme = components.scheme,
            !scheme.isEmpty
        {
            return try parseURL(components)
        }
        return try parseCompactReference(candidate)
    }

    private func repositoryCandidate(
        from input: String
    ) throws -> String {
        let tokens = try tokenize(input)
        if let flagIndex = tokens.firstIndex(
            where: { $0 == "-hf" || $0 == "--hf-repo" }
        ) {
            let valueIndex = tokens.index(after: flagIndex)
            guard tokens.indices.contains(valueIndex) else {
                throw HuggingFaceReferenceError.missingRepository
            }
            return tokens[valueIndex]
        }
        if let token = tokens.first(
            where: {
                $0.hasPrefix("-hf=")
                    || $0.hasPrefix("--hf-repo=")
            }
        ) {
            guard let equals = token.firstIndex(of: "=") else {
                throw HuggingFaceReferenceError.missingRepository
            }
            let value = String(token[token.index(after: equals)...])
            guard !value.isEmpty else {
                throw HuggingFaceReferenceError.missingRepository
            }
            return value
        }
        return input
    }

    private func parseURL(
        _ components: URLComponents
    ) throws -> HuggingFaceRepositoryReference {
        let host = components.host?.lowercased() ?? ""
        guard host == "huggingface.co" || host == "www.huggingface.co" else {
            throw HuggingFaceReferenceError.unsupportedHost(
                host.isEmpty ? "unknown host" : host
            )
        }
        guard components.scheme?.lowercased() == "https" else {
            throw HuggingFaceReferenceError.unsupportedHost(host)
        }

        let segments = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard segments.count >= 2 else {
            throw HuggingFaceReferenceError.missingRepository
        }
        let repositoryID = "\(segments[0])/\(segments[1])"
        try validateRepositoryID(repositoryID)

        var revision = "main"
        if
            segments.count >= 4,
            ["tree", "blob", "resolve"].contains(segments[2])
        {
            revision = segments[3].removingPercentEncoding
                ?? segments[3]
        }
        try validateRevision(revision)

        return HuggingFaceRepositoryReference(
            repositoryID: repositoryID,
            revision: revision
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
        let quantizationSeparator = value.lastIndex(of: ":")
        let repositoryID: String
        let quantization: String?
        if
            let quantizationSeparator,
            quantizationSeparator > value.startIndex
        {
            repositoryID = String(value[..<quantizationSeparator])
            let label = String(
                value[value.index(after: quantizationSeparator)...]
            )
            guard !label.isEmpty else {
                throw HuggingFaceReferenceError.invalidQuantization(label)
            }
            try validateQuantization(label)
            quantization = label
        } else {
            repositoryID = value
            quantization = nil
        }

        try validateRepositoryID(repositoryID)
        return HuggingFaceRepositoryReference(
            repositoryID: repositoryID,
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
            throw HuggingFaceReferenceError.invalidRepositoryID(
                repositoryID
            )
        }
    }

    private func validateRevision(
        _ revision: String
    ) throws {
        guard
            !revision.isEmpty,
            revision != ".",
            revision != "..",
            !revision.contains("\\"),
            !revision.contains(where: \.isNewline)
        else {
            throw HuggingFaceReferenceError.invalidRevision(revision)
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
            throw HuggingFaceReferenceError.invalidQuantization(
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

    private func tokenize(
        _ value: String
    ) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var isEscaping = false

        for character in value {
            if isEscaping {
                current.append(character)
                isEscaping = false
                continue
            }
            if character == "\\", quote != "'" {
                isEscaping = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
            } else if character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }

        guard quote == nil else {
            throw HuggingFaceReferenceError.unterminatedQuote
        }
        if isEscaping {
            current.append("\\")
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

}
