import Foundation

public enum ProductNavigationGroup:
    String,
    CaseIterable,
    Equatable,
    Sendable
{
    case run
    case resources
}

public enum ProductDestination:
    String,
    CaseIterable,
    Equatable,
    Identifiable,
    Sendable
{
    case overview
    case logs
    case benchmark
    case models
    case downloads
    case runtimes
    case settings
    case about

    public var id: Self { self }

    public var group: ProductNavigationGroup {
        switch self {
        case .overview, .logs, .benchmark:
            .run
        case .models, .downloads, .runtimes, .settings, .about:
            .resources
        }
    }

    public static func destinations(
        in group: ProductNavigationGroup
    ) -> [Self] {
        allCases.filter { $0.group == group }
    }
}

public enum ServiceStatusKind:
    String,
    CaseIterable,
    Equatable,
    Sendable
{
    case stopped
    case starting
    case ready
    case degraded
    case failed
    case stopping

    public init(_ state: ServerState) {
        switch state {
        case .stopped:
            self = .stopped
        case .starting:
            self = .starting
        case .ready:
            self = .ready
        case .degraded:
            self = .degraded
        case .failed:
            self = .failed
        case .stopping:
            self = .stopping
        }
    }

    public var isReachable: Bool {
        self == .ready || self == .degraded
    }
}

public enum ServiceStartBlocker:
    Equatable,
    Sendable
{
    case serverBusy
    case runtimeBusy
    case modelBusy
    case missingRuntime
    case missingProfile
    case missingModel
    case alreadyRunning
}

public struct ServiceControlState:
    Equatable,
    Sendable
{
    public let status: ServiceStatusKind
    public let startBlocker: ServiceStartBlocker?
    public let canStop: Bool
    public let canRestart: Bool

    public var canStart: Bool {
        startBlocker == nil
    }

    public init(
        serverState: ServerState,
        hasRuntime: Bool,
        hasProfile: Bool,
        modelIsAvailable: Bool,
        serverOperationInProgress: Bool,
        runtimeOperationInProgress: Bool,
        modelOperationInProgress: Bool
    ) {
        status = ServiceStatusKind(serverState)

        let isRunning = switch serverState {
        case .starting, .ready, .degraded:
            true
        case .stopped, .failed, .stopping:
            false
        }
        let isStopping = status == .stopping

        if serverOperationInProgress || isStopping {
            startBlocker = .serverBusy
        } else if runtimeOperationInProgress {
            startBlocker = .runtimeBusy
        } else if modelOperationInProgress {
            startBlocker = .modelBusy
        } else if !hasRuntime {
            startBlocker = .missingRuntime
        } else if !hasProfile {
            startBlocker = .missingProfile
        } else if !modelIsAvailable {
            startBlocker = .missingModel
        } else if isRunning {
            startBlocker = .alreadyRunning
        } else {
            startBlocker = nil
        }

        canStop = isRunning && !serverOperationInProgress
        canRestart = canStop
            && !runtimeOperationInProgress
            && !modelOperationInProgress
    }
}

public enum ManagedRuntimeChangeBlocker:
    Equatable,
    Sendable
{
    case bootstrapping
    case refreshing
    case runtimeOperation
    case serverOperation
    case serverRunning
}

public struct ManagedRuntimeControlState:
    Equatable,
    Sendable
{
    public let changeBlocker: ManagedRuntimeChangeBlocker?

    public var canChange: Bool {
        changeBlocker == nil
    }

    public init(
        serverState: ServerState,
        isBootstrapping: Bool,
        isRefreshing: Bool,
        runtimeOperationInProgress: Bool,
        serverOperationInProgress: Bool
    ) {
        if isBootstrapping {
            changeBlocker = .bootstrapping
        } else if isRefreshing {
            changeBlocker = .refreshing
        } else if runtimeOperationInProgress {
            changeBlocker = .runtimeOperation
        } else if serverOperationInProgress {
            changeBlocker = .serverOperation
        } else {
            changeBlocker = switch serverState {
            case .stopped, .failed:
                nil
            case .starting, .ready, .degraded, .stopping:
                .serverRunning
            }
        }
    }
}
