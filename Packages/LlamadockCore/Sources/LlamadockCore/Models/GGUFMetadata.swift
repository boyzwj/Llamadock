import Foundation

public struct GGUFReadLimits: Equatable, Sendable {
    public let maximumMetadataEntries: UInt64
    public let maximumTensorCount: UInt64
    public let maximumArrayElements: UInt64
    public let maximumValueStringBytes: UInt64
    public let maximumArrayNestingDepth: Int
    public let maximumTensorDimensions: UInt32
    public let maximumHeaderBytes: UInt64

    public init(
        maximumMetadataEntries: UInt64 = 100_000,
        maximumTensorCount: UInt64 = 1_000_000,
        maximumArrayElements: UInt64 = 10_000_000,
        maximumValueStringBytes: UInt64 = 16 * 1_024 * 1_024,
        maximumArrayNestingDepth: Int = 8,
        maximumTensorDimensions: UInt32 = 8,
        maximumHeaderBytes: UInt64 = 512 * 1_024 * 1_024
    ) {
        self.maximumMetadataEntries = maximumMetadataEntries
        self.maximumTensorCount = maximumTensorCount
        self.maximumArrayElements = maximumArrayElements
        self.maximumValueStringBytes = maximumValueStringBytes
        self.maximumArrayNestingDepth = maximumArrayNestingDepth
        self.maximumTensorDimensions = maximumTensorDimensions
        self.maximumHeaderBytes = maximumHeaderBytes
    }
}

public struct GGUFShardMetadata: Equatable, Sendable {
    public let zeroBasedIndex: UInt64
    public let count: UInt64
    public let totalTensorCount: UInt64?

    public init(
        zeroBasedIndex: UInt64,
        count: UInt64,
        totalTensorCount: UInt64?
    ) {
        self.zeroBasedIndex = zeroBasedIndex
        self.count = count
        self.totalTensorCount = totalTensorCount
    }
}

public struct GGUFMetadata: Equatable, Sendable {
    public let fileURL: URL
    public let formatVersion: UInt32
    public let fileSize: UInt64
    public let headerByteCount: UInt64
    public let metadataCount: UInt64
    public let tensorCount: UInt64
    public let parameterCount: UInt64
    public let name: String?
    public let architecture: String
    public let modelKind: String?
    public let sizeLabel: String?
    public let fileType: UInt64?
    public let quantization: String?
    public let contextLength: UInt64?
    public let hasChatTemplate: Bool
    public let shard: GGUFShardMetadata?

    public init(
        fileURL: URL,
        formatVersion: UInt32,
        fileSize: UInt64,
        headerByteCount: UInt64,
        metadataCount: UInt64,
        tensorCount: UInt64,
        parameterCount: UInt64,
        name: String?,
        architecture: String,
        modelKind: String?,
        sizeLabel: String?,
        fileType: UInt64?,
        quantization: String?,
        contextLength: UInt64?,
        hasChatTemplate: Bool,
        shard: GGUFShardMetadata?
    ) {
        self.fileURL = fileURL.standardizedFileURL
        self.formatVersion = formatVersion
        self.fileSize = fileSize
        self.headerByteCount = headerByteCount
        self.metadataCount = metadataCount
        self.tensorCount = tensorCount
        self.parameterCount = parameterCount
        self.name = name
        self.architecture = architecture
        self.modelKind = modelKind
        self.sizeLabel = sizeLabel
        self.fileType = fileType
        self.quantization = quantization
        self.contextLength = contextLength
        self.hasChatTemplate = hasChatTemplate
        self.shard = shard
    }
}

public enum GGUFMetadataError:
    Error,
    Equatable,
    Sendable
{
    case notRegularFile(URL)
    case invalidMagic
    case unsupportedVersion(UInt32)
    case truncated(offset: UInt64)
    case countExceedsLimit(
        field: String,
        value: UInt64,
        maximum: UInt64
    )
    case stringExceedsLimit(
        field: String,
        value: UInt64,
        maximum: UInt64
    )
    case invalidUTF8(field: String)
    case invalidMetadataKey(String)
    case duplicateMetadataKey(String)
    case invalidMetadataType(UInt32)
    case invalidMetadataValue(key: String, expected: String)
    case excessiveArrayNesting(maximum: Int)
    case missingRequiredMetadata(String)
    case invalidAlignment(UInt64)
    case invalidTensorDimensions(
        name: String,
        count: UInt32
    )
    case tensorOffsetOutsideFile(
        name: String,
        offset: UInt64
    )
    case integerOverflow(field: String)
    case incompleteSplitMetadata
    case invalidSplitMetadata
}

