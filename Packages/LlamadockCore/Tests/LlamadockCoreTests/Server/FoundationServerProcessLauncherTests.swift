import Foundation
import Testing
@testable import LlamadockCore

@Suite("Foundation server process launcher")
struct FoundationServerProcessLauncherTests {
    @Test("streams output and termination from an absolute executable")
    func streamsOutputAndTermination() async throws {
        let launcher = FoundationServerProcessLauncher()
        let invocation = try ProcessInvocation(
            executableURL: URL(filePath: "/usr/bin/printf"),
            arguments: ["server output"]
        )

        let handle = try await launcher.launch(invocation)
        let stream = await handle.events()
        var events: [ManagedProcessEvent] = []
        for await event in stream {
            events.append(event)
        }

        #expect(
            events.contains {
                guard case .output(let source, let message, _) = $0 else {
                    return false
                }
                return source == .standardOutput && message == "server output"
            }
        )
        #expect(
            events.contains {
                guard case .terminated(let status) = $0 else {
                    return false
                }
                return status == 0
            }
        )
        #expect(!(await handle.isRunning()))
    }
}
