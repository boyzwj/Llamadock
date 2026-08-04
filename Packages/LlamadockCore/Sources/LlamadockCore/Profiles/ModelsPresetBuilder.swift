import Foundation

public enum ModelsPresetError: Error, Equatable, Sendable {
    case noEnabledModels
    case duplicateIdentifier(String)
    case invalidIdentifier(String)
    case modelPathMustBeAbsolute(String)
    case conflictingExtraArgument(String)
    case malformedExtraArguments
    case unsupportedFlag(String)
}

public struct RouterServerOptions: Equatable, Sendable {
    public var host: String
    public var port: UInt16
    public var maximumLoadedModels: Int
    public var modelsAutoload: Bool

    public init(
        host: String = "127.0.0.1",
        port: UInt16 = ServerOptions.defaultPort,
        maximumLoadedModels: Int = 4,
        modelsAutoload: Bool = true
    ) {
        self.host = host
        self.port = port
        self.maximumLoadedModels = maximumLoadedModels
        self.modelsAutoload = modelsAutoload
    }
}

public struct ModelsPresetDocument: Equatable, Sendable {
    public let contents: String
    public let profileIDs: [UUID]
    public let modelIdentifiers: [String]

    public init(
        contents: String,
        profileIDs: [UUID],
        modelIdentifiers: [String]
    ) {
        self.contents = contents
        self.profileIDs = profileIDs
        self.modelIdentifiers = modelIdentifiers
    }
}

public struct ModelsPresetBuilder: Sendable {
    public init() {}

    public func makeDocument(
        profiles: [LaunchProfile],
        globalOptions: GlobalModelOptions = GlobalModelOptions(),
        runtime: RuntimeInstallation
    ) throws -> ModelsPresetDocument {
        let enabledProfiles = profiles.filter(\.router.isEnabled)
        guard !enabledProfiles.isEmpty else {
            throw ModelsPresetError.noEnabledModels
        }

        var identifiers: Set<String> = []
        for profile in enabledProfiles {
            let identifier = profile.router.identifier
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard
                !identifier.isEmpty,
                !identifier.contains("["),
                !identifier.contains("]"),
                !identifier.contains("\n"),
                !identifier.contains("\r"),
                identifier != "*"
            else {
                throw ModelsPresetError.invalidIdentifier(
                    profile.router.identifier
                )
            }
            guard identifiers.insert(identifier).inserted else {
                throw ModelsPresetError.duplicateIdentifier(identifier)
            }
            guard NSString(string: profile.model.mainPath).isAbsolutePath else {
                throw ModelsPresetError.modelPathMustBeAbsolute(
                    profile.model.mainPath
                )
            }
        }

        var lines = ["version = 1", "", "[*]"]
        try appendGlobalSettings(
            globalOptions,
            runtime: runtime,
            to: &lines
        )
        for profile in enabledProfiles {
            lines.append("")
            lines.append("[\(profile.router.identifier)]")
            try append(
                key: "model",
                value: profile.model.mainPath,
                flag: "--model",
                runtime: runtime,
                to: &lines
            )
            try appendOptionalPath(
                key: "mmproj",
                value: profile.model.mmprojPath,
                flag: "--mmproj",
                runtime: runtime,
                to: &lines
            )
            try appendOptionalPath(
                key: "model-draft",
                value: profile.model.draftPath,
                flag: "--model-draft",
                runtime: runtime,
                to: &lines
            )
            try appendTypedSettings(
                profile,
                runtime: runtime,
                to: &lines
            )
            lines.append(
                "load-on-startup = \(profile.router.loadOnStartup ? "true" : "false")"
            )
            if let stopTimeout = profile.router.stopTimeout {
                lines.append("stop-timeout = \(max(stopTimeout, 0))")
            }
            try appendExtraArguments(
                profile.extraArguments,
                runtime: runtime,
                to: &lines
            )
        }
        lines.append("")

        return ModelsPresetDocument(
            contents: lines.joined(separator: "\n"),
            profileIDs: enabledProfiles.map(\.id),
            modelIdentifiers: enabledProfiles.map(\.router.identifier)
        )
    }