extension GGUFMetadataError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notRegularFile(let url):
            "The GGUF model is not a regular file: \(url.path)"
        case .invalidMagic:
            "The model does not begin with the GGUF magic bytes."
        case .unsupportedVersion(let version):
            "GGUF version \(version) is not supported."
        case .truncated(let offset):
            "The GGUF header is truncated near byte \(offset)."
        case .countExceedsLimit(let field, let value, let maximum):
            "\(field) is \(value), exceeding the safe limit of \(maximum)."
        case .stringExceedsLimit(let field, let value, let maximum):
            "\(field) is \(value) bytes, exceeding the safe limit of \(maximum)."
        case .invalidUTF8(let field):
            "\(field) is not valid UTF-8."
        case .invalidMetadataKey(let key):
            "The GGUF metadata key is invalid: \(key)"
        case .duplicateMetadataKey(let key):
            "The GGUF metadata key is duplicated: \(key)"
        case .invalidMetadataType(let type):
            "The GGUF metadata value type is invalid: \(type)"
        case .invalidMetadataValue(let key, let expected):
            "GGUF metadata \(key) must be \(expected)."
        case .excessiveArrayNesting(let maximum):
            "GGUF metadata arrays exceed the nesting limit of \(maximum)."
        case .missingRequiredMetadata(let key):
            "The GGUF model is missing required metadata: \(key)"
        case .invalidAlignment(let alignment):
            "The GGUF alignment is invalid: \(alignment)"
        case .invalidTensorDimensions(let name, let count):
            "Tensor \(name) has an invalid dimension count: \(count)."
        case .tensorOffsetOutsideFile(let name, let offset):
            "Tensor \(name) begins outside the GGUF tensor data at offset \(offset)."
        case .integerOverflow(let field):
            "\(field) overflows a 64-bit unsigned integer."
        case .incompleteSplitMetadata:
            "The GGUF split metadata is incomplete."
        case .invalidSplitMetadata:
            "The GGUF split index or count is invalid."
        }
    }
}

public struct GGUFMetadataReader: @unchecked Sendable {
    private let limits: GGUFReadLimits
    private let fileManager: FileManager

    public init(
        limits: GGUFReadLimits = GGUFReadLimits(),
        fileManager: FileManager = .default
    ) {
        self.limits = limits
        self.fileManager = fileManager
    }

    public func read(
        from fileURL: URL
    ) throws -> GGUFMetadata {
        let url = fileURL.standardizedFileURL
        let values = try url.resourceValues(
            forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ]
        )
        guard
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            let signedFileSize = values.fileSize,
            signedFileSize >= 0
        else {
            throw GGUFMetadataError.notRegularFile(url)
        }
        let fileSize = UInt64(signedFileSize)

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var reader = GGUFBufferedReader(
            handle: handle,
            fileSize: fileSize
        )

        guard try reader.readData(count: 4) == Data("GGUF".utf8) else {
            throw GGUFMetadataError.invalidMagic
        }
        let rawVersion = try reader.readData(count: 4)
        let versionAndOrder = try parseVersion(rawVersion)
        let version = versionAndOrder.version
        let byteOrder = versionAndOrder.byteOrder

        let tensorCount = try reader.readUInt64(
            byteOrder: byteOrder
        )
        try requireCount(
            tensorCount,
            field: "tensor_count",
            maximum: limits.maximumTensorCount
        )
        let metadataCount = try reader.readUInt64(
            byteOrder: byteOrder
        )
        try requireCount(
            metadataCount,
            field: "metadata_kv_count",
            maximum: limits.maximumMetadataEntries
        )

        var captured = CapturedMetadata()
        var contextLengths: [String: UInt64] = [:]
        var keys = Set<String>()
        keys.reserveCapacity(
            Int(min(metadataCount, UInt64(Int.max)))
        )

