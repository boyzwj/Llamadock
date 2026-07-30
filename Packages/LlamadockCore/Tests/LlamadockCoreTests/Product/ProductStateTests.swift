import LlamadockCore
import Testing

@Suite("Product state")
struct ProductStateTests {
    @Test("navigation groups preserve the product workflow")
    func navigationGroups() {
        #expect(
            ProductDestination.destinations(in: .run)
                == [.overview, .service, .logs]
        )
        #expect(
            ProductDestination.destinations(in: .resources)
                == [.models, .downloads, .runtimes]
        )
        #expect(
            ProductNavigationGroup.allCases
                == [.run, .resources]
        )
    }

    @Test(
        "server states map to stable presentation kinds",
        arguments: [
            (ServerState.stopped, ServiceStatusKind.stopped),
            (ServerState.starting, ServiceStatusKind.starting),
            (ServerState.ready, ServiceStatusKind.ready),
            (
                ServerState.degraded(reason: "health"),
                ServiceStatusKind.degraded
            ),
            (
                ServerState.failed(reason: "launch"),
                ServiceStatusKind.failed
            ),
            (ServerState.stopping, ServiceStatusKind.stopping),
        ]
    )
    func statusMapping(
        state: ServerState,
        expected: ServiceStatusKind
    ) {
        #expect(ServiceStatusKind(state) == expected)
    }

    @Test("start requires one coherent runtime profile and model")
    func startRequirements() {
        #expect(makeState(hasRuntime: false).startBlocker == .missingRuntime)
        #expect(makeState(hasProfile: false).startBlocker == .missingProfile)
        #expect(makeState(modelIsAvailable: false).startBlocker == .missingModel)
        #expect(makeState().canStart)
    }

    @Test("running service exposes only safe controls")
    func runningControls() {
        let ready = makeState(serverState: .ready)
        #expect(!ready.canStart)
        #expect(ready.canStop)
        #expect(ready.canRestart)

        let busy = makeState(
            serverState: .ready,
            serverOperationInProgress: true
        )
        #expect(!busy.canStop)
        #expect(!busy.canRestart)
        #expect(busy.startBlocker == .serverBusy)
    }

    @Test("runtime changes wait for bootstrap and detection")
    func runtimeChangeGuards() {
        #expect(
            makeRuntimeState(isBootstrapping: true)
                .changeBlocker == .bootstrapping
        )
        #expect(
            makeRuntimeState(isRefreshing: true)
                .changeBlocker == .refreshing
        )
        #expect(
            makeRuntimeState(runtimeOperationInProgress: true)
                .changeBlocker == .runtimeOperation
        )
        #expect(
            makeRuntimeState(serverOperationInProgress: true)
                .changeBlocker == .serverOperation
        )
        #expect(
            makeRuntimeState(serverState: .ready)
                .changeBlocker == .serverRunning
        )
        #expect(makeRuntimeState().canChange)
    }

    private func makeState(
        serverState: ServerState = .stopped,
        hasRuntime: Bool = true,
        hasProfile: Bool = true,
        modelIsAvailable: Bool = true,
        serverOperationInProgress: Bool = false,
        runtimeOperationInProgress: Bool = false,
        modelOperationInProgress: Bool = false
    ) -> ServiceControlState {
        ServiceControlState(
            serverState: serverState,
            hasRuntime: hasRuntime,
            hasProfile: hasProfile,
            modelIsAvailable: modelIsAvailable,
            serverOperationInProgress:
                serverOperationInProgress,
            runtimeOperationInProgress:
                runtimeOperationInProgress,
            modelOperationInProgress:
                modelOperationInProgress
        )
    }

    private func makeRuntimeState(
        serverState: ServerState = .stopped,
        isBootstrapping: Bool = false,
        isRefreshing: Bool = false,
        runtimeOperationInProgress: Bool = false,
        serverOperationInProgress: Bool = false
    ) -> ManagedRuntimeControlState {
        ManagedRuntimeControlState(
            serverState: serverState,
            isBootstrapping: isBootstrapping,
            isRefreshing: isRefreshing,
            runtimeOperationInProgress:
                runtimeOperationInProgress,
            serverOperationInProgress:
                serverOperationInProgress
        )
    }
}
