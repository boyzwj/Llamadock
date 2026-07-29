import Foundation
import Testing
@testable import LlamadockCore

@Suite("GGUF metadata reader")
struct GGUFMetadataReaderTests {
    @Test("reads model metadata and tensor descriptors without tensor data")
    func readsMetadataAndTensorDescriptors() throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let fixture = GGUFFixture(
            metadata: [
                ("general.architecture", .string("llama")),
                ("general.type", .string("model")),
                ("general.name", .string("Tiny Stories")),
                ("general.size_label", .string("15M")),
                ("general.file_type", .uint32(2)),
                ("general.alignment", .uint32(32)),
                ("llama.context_length", .uint64(2_048)),
                (
                    "tokenizer.chat_template",
                    .string("{{ messages }}")
                ),
                (
                    "tokenizer.ggml.tokens",
                    .stringArray(["hello", "world"])
                ),
                (
                    "test.nested",
                    .nestedStringArrays([["a"], ["b", "c"]])
                ),
                ("split.no", .uint16(0)),
                ("split.count", .uint16(2)),
                ("split.tensors.count", .int32(5)),
            ],
            tensors: [
                TensorFixture(
                    name: "token_embd.weight",
                    dimensions: [3, 4],
                    type: 0,
                    offset: 0
                ),
                TensorFixture(
                    name: "output.weight",
                    dimensions: [4, 5],
                    type: 2,
                    offset: 32
                ),
            ]
        )
        try fixture.data().write(to: url)

        let metadata = try GGUFMetadataReader().read(from: url)

        #expect(metadata.formatVersion == 3)
        #expect(metadata.metadataCount == 13)
        #expect(metadata.tensorCount == 2)
        #expect(metadata.parameterCount == 32)
        #expect(metadata.name == "Tiny Stories")
        #expect(metadata.architecture == "llama")
        #expect(metadata.modelKind == "model")
        #expect(metadata.sizeLabel == "15M")
        #expect(metadata.fileType == 2)
        #expect(metadata.quantization == "Q4_0")
        #expect(metadata.contextLength == 2_048)
        #expect(metadata.hasChatTemplate)
        #expect(
            metadata.shard
                == GGUFShardMetadata(
                    zeroBasedIndex: 0,
                    count: 2,
                    totalTensorCount: 5
                )
        )
        #expect(metadata.headerByteCount < metadata.fileSize)
    }

    @Test("detects big-endian GGUF and modern hyphenated architecture keys")
    func readsBigEndianMetadata() throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let fixture = GGUFFixture(
            byteOrder: .big,
            metadata: [
                ("general.architecture", .string("gpt-oss")),
                ("general.file_type", .uint32(38)),
                ("gpt-oss.context_length", .uint32(131_072)),
            ],
            tensors: [
                TensorFixture(
                    name: "weight",
                    dimensions: [7],
                    type: 39,
                    offset: 0
                )
            ]
        )
        try fixture.data().write(to: url)

        let metadata = try GGUFMetadataReader().read(from: url)

        #expect(metadata.formatVersion == 3)
        #expect(metadata.architecture == "gpt-oss")
        #expect(metadata.contextLength == 131_072)
        #expect(metadata.quantization == "MXFP4_MOE")
        #expect(metadata.parameterCount == 7)
    }

    @Test("rejects invalid magic before parsing counts")
    func rejectsInvalidMagic() throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("NOPE".utf8).write(to: url)

        #expect(throws: GGUFMetadataError.invalidMagic) {
            try GGUFMetadataReader().read(from: url)
        }
    }

    @Test("bounds untrusted metadata counts")
    func boundsMetadataCounts() throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var data = Data("GGUF".utf8)
        data.appendInteger(UInt32(3), byteOrder: .little)
        data.appendInteger(UInt64(0), byteOrder: .little)
        data.appendInteger(UInt64(11), byteOrder: .little)
        try data.write(to: url)
        let reader = GGUFMetadataReader(
            limits: GGUFReadLimits(
                maximumMetadataEntries: 10
            )
        )

        #expect(
            throws: GGUFMetadataError.countExceedsLimit(
                field: "metadata_kv_count",
                value: 11,
                maximum: 10
            )
        ) {
            try reader.read(from: url)
        }
    }

    @Test("reports a truncated variable-length metadata value")
    func reportsTruncation() throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var data = Data("GGUF".utf8)
        data.appendInteger(UInt32(3), byteOrder: .little)
        data.appendInteger(UInt64(0), byteOrder: .little)
        data.appendInteger(UInt64(1), byteOrder: .little)
        data.appendString("general.architecture", byteOrder: .little)
        data.appendInteger(UInt32(8), byteOrder: .little)
        data.appendInteger(UInt64(20), byteOrder: .little)
        data.append(Data("short".utf8))
        try data.write(to: url)

        #expect(throws: GGUFMetadataError.self) {
            try GGUFMetadataReader().read(from: url)
        }
    }

    @Test("rejects parameter count multiplication overflow")
    func rejectsParameterOverflow() throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let fixture = GGUFFixture(
            metadata: [
                ("general.architecture", .string("llama"))
            ],
            tensors: [
                TensorFixture(
                    name: "weight",
                    dimensions: [UInt64.max, 2],
                    type: 0,
                    offset: 0
                )
            ]
        )
        try fixture.data().write(to: url)

        #expect(
            throws: GGUFMetadataError.integerOverflow(
                field: "tensor weight element count"
            )
        ) {
            try GGUFMetadataReader().read(from: url)
        }
    }

    @Test("rejects tensor offsets beyond the file")
    func rejectsTensorOffsetOutsideFile() throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let fixture = GGUFFixture(
            metadata: [
                ("general.architecture", .string("llama"))
            ],
            tensors: [
                TensorFixture(
                    name: "weight",
                    dimensions: [4],
                    type: 0,
                    offset: 96
                )
            ]
        )
        try fixture.data().write(to: url)

        #expect(
            throws: GGUFMetadataError.tensorOffsetOutsideFile(
                name: "weight",
                offset: 96
            )
        ) {
            try GGUFMetadataReader().read(from: url)
        }
    }

    private func makeTemporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "LlamadockGGUF-\(UUID().uuidString).gguf",
            directoryHint: .notDirectory
        )
    }
}