        for _ in 0..<metadataCount {
            try requireHeaderPosition(reader.position)
            let key = try readString(
                reader: &reader,
                byteOrder: byteOrder,
                field: "metadata key",
                maximum: 65_535
            )
            try validateMetadataKey(key)
            guard keys.insert(key).inserted else {
                throw GGUFMetadataError
                    .duplicateMetadataKey(key)
            }
            let type = try readValueType(
                reader: &reader,
                byteOrder: byteOrder
            )

            switch key {
            case "general.name":
                captured.name = try readRequiredString(
                    key: key,
                    type: type,
                    reader: &reader,
                    byteOrder: byteOrder
                )
            case "general.architecture":
                captured.architecture = try readRequiredString(
                    key: key,
                    type: type,
                    reader: &reader,
                    byteOrder: byteOrder
                )
            case "general.type":
                captured.modelKind = try readRequiredString(
                    key: key,
                    type: type,
                    reader: &reader,
                    byteOrder: byteOrder
                )
            case "general.size_label":
                captured.sizeLabel = try readRequiredString(
                    key: key,
                    type: type,
                    reader: &reader,
                    byteOrder: byteOrder
                )
            case "general.file_type":
                captured.fileType = try readUnsignedInteger(
                    key: key,
                    type: type,
                    reader: &reader,
                    byteOrder: byteOrder
                )
            case "general.alignment":
                captured.alignment = try readUnsignedInteger(
                    key: key,
                    type: type,
                    reader: &reader,
                    byteOrder: byteOrder
                )
            case "split.no":
                captured.splitIndex = try readUnsignedInteger(
                    key: key,
                    type: type,
                    reader: &reader,
                    byteOrder: byteOrder
                )
            case "split.count":
                captured.splitCount = try readUnsignedInteger(
                    key: key,
                    type: type,
                    reader: &reader,
                    byteOrder: byteOrder
                )
            case "split.tensors.count":
                captured.splitTensorCount =
                    try readUnsignedInteger(
                        key: key,
                        type: type,
                        reader: &reader,
                        byteOrder: byteOrder
                    )
            default:
                if
                    key.hasSuffix(".context_length"),
                    type.isInteger
                {
                    contextLengths[key] = try readUnsignedInteger(
                        key: key,
                        type: type,
                        reader: &reader,
                        byteOrder: byteOrder
                    )
                } else {
                    if
                        key == "tokenizer.chat_template"
                            || key.hasPrefix(
                                "tokenizer.chat_template."
                            )
                            || key == "tokenizer.chat_templates"
                    {
                        captured.hasChatTemplate = true
                    }
                    try skipValue(
                        type,
                        reader: &reader,
                        byteOrder: byteOrder,
                        depth: 0
                    )
                }
            }
        }

        guard
            let architecture = captured.architecture,
            !architecture.isEmpty
        else {
            throw GGUFMetadataError.missingRequiredMetadata(
                "general.architecture"
            )
        }
        let alignment = captured.alignment ?? 32
        guard
            alignment >= 8,
            alignment <= 4_096,
            alignment.isMultiple(of: 8)
        else {
            throw GGUFMetadataError.invalidAlignment(alignment)
        }

