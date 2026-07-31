import Foundation
import Testing
@testable import LlamadockCore

@Suite("JSON model download store")
struct JSONModelDownloadStoreTests {
    @Test("persists readable jobs atomically")
    func persistsJobs() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appending(path: "state.json")
        let store = JSONModelDownloadStore(fileURL: fileURL)
        let job = makeJob()

        try await store.saveJobs([job])

        #expect(try await store.loadJobs() == [job])
        let object = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: fileURL)
            ) as? [String: Any]
        )
        #expect(object["schemaVersion"] as? Int == 1)
        let serialized = String(
            decoding: try Data(contentsOf: fileURL),
            as: UTF8.self
        )
        #expect(!serialized.localizedCaseInsensitiveContains("token"))
        #expect(!serialized.localizedCaseInsensitiveContains("authorization"))
    }

    @Test("rejects unsafe paths and invalid byte ranges")
    func rejectsInvalidJobs() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONModelDownloadStore(
            fileURL: root.appending(path: "state.json")
        )
        var invalidFile = makeJob()
        invalidFile.files[0].receivedBytes = 4

        await #expect(throws: ModelDownloadStoreError.self) {
            try await store.saveJobs([invalidFile])
        }

        let unsafe = makeJob(
            destinationRelativeDirectory: "../escape"
        )
        await #expect(throws: ModelDownloadStoreError.self) {
            try await store.saveJobs([unsafe])
        }
    }

    @Test("restores legacy jobs without a source as Hugging Face")
    func restoresLegacySourceDefault() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appending(path: "state.json")
        let store = JSONModelDownloadStore(fileURL: fileURL)
        let legacyJob = makeJob()
        try await store.saveJobs([legacyJob])

        var object = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: fileURL)
            ) as? [String: Any]
        )
        var jobs = try #require(
            object["jobs"] as? [[String: Any]]
        )
        jobs[0].removeValue(forKey: "source")
        object["jobs"] = jobs
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ).write(to: fileURL)

        let restored = try #require(
            try await store.loadJobs().first
        )
        #expect(restored.source == .huggingFace)
    }

    @Test("round-trips the ModelScope source")
    func roundTripsModelScopeSource() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appending(path: "state.json")
        let store = JSONModelDownloadStore(fileURL: fileURL)
        let job = makeJob(source: .modelScope)

        try await store.saveJobs([job])

        let restored = try #require(
            try await store.loadJobs().first
        )
        #expect(restored.source == .modelScope)
    }

    private func makeJob(
        source: ModelHubSource = .huggingFace,
        destinationRelativeDirectory: String =
            "huggingface/owner/repo/main/model"
    ) -> ModelDownloadJob {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        return ModelDownloadJob(
            id: UUID(
                uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
            )!,
            source: source,
            repositoryID: "owner/repo",
            revision: "main",
            displayName: "model-Q4_K_M",
            quantization: "Q4_K_M",
            destinationRelativeDirectory:
                destinationRelativeDirectory,
            files: [
                ModelDownloadFile(
                    artifactID: "main:model.gguf",
                    artifactDisplayName: "model.gguf",
                    role: .main,
                    repositoryPath: "model.gguf",
                    expectedSize: 3,
                    expectedSHA256: String(
                        repeating: "a",
                        count: 64
                    )
                ),
            ],
            state: .paused,
            error: nil,
            createdAt: now,
            updatedAt: now
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "LlamadockDownloadStoreTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }
}
