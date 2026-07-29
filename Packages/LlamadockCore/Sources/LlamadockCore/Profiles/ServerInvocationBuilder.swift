import Foundation

public enum ServerInvocationError: Error, Equatable, Sendable {
    case modelPathMustBeAbsolute(String)
    case conflictingExtraArgument(String)
    case unsupportedFlag(String)
}

public struct ServerInvocationBuilder: Sendable {
    public init() {}

    public func makeServerInvocation(
        profile: LaunchProfile,
        runtime: RuntimeInstallation
    ) throws -> ProcessInvocation {
        guard NSString(string: profile.model.mainPath).isAbsolutePath else {
            throw ServerInvocationError.modelPathMustBeAbsolute(
                profile.model.mainPath
            )
        }

        if let conflict = profile.extraArguments.first(
            where: Self.managedFlags.contains
        ) {
            throw ServerInvocationError.conflictingExtraArgument(conflict)
        }

        var arguments: [String] = []
        try append(
            "--model",
            profile.model.mainPath,
            runtime: runtime,
            to: &arguments
        )
        try appendOptional(
            "--alias",
            profile.server.alias,
            runtime: runtime,
            to: &arguments
        )
        try append(
            "--host",
            profile.server.host,
            runtime: runtime,
            to: &arguments
        )
        try append(
            "--port",
            String(profile.server.port),
            runtime: runtime,
            to: &arguments
        )
        try appendOptional(
            "--ctx-size",
            profile.server.contextSize.map(String.init),
            runtime: runtime,
            to: &arguments
        )
        try appendOptional(
            "--n-gpu-layers",
            profile.server.gpuLayers.map(String.init),
            runtime: runtime,
            to: &arguments
        )
        try appendOptional(
            "--threads",
            profile.server.threads.map(String.init),
            runtime: runtime,
            to: &arguments
        )
        try appendOptional(
            "--parallel",
            profile.server.parallel.map(String.init),
            runtime: runtime,
            to: &arguments
        )
        try appendOptional(
            "--batch-size",
            profile.server.batchSize.map(String.init),
            runtime: runtime,
            to: &arguments
        )
        try appendOptional(
            "--ubatch-size",
            profile.server.ubatchSize.map(String.init),
            runtime: runtime,
            to: &arguments
        )
        try appendOptional(
            "--flash-attn",
            profile.server.flashAttention.map { $0 ? "on" : "off" },
            runtime: runtime,
            to: &arguments
        )
        try appendOptional(
            "--cache-type-k",
            profile.server.cacheTypeK,
            runtime: runtime,
            to: &arguments
        )
        try appendOptional(
            "--cache-type-v",
            profile.server.cacheTypeV,
            runtime: runtime,
            to: &arguments
        )
        try appendOptionalPath(
            "--mmproj",
            profile.model.mmprojPath,
            runtime: runtime,
            to: &arguments
        )
        try appendOptionalPath(
            "--model-draft",
            profile.model.draftPath,
            runtime: runtime,
            to: &arguments
        )
        try appendOptional(
            "--system-prompt",
            profile.server.systemPrompt,
            runtime: runtime,
            to: &arguments
        )
        try appendOptional(
            "--temp",
            profile.sampling.temperature.map { String($0) },
            runtime: runtime,
            to: &arguments
        )
        try appendOptional(
            "--top-k",
            profile.sampling.topK.map(String.init),
            runtime: runtime,
            to: &arguments
        )
        try appendOptional(
            "--top-p",
            profile.sampling.topP.map { String($0) },
            runtime: runtime,
            to: &arguments
        )
        try appendOptional(
            "--min-p",
            profile.sampling.minP.map { String($0) },
            runtime: runtime,
            to: &arguments
        )
        try appendOptional(
            "--repeat-penalty",
            profile.sampling.repeatPenalty.map { String($0) },
            runtime: runtime,
            to: &arguments
        )
        try appendOptional(
            "--seed",
            profile.sampling.seed.map(String.init),
            runtime: runtime,
            to: &arguments
        )

        arguments.append(contentsOf: profile.extraArguments)

        return try ProcessInvocation(
            executableURL: runtime.serverURL,
            arguments: arguments
        )
    }

    private func appendOptionalPath(
        _ flag: String,
        _ path: String?,
        runtime: RuntimeInstallation,
        to arguments: inout [String]
    ) throws {
        guard let path else {
            return
        }
        guard NSString(string: path).isAbsolutePath else {
            throw ServerInvocationError.modelPathMustBeAbsolute(path)
        }
        try append(flag, path, runtime: runtime, to: &arguments)
    }

    private func appendOptional(
        _ flag: String,
        _ value: String?,
        runtime: RuntimeInstallation,
        to arguments: inout [String]
    ) throws {
        guard let value else {
            return
        }
        try append(flag, value, runtime: runtime, to: &arguments)
    }

    private func append(
        _ flag: String,
        _ value: String,
        runtime: RuntimeInstallation,
        to arguments: inout [String]
    ) throws {
        if runtime.capabilities.support(for: flag) == .unsupported {
            throw ServerInvocationError.unsupportedFlag(flag)
        }
        arguments.append(contentsOf: [flag, value])
    }

    private static let managedFlags: Set<String> = [
        "--model",
        "--alias",
        "--host",
        "--port",
        "--ctx-size",
        "--n-gpu-layers",
        "--threads",
        "--parallel",
        "--batch-size",
        "--ubatch-size",
        "--flash-attn",
        "--cache-type-k",
        "--cache-type-v",
        "--mmproj",
        "--model-draft",
        "--system-prompt",
        "--temp",
        "--top-k",
        "--top-p",
        "--min-p",
        "--repeat-penalty",
        "--seed",
    ]
}