        var parameterCount: UInt64 = 0
        var greatestTensorOffset: (name: String, offset: UInt64)?
        for _ in 0..<tensorCount {
            try requireHeaderPosition(reader.position)
            let name = try readString(
                reader: &reader,
                byteOrder: byteOrder,
                field: "tensor name",
                maximum: 64
            )
            let dimensionCount = try reader.readUInt32(
                byteOrder: byteOrder
            )
            guard
                dimensionCount > 0,
                dimensionCount <= limits.maximumTensorDimensions
            else {
                throw GGUFMetadataError.invalidTensorDimensions(
                    name: name,
                    count: dimensionCount
                )
            }

            var tensorElements: UInt64 = 1
            for _ in 0..<dimensionCount {
                let dimension = try reader.readUInt64(
                    byteOrder: byteOrder
                )
                guard dimension > 0 else {
                    throw GGUFMetadataError
                        .invalidTensorDimensions(
                            name: name,
                            count: dimensionCount
                        )
                }
                let product = tensorElements
                    .multipliedReportingOverflow(by: dimension)
                guard !product.overflow else {
                    throw GGUFMetadataError.integerOverflow(
                        field: "tensor \(name) element count"
                    )
                }
                tensorElements = product.partialValue
            }

            _ = try reader.readUInt32(byteOrder: byteOrder)
            let tensorOffset = try reader.readUInt64(
                byteOrder: byteOrder
            )
            guard tensorOffset.isMultiple(of: alignment) else {
                throw GGUFMetadataError.invalidAlignment(
                    tensorOffset
                )
            }
            if tensorOffset > (greatestTensorOffset?.offset ?? 0)
                || greatestTensorOffset == nil
            {
                greatestTensorOffset = (name, tensorOffset)
            }

            let sum = parameterCount.addingReportingOverflow(
                tensorElements
            )
            guard !sum.overflow else {
                throw GGUFMetadataError.integerOverflow(
                    field: "model parameter count"
                )
            }
            parameterCount = sum.partialValue
        }

        try requireHeaderPosition(reader.position)
        let tensorDataOffset = try alignedOffset(
            reader.position,
            alignment: alignment
        )
        guard tensorDataOffset <= fileSize else {
            throw GGUFMetadataError.truncated(
                offset: reader.position
            )
        }
        if let greatestTensorOffset {
            let tensorDataByteCount = fileSize - tensorDataOffset
            guard greatestTensorOffset.offset < tensorDataByteCount else {
                throw GGUFMetadataError.tensorOffsetOutsideFile(
                    name: greatestTensorOffset.name,
                    offset: greatestTensorOffset.offset
                )
            }
        }

        let shard = try makeShardMetadata(captured)
        let contextLength = contextLengths[
            "\(architecture).context_length"
        ]

