import Foundation
import Testing
@testable import LlamadockCore

@Suite("Model download profile factory")
struct ModelDownloadProfileFactoryTests {
    @Test("creates a profile from grouped imported artifacts")
    func createsProfileWithCompanions() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let job = completedJob()
        let imported = root.appending(
            path: job.destinationRelativeDirectory,
            directoryHint: .isDirectory
        )
        for file in job.files {
            let url = imported.appending(
                path: file.repositoryPath,
                directoryHint: .notDirectory
            )
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(repeating: 0, count: Int(file.expectedSize))
                .write(to: url)
        }
        let now = Date(timeIntervalSince1970: 123)

        let profile = try ModelDownloadProfileFactory()
            .makeProfile(
                for: job,
                modelsRoot: root,
                runtimeID: "runtime-id",
                now: now
            )

        #expect(profile.name == "Tiny Q4_0 Default")
        #expect(
            profile.model.mainPath.hasSuffix(
                "/weights/model-00001-of-00002.gguf"
            )
        )
        #expect(
            profile.model.mmprojPath?.hasSuffix(
                "/vision/mmproj-f16.gguf"
            ) == true
        )
        #expect(
            profile.model.draftPath?.hasSuffix(
                "/draft/model-draft.gguf"
            ) == true
        )
        #expect(profile.runtimeSelection.policy == .specific)
        #expect(profile.runtimeSelection.runtimeID == "runtime-id")
        #expect(profile.createdAt == now)
    }

    @Test("requires a completed job and imported primary file")
    func rejectsIncompleteInputs() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var job = completedJob()
        job.state = .verifying

        #expect(
            throws: ModelDownloadProfileFactoryError
                .jobNotCompleted(job.id)
        ) {
            _ = try ModelDownloadProfileFactory()
                .makeProfile(
                    for: job,
                    modelsRoot: root,
                    runtimeID: nil
                )
        }

        job.state = .completed
        #expect(
            throws: ModelDownloadProfileFactoryError
                .missingImportedFile(
                    "weights/model-00001-of-00002.gguf"
                )
        ) {
            _ = try ModelDownloadProfileFactory()
                .makeProfile(
                    for: job,
                    modelsRoot: root,
                    runtimeID: nil
                )
        }
    }

    private func completedJob() -> ModelDownloadJob {
        let now = Date(timeIntervalSince1970: 100)
        return ModelDownloadJob(
            id: UUID(),
            repositoryID: "owner/repo",
            revision: "main",
            displayName: "Tiny Q4_0",
            quantization: "Q4_0",
            destinationRelativeDirectory:
                "huggingface/owner/repo/main/tiny",
            files: [
                file(
                    artifactID: "main",
                    role: .main,
                    path: "weights/model-00002-of-00002.gguf"
                ),
                file(
                    artifactID: "main",
                    role: .main,
                    path: "weights/model-00001-of-00002.gguf"
                ),
                file(
                    artifactID: "mmproj",
                    role: .mmproj,
                    path: "vision/mmproj-f16.gguf"
                ),
                file(
                    artifactID: "draft",
                    role: .draft,
                    path: "draft/model-draft.gguf"
                ),
            ],
            state: .completed,
            error: nil,
            createdAt: now,
            updatedAt: now
        )
    }

    private func file(
        artifactID: String,
        role: HuggingFaceGGUFRole,
        path: String
    ) -> ModelDownloadFile {
        ModelDownloadFile(
            artifactID: artifactID,
            artifactDisplayName: artifactID,
            role: role,
            repositoryPath: path,
            expectedSize: 4,
            expectedSHA256: nil,
            receivedBytes: 4,
            isVerified: true
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "LlamadockProfileFactory-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }
}
