import Foundation

public enum PackageScope: String, Sendable, Codable, CaseIterable {
    case user
    case project
}

public enum PackageResourceKind: String, Sendable, Codable, CaseIterable {
    case extensionResource = "extensions"
    case skill = "skills"
    case prompt = "prompts"
    case theme = "themes"
}

public struct PackageResource: Sendable, Hashable, Codable, Identifiable {
    public var id: String { "\(scope.rawValue):\(kind.rawValue):\(path)" }

    public let source: String
    public let scope: PackageScope
    public let kind: PackageResourceKind
    public let path: String
    public let enabled: Bool
    public let origin: String
    public let diagnostic: String?

    public init(
        source: String,
        scope: PackageScope,
        kind: PackageResourceKind,
        path: String,
        enabled: Bool,
        origin: String,
        diagnostic: String? = nil
    ) {
        self.source = source
        self.scope = scope
        self.kind = kind
        self.path = path
        self.enabled = enabled
        self.origin = origin
        self.diagnostic = diagnostic
    }
}

public enum PackageOperation: Sendable, Hashable {
    case install(source: String, scope: PackageScope)
    case remove(source: String, scope: PackageScope)
    case update(source: String?)
    case updateAllPackages
    case refreshModels
}

public enum PackageOperationEvent: Sendable, Hashable {
    /// Live output was dropped to preserve the event-stream memory bound. The
    /// final `PackageOperationResult` remains the authoritative bounded tail.
    case outputGap
    case started(PackageOperation)
    case output(String, isError: Bool)
    case completed(PackageOperation, status: Int32)
}

public struct PackageOperationResult: Sendable, Hashable {
    public let operation: PackageOperation
    public let status: Int32
    public let output: String
    public let errorOutput: String

    public var succeeded: Bool { status == 0 }
}