        return GGUFMetadata(
            fileURL: url,
            formatVersion: version,
            fileSize: fileSize,
            headerByteCount: reader.position,
            metadataCount: metadataCount,
            tensorCount: tensorCount,
            parameterCount: parameterCount,
            name: captured.name,
            architecture: architecture,
            modelKind: captured.modelKind,
            sizeLabel: captured.sizeLabel,
            fileType: captured.fileType,
            quantization: captured.fileType.flatMap(
                Self.quantizationName
            ),
            contextLength: contextLength,
            hasChatTemplate: captured.hasChatTemplate,
            shard: shard
        )
    }

    public static func quantizationName(
        for fileType: UInt64
    ) -> String? {
        quantizationNames[fileType]
    }

    private func parseVersion(
        _ data: Data
    ) throws -> (
        version: UInt32,
        byteOrder: GGUFByteOrder
    ) {
        let little = GGUFByteOrder.little.uint32(data)
        if little == 2 || little == 3 {
            return (little, .little)
        }
        let big = GGUFByteOrder.big.uint32(data)
        if big == 2 || big == 3 {
            return (big, .big)
        }
        throw GGUFMetadataError.unsupportedVersion(little)
    }

    private func requireCount(
        _ value: UInt64,
        field: String,
        maximum: UInt64
    ) throws {
        guard value <= maximum else {
            throw GGUFMetadataError.countExceedsLimit(
                field: field,
                value: value,
                maximum: maximum
            )
        }
    }

    private func requireHeaderPosition(
        _ position: UInt64
    ) throws {
        guard position <= limits.maximumHeaderBytes else {
            throw GGUFMetadataError.countExceedsLimit(
                field: "GGUF header bytes",
                value: position,
                maximum: limits.maximumHeaderBytes
            )
        }
    }

    private func readString(
        reader: inout GGUFBufferedReader,
        byteOrder: GGUFByteOrder,
        field: String,
        maximum: UInt64
    ) throws -> String {
        let length = try reader.readUInt64(
            byteOrder: byteOrder
        )
        guard length <= maximum else {
            throw GGUFMetadataError.stringExceedsLimit(
                field: field,
                value: length,
                maximum: maximum
            )
        }
        guard length <= UInt64(Int.max) else {
            throw GGUFMetadataError.stringExceedsLimit(
                field: field,
                value: length,
                maximum: UInt64(Int.max)
            )
        }
        let data = try reader.readData(count: Int(length))
        guard let value = String(data: data, encoding: .utf8) else {
            throw GGUFMetadataError.invalidUTF8(field: field)
        }
        return value
    }

    private func readRequiredString(
        key: String,
        type: GGUFValueType,
        reader: inout GGUFBufferedReader,
        byteOrder: GGUFByteOrder
    ) throws -> String {
        guard type == .string else {
            throw GGUFMetadataError.invalidMetadataValue(
                key: key,
                expected: "a string"
            )
        }
        return try readString(
            reader: &reader,
            byteOrder: byteOrder,
            field: key,
            maximum: limits.maximumValueStringBytes
        )
    }

    private func readUnsignedInteger(
        key: String,
        type: GGUFValueType,
        reader: inout GGUFBufferedReader,
        byteOrder: GGUFByteOrder
    ) throws -> UInt64 {
        switch type {
        case .uint8:
            return UInt64(try reader.readUInt8())
        case .int8:
            let value = Int8(bitPattern: try reader.readUInt8())
            return try nonnegative(value, key: key)
        case .uint16:
            return UInt64(
                try reader.readUInt16(byteOrder: byteOrder)
            )
        case .int16:
            let raw = try reader.readUInt16(byteOrder: byteOrder)
            return try nonnegative(
                Int16(bitPattern: raw),
                key: key
            )
        case .uint32:
            return UInt64(
                try reader.readUInt32(byteOrder: byteOrder)
            )
        case .int32:
            let raw = try reader.readUInt32(byteOrder: byteOrder)
            return try nonnegative(
                Int32(bitPattern: raw),
                key: key
            )
        case .uint64:
            return try reader.readUInt64(byteOrder: byteOrder)
        case .int64:
            let raw = try reader.readUInt64(byteOrder: byteOrder)
            return try nonnegative(
                Int64(bitPattern: raw),
                key: key
            )
        case .float32, .bool, .string, .array, .float64:
            throw GGUFMetadataError.invalidMetadataValue(
                key: key,
                expected: "a nonnegative integer"
            )
        }
    }

    private func nonnegative<T: BinaryInteger>(
        _ value: T,
        key: String
    ) throws -> UInt64 {
        guard value >= 0, let result = UInt64(exactly: value) else {
            throw GGUFMetadataError.invalidMetadataValue(
                key: key,
                expected: "a nonnegative integer"
            )
        }
        return result
    }

    private func readValueType(
        reader: inout GGUFBufferedReader,
        byteOrder: GGUFByteOrder
    ) throws -> GGUFValueType {
        let raw = try reader.readUInt32(byteOrder: byteOrder)
        guard let type = GGUFValueType(rawValue: raw) else {
            throw GGUFMetadataError.invalidMetadataType(raw)
        }
        return type
    }

    private func skipValue(
        _ type: GGUFValueType,
        reader: inout GGUFBufferedReader,
        byteOrder: GGUFByteOrder,
        depth: Int
    ) throws {
        if let width = type.fixedWidth {
            try reader.skip(UInt64(width))
            return
        }

        switch type {
        case .string:
            let length = try reader.readUInt64(
                byteOrder: byteOrder
            )
            try requireCount(
                length,
                field: "metadata string bytes",
                maximum: limits.maximumHeaderBytes
            )
            try reader.skip(length)
        case .array:
            guard depth < limits.maximumArrayNestingDepth else {
                throw GGUFMetadataError.excessiveArrayNesting(
                    maximum: limits.maximumArrayNestingDepth
                )
            }
            let elementType = try readValueType(
                reader: &reader,
                byteOrder: byteOrder
            )
            let count = try reader.readUInt64(
                byteOrder: byteOrder
            )
            try requireCount(
                count,
                field: "metadata array elements",
                maximum: limits.maximumArrayElements
            )

            if let width = elementType.fixedWidth {
                let byteCount = count.multipliedReportingOverflow(
                    by: UInt64(width)
                )
                guard !byteCount.overflow else {
                    throw GGUFMetadataError.integerOverflow(
                        field: "metadata array byte count"
                    )
                }
                try reader.skip(byteCount.partialValue)
                return
            }

            for _ in 0..<count {
                try skipValue(
                    elementType,
                    reader: &reader,
                    byteOrder: byteOrder,
                    depth: depth + 1
                )
            }
        case .uint8, .int8, .uint16, .int16, .uint32,
            .int32, .float32, .bool, .uint64, .int64,
            .float64:
            preconditionFailure("Fixed-width metadata was handled above.")
        }
    }

    private func validateMetadataKey(
        _ key: String
    ) throws {
        guard
            !key.isEmpty,
            key.utf8.count <= 65_535,
            key.utf8.allSatisfy({ byte in
                byte == 46
                    || byte == 45
                    || byte == 95
                    || (byte >= 48 && byte <= 57)
                    || (byte >= 97 && byte <= 122)
            }),
            !key.hasPrefix("."),
            !key.hasSuffix("."),
            !key.contains("..")
        else {
            throw GGUFMetadataError.invalidMetadataKey(key)
        }
    }

    private func alignedOffset(
        _ value: UInt64,
        alignment: UInt64
    ) throws -> UInt64 {
        let remainder = value % alignment
        guard remainder != 0 else {
            return value
        }
        let result = value.addingReportingOverflow(
            alignment - remainder
        )
        guard !result.overflow else {
            throw GGUFMetadataError.integerOverflow(
                field: "tensor data offset"
            )
        }
        return result.partialValue
    }

    private func makeShardMetadata(
        _ captured: CapturedMetadata
    ) throws -> GGUFShardMetadata? {
        let values = [
            captured.splitIndex,
            captured.splitCount,
            captured.splitTensorCount,
        ]
        guard values.contains(where: { $0 != nil }) else {
            return nil
        }
        guard
            let index = captured.splitIndex,
            let count = captured.splitCount
        else {
            throw GGUFMetadataError.incompleteSplitMetadata
        }
        if count <= 1 {
            guard index == 0 else {
                throw GGUFMetadataError.invalidSplitMetadata
            }
            return nil
        }
        guard index < count else {
            throw GGUFMetadataError.invalidSplitMetadata
        }
        return GGUFShardMetadata(
            zeroBasedIndex: index,
            count: count,
            totalTensorCount: captured.splitTensorCount
        )
    }

    private static let quantizationNames: [UInt64: String] = [
        0: "F32",
        1: "F16",
        2: "Q4_0",
        3: "Q4_1",
        4: "Q4_1 + F16",
        7: "Q8_0",
        8: "Q5_0",
        9: "Q5_1",
        10: "Q2_K",
        11: "Q3_K_S",
        12: "Q3_K_M",
        13: "Q3_K_L",
        14: "Q4_K_S",
        15: "Q4_K_M",
        16: "Q5_K_S",
        17: "Q5_K_M",
        18: "Q6_K",
        19: "IQ2_XXS",
        20: "IQ2_XS",
        21: "Q2_K_S",
        22: "IQ3_XS",
        23: "IQ3_XXS",
        24: "IQ1_S",
        25: "IQ4_NL",
        26: "IQ3_S",
        27: "IQ3_M",
        28: "IQ2_S",
        29: "IQ2_M",
        30: "IQ4_XS",
        31: "IQ1_M",
        32: "BF16",
        36: "TQ1_0",
        37: "TQ2_0",
        38: "MXFP4_MOE",
        39: "NVFP4",
        40: "Q1_0",
        41: "Q2_0",
    ]
}