private struct TensorFixture {
    let name: String
    let dimensions: [UInt64]
    let type: UInt32
    let offset: UInt64
}

private struct GGUFFixture {
    var byteOrder: FixtureByteOrder = .little
    var metadata: [(String, FixtureValue)]
    var tensors: [TensorFixture]

    func data() -> Data {
        var result = Data("GGUF".utf8)
        result.appendInteger(UInt32(3), byteOrder: byteOrder)
        result.appendInteger(
            UInt64(tensors.count),
            byteOrder: byteOrder
        )
        result.appendInteger(
            UInt64(metadata.count),
            byteOrder: byteOrder
        )

        for (key, value) in metadata {
            result.appendString(key, byteOrder: byteOrder)
            result.appendInteger(
                value.typeCode,
                byteOrder: byteOrder
            )
            result.append(value.encoded(byteOrder: byteOrder))
        }

        for tensor in tensors {
            result.appendString(
                tensor.name,
                byteOrder: byteOrder
            )
            result.appendInteger(
                UInt32(tensor.dimensions.count),
                byteOrder: byteOrder
            )
            for dimension in tensor.dimensions {
                result.appendInteger(
                    dimension,
                    byteOrder: byteOrder
                )
            }
            result.appendInteger(
                tensor.type,
                byteOrder: byteOrder
            )
            result.appendInteger(
                tensor.offset,
                byteOrder: byteOrder
            )
        }

        let remainder = result.count % 32
        if remainder != 0 {
            result.append(
                Data(repeating: 0, count: 32 - remainder)
            )
        }
        result.append(Data(repeating: 0, count: 64))
        return result
    }
}

private indirect enum FixtureValue {
    case uint16(UInt16)
    case uint32(UInt32)
    case int32(Int32)
    case uint64(UInt64)
    case string(String)
    case stringArray([String])
    case nestedStringArrays([[String]])

    var typeCode: UInt32 {
        switch self {
        case .uint16:
            2
        case .uint32:
            4
        case .int32:
            5
        case .string:
            8
        case .stringArray, .nestedStringArrays:
            9
        case .uint64:
            10
        }
    }

    func encoded(
        byteOrder: FixtureByteOrder
    ) -> Data {
        var data = Data()
        switch self {
        case .uint16(let value):
            data.appendInteger(value, byteOrder: byteOrder)
        case .uint32(let value):
            data.appendInteger(value, byteOrder: byteOrder)
        case .int32(let value):
            data.appendInteger(
                UInt32(bitPattern: value),
                byteOrder: byteOrder
            )
        case .uint64(let value):
            data.appendInteger(value, byteOrder: byteOrder)
        case .string(let value):
            data.appendString(value, byteOrder: byteOrder)
        case .stringArray(let values):
            data.appendInteger(UInt32(8), byteOrder: byteOrder)
            data.appendInteger(
                UInt64(values.count),
                byteOrder: byteOrder
            )
            for value in values {
                data.appendString(value, byteOrder: byteOrder)
            }
        case .nestedStringArrays(let arrays):
            data.appendInteger(UInt32(9), byteOrder: byteOrder)
            data.appendInteger(
                UInt64(arrays.count),
                byteOrder: byteOrder
            )
            for values in arrays {
                data.appendInteger(
                    UInt32(8),
                    byteOrder: byteOrder
                )
                data.appendInteger(
                    UInt64(values.count),
                    byteOrder: byteOrder
                )
                for value in values {
                    data.appendString(
                        value,
                        byteOrder: byteOrder
                    )
                }
            }
        }
        return data
    }
}

private enum FixtureByteOrder {
    case little
    case big
}

private extension Data {
    mutating func appendInteger<T: FixedWidthInteger>(
        _ value: T,
        byteOrder: FixtureByteOrder
    ) {
        let bytes: [UInt8] = (0..<MemoryLayout<T>.size).map {
            let shift: Int
            switch byteOrder {
            case .little:
                shift = $0 * 8
            case .big:
                shift = (MemoryLayout<T>.size - 1 - $0) * 8
            }
            return UInt8(
                truncatingIfNeeded: value >> T(shift)
            )
        }
        append(contentsOf: bytes)
    }

    mutating func appendString(
        _ value: String,
        byteOrder: FixtureByteOrder
    ) {
        let encoded = Data(value.utf8)
        appendInteger(
            UInt64(encoded.count),
            byteOrder: byteOrder
        )
        append(encoded)
    }
}
