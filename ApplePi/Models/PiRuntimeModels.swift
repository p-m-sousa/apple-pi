import Foundation

public struct SemanticVersion: Sendable, Hashable, Codable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: String?

    public init(major: Int, minor: Int, patch: Int, prerelease: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    public init?(_ text: String) {
        let pattern = #"(?<![0-9])([0-9]+)\.([0-9]+)\.([0-9]+)(?:-([0-9A-Za-z.-]+))?"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ),
              let majorRange = Range(match.range(at: 1), in: text),
              let minorRange = Range(match.range(at: 2), in: text),
              let patchRange = Range(match.range(at: 3), in: text),
              let major = Int(text[majorRange]),
              let minor = Int(text[minorRange]),
              let patch = Int(text[patchRange]) else {
            return nil
        }

        let prerelease: String?
        if match.range(at: 4).location != NSNotFound,
           let prereleaseRange = Range(match.range(at: 4), in: text) {
            prerelease = String(text[prereleaseRange])
        } else {
            prerelease = nil
        }
        self.init(major: major, minor: minor, patch: patch, prerelease: prerelease)
    }

    public var description: String {
        let base = "\(major).\(minor).\(patch)"
        return prerelease.map { "\(base)-\($0)" } ?? base
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let left = [lhs.major, lhs.minor, lhs.patch]
        let right = [rhs.major, rhs.minor, rhs.patch]
        if left != right { return left.lexicographicallyPrecedes(right) }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return false
        case (nil, _): return false
        case (_, nil): return true
        case let (.some(left), .some(right)): return left < right
        }
    }
}

public struct PiRuntimeVersionRange: Sendable, Hashable, Codable {
    public let minimum: SemanticVersion
    public let maximumExclusive: SemanticVersion

    public init(minimum: SemanticVersion, maximumExclusive: SemanticVersion) {
        self.minimum = minimum
        self.maximumExclusive = maximumExclusive
    }

    public func contains(_ version: SemanticVersion) -> Bool {
        version >= minimum && version < maximumExclusive
    }

    public static let nativeV1 = PiRuntimeVersionRange(
        minimum: SemanticVersion(major: 0, minor: 84, patch: 2),
        maximumExclusive: SemanticVersion(major: 0, minor: 85, patch: 0)
    )
}

public enum PiRuntimeSource: String, Sendable, Codable, CaseIterable {
    case savedExecutable
    case loginShellPath
    case commonLocation
}

public enum PiRuntimeCompatibility: String, Sendable, Codable {
    case native
    case advancedOverride
    case terminalOnly
    case incompatible
}

public struct PiRuntimeCapabilities: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let rpc = Self(rawValue: 1 << 0)
    public static let extensionUI = Self(rawValue: 1 << 1)
    public static let sessionTree = Self(rawValue: 1 << 2)
    public static let imageInput = Self(rawValue: 1 << 3)
    public static let packageManagement = Self(rawValue: 1 << 4)
    public static let explicitExtensions = Self(rawValue: 1 << 5)
    public static let projectTrust = Self(rawValue: 1 << 6)
    public static let bridgeV1 = Self(rawValue: 1 << 7)

    public static let nativeV1Required: Self = [
        .rpc, .extensionUI, .sessionTree, .imageInput,
        .packageManagement, .explicitExtensions, .projectTrust,
    ]
}

public struct PiRuntimeDescriptor: Sendable, Hashable, Codable, Identifiable {
    public var id: String { executable.path }

    public let source: PiRuntimeSource
    public let version: SemanticVersion
    public let executable: URL
    public let compatibility: PiRuntimeCompatibility
    public let capabilities: PiRuntimeCapabilities
    public let diagnostic: String?

    public init(
        source: PiRuntimeSource,
        version: SemanticVersion,
        executable: URL,
        compatibility: PiRuntimeCompatibility,
        capabilities: PiRuntimeCapabilities,
        diagnostic: String? = nil
    ) {
        self.source = source
        self.version = version
        self.executable = executable
        self.compatibility = compatibility
        self.capabilities = capabilities
        self.diagnostic = diagnostic
    }

    public var supportsNativeTasks: Bool {
        switch compatibility {
        case .native:
            capabilities.contains(.rpc)
        case .advancedOverride:
            capabilities.contains([.rpc, .bridgeV1])
        case .terminalOnly, .incompatible:
            false
        }
    }
}

public struct PiRuntimeResolution: Sendable {
    public let selected: PiRuntimeDescriptor?
    public let candidates: [PiRuntimeDescriptor]
    public let environment: [String: String]

    public init(
        selected: PiRuntimeDescriptor?,
        candidates: [PiRuntimeDescriptor],
        environment: [String: String]
    ) {
        self.selected = selected
        self.candidates = candidates
        self.environment = environment
    }
}