private struct CapturedMetadata {
    var name: String?
    var architecture: String?
    var modelKind: String?
    var sizeLabel: String?
    var fileType: UInt64?
    var alignment: UInt64?
    var splitIndex: UInt64?
    var splitCount: UInt64?
    var splitTensorCount: UInt64?
    var hasChatTemplate = false
}

private enum GGUFValueType:
    UInt32,
    Equatable
{
    case uint8 = 0
    case int8 = 1
    case uint16 = 2
    case int16 = 3
    case uint32 = 4
    case int32 = 5
    case float32 = 6
    case bool = 7
    case string = 8
    case array = 9
    case uint64 = 10
    case int64 = 11
    case float64 = 12

    var fixedWidth: Int? {
        switch self {
        case .uint8, .int8, .bool:
            1
        case .uint16, .int16:
            2
        case .uint32, .int32, .float32:
            4
        case .uint64, .int64, .float64:
            8
        case .string, .array:
            nil
        }
    }

    var isInteger: Bool {
        switch self {
        case .uint8, .int8, .uint16, .int16, .uint32,
            .int32, .uint64, .int64:
            true
        case .float32, .bool, .string, .array, .float64:
            false
        }
    }
}

private enum GGUFByteOrder {
    case little
    case big

    func uint16(
        _ data: Data
    ) -> UInt16 {
        switch self {
        case .little:
            data.enumerated().reduce(0) { result, entry in
                result
                    | UInt16(entry.element)
                        << UInt16(entry.offset * 8)
            }
        case .big:
            data.reduce(0) { result, byte in
                result << 8 | UInt16(byte)
            }
        }
    }