    private func appendGlobalSettings(
        _ options: GlobalModelOptions,
        runtime: RuntimeInstallation,
        to lines: inout [String]
    ) throws {
        var options = options
        options.normalize()
        try append(
            key: "ctx-size",
            value: String(options.contextSize),
            flag: "--ctx-size",
            runtime: runtime,
            to: &lines
        )
        try append(
            key: "cache-type-k",
            value: options.cacheTypeK.rawValue,
            flag: "--cache-type-k",
            runtime: runtime,
            to: &lines
        )
        try append(
            key: "cache-type-v",
            value: options.cacheTypeV.rawValue,
            flag: "--cache-type-v",
            runtime: runtime,
            to: &lines
        )
        try append(
            key: "n-gpu-layers",
            value: options.gpuLayers.rawValue,
            flag: "--n-gpu-layers",
            runtime: runtime,
            to: &lines
        )
        if options.kvOffload {
            try append(
                key: "kv-offload",
                value: "true",
                flag: "--kv-offload",
                runtime: runtime,
                to: &lines
            )
        } else {
            try append(
                key: "no-kv-offload",
                value: "true",
                flag: "--no-kv-offload",
                runtime: runtime,
                to: &lines
            )
        }
        try append(
            key: "fit",
            value: options.fitToMemory ? "on" : "off",
            flag: "--fit",
            runtime: runtime,
            to: &lines
        )
        try append(
            key: "fit-target",
            value: String(options.fitTargetMiB),
            flag: "--fit-target",
            runtime: runtime,
            to: &lines
        )
        try append(
            key: "fit-ctx",
            value: String(options.fitContextSize),
            flag: "--fit-ctx",
            runtime: runtime,
            to: &lines
        )
        try append(
            key: "flash-attn",
            value: options.flashAttention.rawValue,
            flag: "--flash-attn",
            runtime: runtime,
            to: &lines
        )
        try append(
            key: "threads",
            value: String(options.threads),
            flag: "--threads",
            runtime: runtime,
            to: &lines
        )
        try append(
            key: "parallel",
            value: String(options.parallel),
            flag: "--parallel",
            runtime: runtime,
            to: &lines
        )
        try append(
            key: "batch-size",
            value: String(options.batchSize),
            flag: "--batch-size",
            runtime: runtime,
            to: &lines
        )
        try append(
            key: "ubatch-size",
            value: String(options.ubatchSize),
            flag: "--ubatch-size",
            runtime: runtime,
            to: &lines
        )
    }

    public func makeInvocation(
        presetURL: URL,
        options: RouterServerOptions,
        runtime: RuntimeInstallation
    ) throws -> ProcessInvocation {
        guard presetURL.isFileURL else {
            throw ModelsPresetError.modelPathMustBeAbsolute(
                presetURL.absoluteString
            )
        }

        var arguments: [String] = []
        try appendArgument(
            "--host",
            options.host,
            runtime: runtime,
            to: &arguments
        )
        try appendArgument(
            "--port",
            String(options.port),
            runtime: runtime,
            to: &arguments
        )
        try appendArgument(
            "--models-preset",
            presetURL.path,
            runtime: runtime,
            to: &arguments
        )
        try appendArgument(
            "--models-max",
            String(max(options.maximumLoadedModels, 0)),
            runtime: runtime,
            to: &arguments
        )
        let autoloadFlag = options.modelsAutoload
            ? "--models-autoload"
            : "--no-models-autoload"
        try requireSupport(autoloadFlag, runtime: runtime)
        arguments.append(autoloadFlag)

        return try ProcessInvocation(
            executableURL: runtime.serverURL,
            arguments: arguments
        )
    }

