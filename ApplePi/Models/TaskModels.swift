import Foundation

public struct PiTaskID: RawRepresentable, Sendable, Hashable, Codable, Identifiable {
    public let rawValue: UUID
    public var id: UUID { rawValue }

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct TaskRuntimeState: Sendable, Hashable, Codable {
    public enum Phase: String, Sendable, Codable {
        case stopped, starting, ready, generating, awaitingInput, queued, failed
    }

    public let phase: Phase
    public let detail: String?

    public init(_ phase: Phase, detail: String? = nil) {
        self.phase = phase
        self.detail = detail
    }

    public static let stopped = Self(.stopped)
    public static let starting = Self(.starting)
    public static let ready = Self(.ready)
    public static let generating = Self(.generating)
    public static let awaitingInput = Self(.awaitingInput)
    public static let queued = Self(.queued)
    public static func failed(_ message: String) -> Self { Self(.failed, detail: message) }
}

public struct PiTaskLaunchConfiguration: Sendable, Hashable {
    public let id: PiTaskID
    public let workingDirectory: URL
    public let sessionPath: URL?
    public let projectTrusted: Bool
    public let hasUserExtensions: Bool
    public let runtime: PiRuntimeDescriptor
    public let environment: [String: String]
    public let bridgeURL: URL?

    public init(
        id: PiTaskID = PiTaskID(),
        workingDirectory: URL,
        sessionPath: URL? = nil,
        projectTrusted: Bool,
        hasUserExtensions: Bool,
        runtime: PiRuntimeDescriptor,
        environment: [String: String],
        bridgeURL: URL?
    ) {
        self.id = id
        self.workingDirectory = workingDirectory
        self.sessionPath = sessionPath
        self.projectTrusted = projectTrusted
        self.hasUserExtensions = hasUserExtensions
        self.runtime = runtime
        self.environment = environment
        self.bridgeURL = bridgeURL
    }
}

public struct PiTaskSnapshot: Sendable, Hashable, Identifiable {
    public let id: PiTaskID
    public let workingDirectory: URL
    public let sessionPath: URL?
    public let state: TaskRuntimeState
    public let pendingTurnCount: Int
    public let hasUserExtensions: Bool
}

public enum PiTaskCoordinatorEvent: Sendable, Hashable {
    /// One or more coordinator events were discarded under backpressure.
    /// Consumers should request current snapshots and refresh durable session
    /// content before applying subsequent incremental RPC events.
    case streamGap
    case changed(PiTaskSnapshot)
    case rpc(PiTaskID, PiRPCEvent)
    case removed(PiTaskID)
}