    func uint32(
        _ data: Data
    ) -> UInt32 {
        switch self {
        case .little:
            data.enumerated().reduce(0) { result, entry in
                result
                    | UInt32(entry.element)
                        << UInt32(entry.offset * 8)
            }
        case .big:
            data.reduce(0) { result, byte in
                result << 8 | UInt32(byte)
            }
        }
    }

    func uint64(
        _ data: Data
    ) -> UInt64 {
        switch self {
        case .little:
            data.enumerated().reduce(0) { result, entry in
                result
                    | UInt64(entry.element)
                        << UInt64(entry.offset * 8)
            }
        case .big:
            data.reduce(0) { result, byte in
                result << 8 | UInt64(byte)
            }
        }
    }
}

private struct GGUFBufferedReader {
    private let handle: FileHandle
    private let fileSize: UInt64
    private var buffer = Data()
    private var bufferStart: UInt64 = 0
    private var cursor = 0
    private let chunkSize = 64 * 1_024

    init(
        handle: FileHandle,
        fileSize: UInt64
    ) {
        self.handle = handle
        self.fileSize = fileSize
    }

    var position: UInt64 {
        bufferStart + UInt64(cursor)
    }

    mutating func readUInt8() throws -> UInt8 {
        try readData(count: 1)[0]
    }

    mutating func readUInt16(
        byteOrder: GGUFByteOrder
    ) throws -> UInt16 {
        byteOrder.uint16(try readData(count: 2))
    }

    mutating func readUInt32(
        byteOrder: GGUFByteOrder
    ) throws -> UInt32 {
        byteOrder.uint32(try readData(count: 4))
    }

    mutating func readUInt64(
        byteOrder: GGUFByteOrder
    ) throws -> UInt64 {
        byteOrder.uint64(try readData(count: 8))
    }

    mutating func readData(
        count: Int
    ) throws -> Data {
        guard count >= 0 else {
            throw GGUFMetadataError.truncated(offset: position)
        }
        try ensureAvailable(count)
        let range = cursor..<(cursor + count)
        let result = Data(buffer[range])
        cursor += count
        return result
    }

    mutating func skip(
        _ count: UInt64
    ) throws {
        let target = position.addingReportingOverflow(count)
        guard !target.overflow, target.partialValue <= fileSize else {
            throw GGUFMetadataError.truncated(offset: position)
        }
        let remaining = UInt64(buffer.count - cursor)
        if count <= remaining {
            cursor += Int(count)
            return
        }

        try handle.seek(toOffset: target.partialValue)
        bufferStart = target.partialValue
        cursor = 0
        buffer.removeAll(keepingCapacity: true)
    }

    private mutating func ensureAvailable(
        _ count: Int
    ) throws {
        guard count > buffer.count - cursor else {
            return
        }

        if cursor > 0 {
            buffer.removeSubrange(0..<cursor)
            bufferStart += UInt64(cursor)
            cursor = 0
        }

        while buffer.count < count {
            let readCount = max(chunkSize, count - buffer.count)
            guard
                let data = try handle.read(upToCount: readCount),
                !data.isEmpty
            else {
                throw GGUFMetadataError.truncated(
                    offset: position
                )
            }
            buffer.append(data)
        }
    }
}
