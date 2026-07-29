import Foundation
import Testing
@testable import LlamadockCore

@Suite("Real Hugging Face Hub smoke")
struct RealHuggingFaceHubSmokeTests {
    @Test("searches and catalogs a public GGUF repository")
    func searchesAndCatalogsPublicRepository() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard
            let query = environment["LLAMADOCK_HF_SMOKE_QUERY"],
            let repositoryID =
                environment["LLAMADOCK_HF_SMOKE_REPOSITORY"]
        else {
            return
        }

        let client = HuggingFaceHubClient()
        let repositories = try await client.searchModels(
            query: query,
            limit: 10,
            token: nil
        )
        #expect(
            repositories.contains {
                $0.id == repositoryID
            }
        )

        let reference = try HuggingFaceReferenceParser()
            .parse(repositoryID)
        let files = try await client.repositoryFiles(
            reference: reference,
            token: nil
        )
        let catalog = HuggingFaceFileCatalogBuilder()
            .makeCatalog(files: files)
        let mainArtifacts = catalog.artifacts.filter {
            $0.role == .main && $0.isComplete
        }
        #expect(!mainArtifacts.isEmpty)

        let firstFile = try #require(
            mainArtifacts.first?.files.first
        )
        let resolveURL = try client.resolveURL(
            reference: reference,
            filePath: firstFile.repositoryFile.path
        )
        #expect(resolveURL.host == "huggingface.co")
        #expect(
            resolveURL.path.contains(
                "/\(repositoryID)/resolve/main/"
            )
        )
    }
}
