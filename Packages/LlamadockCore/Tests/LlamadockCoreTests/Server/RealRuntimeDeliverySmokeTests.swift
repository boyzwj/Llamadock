import Foundation
import Testing
@testable import LlamadockCore

@Suite("Real runtime delivery smoke")
struct RealRuntimeDeliverySmokeTests {
    @Test("starts, reaches health readiness, and stops an installed runtime")
    func startsAndStopsInstalledRuntime() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard
            let serverPath = environment["LLAMADOCK_SMOKE_SERVER"],
            let modelPath = environment["LLAMADOCK_SMOKE_MODEL"],
            let portValue = environment["LLAMADOCK_SMOKE_PORT"],
            let port = UInt16(portValue)
        else {
            return
        }

        let serverURL = URL(
            filePath: serverPath,
            directoryHint: .notDirectory
        )
        let helpResult = try await FoundationProcessRunner().run(
            ProcessInvocation(
                executableURL: serverURL,
                arguments: ["--help"]
            ),
            timeout: .seconds(30)
        )
        let capabilities = RuntimeCapabilitiesParser().parse(
            [
                helpResult.standardOutput,
                helpResult.standardError,
            ]
                .joined(separator: "\n")
        )
        let runtime = RuntimeInstallation(
            id: "real-delivery-smoke",
            source: .custom,
            llamaURL: nil,
            serverURL: serverURL,
            versionOutput: "real delivery smoke",
            capabilities: capabilities
        )
        let profile = LaunchProfile(
            name: "Real Delivery Smoke",
            model: ModelPaths(mainPath: modelPath),
            runtimeSelection: RuntimeSelection(
                policy: .specific,
                runtimeID: runtime.id
            ),
            server: ServerOptions(
                host: "127.0.0.1",
                port: port
            )
        )
        let invocation = try ServerInvocationBuilder()
            .makeServerInvocation(
                profile: profile,
                runtime: runtime
            )
        let ownershipDirectory = FileManager.default.temporaryDirectory
            .appending(
                path: "llamadock-real-ownership-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: ownershipDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(
                at: ownershipDirectory
            )
        }
        let ownershipStore = JSONServerOwnershipStore(
            fileURL: ownershipDirectory.appending(
                path: "ownership.json",
                directoryHint: .notDirectory
            )
        )
        let controller = ServerProcessController(
            ownershipStore: ownershipStore
        )

        do {
            try await controller.start(
                profileID: profile.id,
                runtimeID: runtime.id,
                invocation: invocation,
                host: profile.server.host,
                port: profile.server.port,
                readinessTimeout: .seconds(30)
            )

            let ready = await controller.snapshot()
            #expect(ready.state == .ready)
            #expect(ready.run?.profileID == profile.id)
            #expect(ready.run?.command == invocation)
            let ownership = try await ownershipStore.load()
            #expect(
                ownership?.processIdentifier
                    == ready.run?.processIdentifier
            )
            #expect(
                ownership?.executableURL
                    == invocation.executableURL
            )
            #expect(
                ready.logs.contains {
                    $0.message.localizedCaseInsensitiveContains("server")
                }
            )
        } catch {
            await controller.stop()
            throw error
        }

        await controller.stop()
        let stopped = await controller.snapshot()
        #expect(stopped.state == .stopped)
        #expect(stopped.run == nil)
        #expect(try await ownershipStore.load() == nil)
    }
}
