import Foundation
import Testing
@testable import LlamadockCore

@Suite("Process boundary")
struct ProcessBoundaryTests {
    @Test("requires an absolute executable file URL")
    func requiresAbsoluteExecutableURL() {
        let relativeURL = URL(string: "llama-server")!

        #expect(
            throws: ProcessInvocationError.executableMustBeAbsolute(relativeURL)
        ) {
            _ = try ProcessInvocation(
                executableURL: relativeURL,
                arguments: ["--version"]
            )
        }
    }

    @Test("preserves arguments as tokens")
    func preservesArgumentTokens() throws {
        let executableURL = URL(filePath: "/opt/homebrew/bin/llama-server")
        let invocation = try ProcessInvocation(
            executableURL: executableURL,
            arguments: ["--model", "/Models/My Model.gguf", "--host", "127.0.0.1"]
        )

        #expect(invocation.executableURL == executableURL)
        #expect(
            invocation.arguments
                == ["--model", "/Models/My Model.gguf", "--host", "127.0.0.1"]
        )
        #expect(invocation.environment.isEmpty)
    }
}
