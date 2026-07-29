import Foundation
import Testing
@testable import LlamadockCore

@Suite("Hugging Face GGUF file catalog")
struct HuggingFaceFileCatalogTests {
    @Test("groups split models and classifies mmproj and draft companions")
    func groupsAndClassifies() throws {
        let files = [
            file("model-UD-Q4_K_M-00002-of-00002.gguf", size: 20),
            file("model-UD-Q4_K_M-00001-of-00002.gguf", size: 10),
            file("mmproj-model-f16.gguf", size: 5),
            file("model-draft-Q8_0.gguf", size: 7),
            file("README.md", size: 1),
            file("../escape.gguf", size: 1),
        ]

        let catalog = HuggingFaceFileCatalogBuilder()
            .makeCatalog(files: files)

        #expect(catalog.artifacts.count == 3)
        let main = try #require(
            catalog.artifacts.first { $0.role == .main }
        )
        #expect(main.quantization == "UD-Q4_K_M")
        #expect(main.files.map(\.split?.index) == [1, 2])
        #expect(main.totalSize == 30)
        #expect(main.isComplete)

        let mmproj = try #require(
            catalog.artifacts.first { $0.role == .mmproj }
        )
        #expect(mmproj.quantization == "f16")
        #expect(mmproj.files.count == 1)
        #expect(mmproj.isComplete)

        let draft = try #require(
            catalog.artifacts.first { $0.role == .draft }
        )
        #expect(draft.quantization == "Q8_0")
        #expect(draft.isComplete)
        #expect(catalog.ignoredPaths == ["../escape.gguf", "README.md"])
    }

    @Test("marks incomplete or inconsistent split groups unavailable")
    func marksIncompleteSplits() throws {
        let catalog = HuggingFaceFileCatalogBuilder().makeCatalog(
            files: [
                file("model-Q4_K_M-00001-of-00003.gguf", size: 10),
                file("model-Q4_K_M-00003-of-00003.gguf", size: 30),
                file("broken-Q8_0-00000-of-00001.gguf", size: 2),
            ]
        )

        #expect(catalog.artifacts.count == 2)
        #expect(catalog.artifacts.allSatisfy { !$0.isComplete })
        let artifact = try #require(
            catalog.artifacts.first {
                $0.quantization == "Q4_K_M"
            }
        )
        #expect(artifact.totalSize == 40)
    }

    @Test("saturates total size instead of overflowing")
    func saturatesSize() throws {
        let catalog = HuggingFaceFileCatalogBuilder().makeCatalog(
            files: [
                file("model-Q4_0-00001-of-00002.gguf", size: Int64.max),
                file("model-Q4_0-00002-of-00002.gguf", size: 1),
            ]
        )

        #expect(
            try #require(catalog.artifacts.first).totalSize
                == Int64.max
        )
    }

    private func file(
        _ path: String,
        size: Int64
    ) -> HuggingFaceRepositoryFile {
        HuggingFaceRepositoryFile(
            path: path,
            size: size,
            gitOID: nil,
            lfsOID: nil
        )
    }
}