    private func appendTypedSettings(
        _ profile: LaunchProfile,
        runtime: RuntimeInstallation,
        to lines: inout [String]
    ) throws {
        try appendOptional(
            key: "ctx-size",
            value: profile.server.contextSize.map(String.init),
            flag: "--ctx-size",
            runtime: runtime,
            to: &lines
        )
        try appendOptional(
            key: "n-gpu-layers",
            value: profile.server.gpuLayers.map(String.init),
            flag: "--n-gpu-layers",
            runtime: runtime,
            to: &lines
        )
        try appendOptional(
            key: "threads",
            value: profile.server.threads.map(String.init),
            flag: "--threads",
            runtime: runtime,
            to: &lines
        )
        try appendOptional(
            key: "parallel",
            value: profile.server.parallel.map(String.init),
            flag: "--parallel",
            runtime: runtime,
            to: &lines
        )
        try appendOptional(
            key: "batch-size",
            value: profile.server.batchSize.map(String.init),
            flag: "--batch-size",
            runtime: runtime,
            to: &lines
        )
        try appendOptional(
            key: "ubatch-size",
            value: profile.server.ubatchSize.map(String.init),
            flag: "--ubatch-size",
            runtime: runtime,
            to: &lines
        )
        try appendOptional(
            key: "flash-attn",
            value: profile.server.flashAttention.map {
                $0 ? "on" : "off"
            },
            flag: "--flash-attn",
            runtime: runtime,
            to: &lines
        )
        try appendOptional(
            key: "cache-type-k",
            value: profile.server.cacheTypeK,
            flag: "--cache-type-k",
            runtime: runtime,
            to: &lines
        )
        try appendOptional(
            key: "cache-type-v",
            value: profile.server.cacheTypeV,
            flag: "--cache-type-v",
            runtime: runtime,
            to: &lines
        )
        try appendOptional(
            key: "system-prompt",
            value: profile.server.systemPrompt,
            flag: "--system-prompt",
            runtime: runtime,
            to: &lines
        )
        try appendOptional(
            key: "temp",
            value: profile.sampling.temperature.map { String($0) },
            flag: "--temp",
            runtime: runtime,
            to: &lines
        )
        try appendOptional(
            key: "top-k",
            value: profile.sampling.topK.map(String.init),
            flag: "--top-k",
            runtime: runtime,
            to: &lines
        )
        try appendOptional(
            key: "top-p",
            value: profile.sampling.topP.map { String($0) },
            flag: "--top-p",
            runtime: runtime,
            to: &lines
        )
        try appendOptional(
            key: "min-p",
            value: profile.sampling.minP.map { String($0) },
            flag: "--min-p",
            runtime: runtime,
            to: &lines
        )
        try appendOptional(
            key: "repeat-penalty",
            value: profile.sampling.repeatPenalty.map { String($0) },
            flag: "--repeat-penalty",
            runtime: runtime,
            to: &lines
        )
        try appendOptional(
            key: "seed",
            value: profile.sampling.seed.map(String.init),
            flag: "--seed",
            runtime: runtime,
            to: &lines
        )
    }

    private func appendExtraArguments(
        _ arguments: [String],
        runtime: RuntimeInstallation,
        to lines: inout [String]
    ) throws {
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            guard flag.hasPrefix("-") else {
                throw ModelsPresetError.malformedExtraArguments
            }
            guard !Self.routerControlledFlags.contains(flag) else {
                throw ModelsPresetError.conflictingExtraArgument(flag)
            }
            try requireSupport(flag, runtime: runtime)
            let key = flag.drop(while: { $0 == "-" })
            guard !key.isEmpty else {
                throw ModelsPresetError.malformedExtraArguments
            }
            let nextIndex = index + 1
            if
                nextIndex < arguments.count,
                (
                    !arguments[nextIndex].hasPrefix("-")
                        || Double(arguments[nextIndex]) != nil
                )
            {
                lines.append("\(key) = \(sanitize(arguments[nextIndex]))")
                index += 2
            } else {
                lines.append("\(key) = true")
                index += 1
            }
        }
    }

    private func appendOptionalPath(
        key: String,
        value: String?,
        flag: String,
        runtime: RuntimeInstallation,
        to lines: inout [String]
    ) throws {
        guard let value else {
            return
        }
        guard NSString(string: value).isAbsolutePath else {
            throw ModelsPresetError.modelPathMustBeAbsolute(value)
        }
        try append(
            key: key,
            value: value,
            flag: flag,
            runtime: runtime,
            to: &lines
        )
    }

    private func appendOptional(
        key: String,
        value: String?,
        flag: String,
        runtime: RuntimeInstallation,
        to lines: inout [String]
    ) throws {
        guard let value else {
            return
        }
        try append(
            key: key,
            value: value,
            flag: flag,
            runtime: runtime,
            to: &lines
        )
    }

    private func append(
        key: String,
        value: String,
        flag: String,
        runtime: RuntimeInstallation,
        to lines: inout [String]
    ) throws {
        try requireSupport(flag, runtime: runtime)
        lines.append("\(key) = \(sanitize(value))")
    }

    private func appendArgument(
        _ flag: String,
        _ value: String,
        runtime: RuntimeInstallation,
        to arguments: inout [String]
    ) throws {
        try requireSupport(flag, runtime: runtime)
        arguments.append(contentsOf: [flag, value])
    }

    private func requireSupport(
        _ flag: String,
        runtime: RuntimeInstallation
    ) throws {
        if runtime.capabilities.support(for: flag) == .unsupported {
            throw ModelsPresetError.unsupportedFlag(flag)
        }
    }

    private func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static let routerControlledFlags: Set<String> = [
        "--model",
        "-m",
        "--alias",
        "-a",
        "--host",
        "--port",
        "--models-dir",
        "--models-preset",
        "--models-max",
        "--models-autoload",
        "--no-models-autoload",
    ]
}
