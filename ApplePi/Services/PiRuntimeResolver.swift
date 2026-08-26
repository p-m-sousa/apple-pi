import Foundation

public actor PiRuntimeResolver {
    public struct Configuration: Sendable {
        public let supportedVersions: PiRuntimeVersionRange
        public let savedExecutable: URL?
        public let allowAdvancedOverride: Bool
        public let commonExecutableURLs: [URL]
        public let bridgeURL: URL?

        public init(
            supportedVersions: PiRuntimeVersionRange = .nativeV1,
            savedExecutable: URL? = nil,
            allowAdvancedOverride: Bool = false,
            commonExecutableURLs: [URL]? = nil,
            bridgeURL: URL? = PiRuntimeResolver.defaultBridgeURL()
        ) {
            self.supportedVersions = supportedVersions
            self.savedExecutable = savedExecutable
            self.allowAdvancedOverride = allowAdvancedOverride
            self.commonExecutableURLs = commonExecutableURLs ?? PiRuntimeResolver.defaultCommonLocations()
            self.bridgeURL = bridgeURL
        }
    }

    private struct Candidate: Sendable {
        let url: URL
        let source: PiRuntimeSource
    }

    private let configuration: Configuration
    private let environmentImporter: LoginShellEnvironmentImporter

    public init(
        configuration: Configuration = .init(),
        environmentImporter: LoginShellEnvironmentImporter = .init()
    ) {
        self.configuration = configuration
        self.environmentImporter = environmentImporter
    }

    public func resolve() async -> PiRuntimeResolution {
        let environment: [String: String]
        do {
            environment = try await environmentImporter.environment()
        } catch {
            // A broken shell profile must not prevent use of a saved or common-location Pi.
            environment = ProcessInfo.processInfo.environment
        }

        var rawCandidates: [Candidate] = []
        if let saved = configuration.savedExecutable {
            rawCandidates.append(Candidate(url: saved, source: .savedExecutable))
        }
        rawCandidates.append(contentsOf: pathCandidates(environment: environment))
        rawCandidates.append(contentsOf: configuration.commonExecutableURLs.map {
            Candidate(url: $0, source: .commonLocation)
        })

        var seen = Set<String>()
        var candidates: [Candidate] = []
        for candidate in rawCandidates {
            let normalized = candidate.url.standardizedFileURL.resolvingSymlinksInPath()
            guard seen.insert(normalized.path).inserted else { continue }
            guard FileManager.default.isExecutableFile(atPath: candidate.url.path) else { continue }
            candidates.append(candidate)
        }

        // Version/help probes are independent subprocesses. Keep two in flight
        // to reduce startup latency without creating a burst proportional to a
        // user's PATH, then restore discovery priority before selecting Pi.
        var orderedDescriptors = Array<PiRuntimeDescriptor?>(repeating: nil, count: candidates.count)
        await withTaskGroup(of: (Int, PiRuntimeDescriptor).self) { group in
            var nextCandidate = 0
            let initialCount = min(2, candidates.count)
            for _ in 0..<initialCount {
                let index = nextCandidate
                nextCandidate += 1
                let candidate = candidates[index]
                group.addTask { [self] in
                    (index, await probe(candidate, environment: environment))
                }
            }
            while let (index, descriptor) = await group.next() {
                orderedDescriptors[index] = descriptor
                if nextCandidate < candidates.count {
                    let nextIndex = nextCandidate
                    nextCandidate += 1
                    let candidate = candidates[nextIndex]
                    group.addTask { [self] in
                        (nextIndex, await probe(candidate, environment: environment))
                    }
                }
            }
        }
        let descriptors = orderedDescriptors.compactMap { $0 }

        let selected = descriptors.first(where: \.supportsNativeTasks)
            ?? descriptors.first(where: { $0.compatibility == .terminalOnly })

        return PiRuntimeResolution(selected: selected, candidates: descriptors, environment: environment)
    }

    private func pathCandidates(environment: [String: String]) -> [Candidate] {
        guard let path = environment["PATH"] else { return [] }
        return path.split(separator: ":", omittingEmptySubsequences: true).map {
            Candidate(
                url: URL(filePath: String($0), directoryHint: .isDirectory).appending(path: "pi"),
                source: .loginShellPath
            )
        }
    }

    private func probe(_ candidate: Candidate, environment: [String: String]) async -> PiRuntimeDescriptor {
        let unknownVersion = SemanticVersion(major: 0, minor: 0, patch: 0)
        let probeDirectory = FileManager.default.temporaryDirectory
            .appending(path: "ApplePiRuntimeProbe-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: probeDirectory, withIntermediateDirectories: true)
        } catch {
            return PiRuntimeDescriptor(
                source: candidate.source,
                version: unknownVersion,
                executable: candidate.url,
                compatibility: .incompatible,
                capabilities: [],
                diagnostic: "ApplePi could not create an isolated runtime probe directory."
            )
        }
        defer { try? FileManager.default.removeItem(at: probeDirectory) }
        var probeEnvironment = environment
        // Capability probes must never acquire locks in, mutate settings under,
        // or create sessions inside the user's real Pi directory.
        probeEnvironment["PI_CODING_AGENT_DIR"] = probeDirectory.path

        let versionResult: CapturedProcessResult
        do {
            versionResult = try await ProcessCapture.run(
                executable: candidate.url,
                arguments: ["--version"],
                environment: probeEnvironment,
                currentDirectory: probeDirectory,
                timeout: 3,
                maximumOutputBytes: 64 * 1_024
            )
        } catch {
            return PiRuntimeDescriptor(
                source: candidate.source,
                version: unknownVersion,
                executable: candidate.url,
                compatibility: .incompatible,
                capabilities: [],
                diagnostic: error.localizedDescription
            )
        }

        guard versionResult.status == 0,
              let version = SemanticVersion(versionResult.stdoutString) else {
            let message = versionResult.stderrString.isEmpty
                ? "Pi did not return a semantic version."
                : DiagnosticsRedactor.redact(versionResult.stderrString)
            return PiRuntimeDescriptor(
                source: candidate.source,
                version: unknownVersion,
                executable: candidate.url,
                compatibility: .incompatible,
                capabilities: [],
                diagnostic: message
            )
        }

        var capabilities: PiRuntimeCapabilities = []
        do {
            let help = try await ProcessCapture.run(
                executable: candidate.url,
                arguments: ["--help"],
                environment: probeEnvironment,
                currentDirectory: probeDirectory,
                timeout: 4,
                maximumOutputBytes: 512 * 1_024
            ).stdoutString
            if help.contains("--mode <mode>") && help.contains("rpc") { capabilities.insert(.rpc) }
            if help.contains("--extension") { capabilities.insert(.explicitExtensions) }
            if help.contains("--approve") && help.contains("--no-approve") { capabilities.insert(.projectTrust) }
            if help.contains("pi install") && help.contains("pi remove") { capabilities.insert(.packageManagement) }
        } catch {
            // Versioned Pi remains usable in terminal mode even if help probing fails.
        }

        if configuration.supportedVersions.contains(version), capabilities.contains(.rpc) {
            capabilities.formUnion([.extensionUI, .sessionTree, .imageInput])
            if configuration.bridgeURL != nil { capabilities.insert(.bridgeV1) }
        } else if configuration.allowAdvancedOverride,
                  capabilities.contains([.rpc, .explicitExtensions]),
                  await probeRPCAndBridge(
                      candidate,
                      environment: probeEnvironment,
                      workingDirectory: probeDirectory
                  ) {
            capabilities.formUnion([.extensionUI, .sessionTree, .imageInput, .bridgeV1])
        }

        let compatibility: PiRuntimeCompatibility
        let diagnostic: String?
        if configuration.supportedVersions.contains(version),
           capabilities.isSuperset(of: .nativeV1Required) {
            compatibility = .native
            diagnostic = nil
        } else if configuration.allowAdvancedOverride,
                  capabilities.contains(.bridgeV1),
                  capabilities.isSuperset(of: .nativeV1Required) {
            compatibility = .advancedOverride
            diagnostic = "Version \(version) is outside the tested native range."
        } else if version != unknownVersion {
            compatibility = .terminalOnly
            diagnostic = "Version \(version) is outside the tested native range or lacks required RPC capabilities."
        } else {
            compatibility = .incompatible
            diagnostic = "Pi could not be capability-probed."
        }

        return PiRuntimeDescriptor(
            source: candidate.source,
            version: version,
            executable: candidate.url,
            compatibility: compatibility,
            capabilities: capabilities,
            diagnostic: diagnostic
        )
    }

    /// An out-of-range runtime is never authorized from version/help text alone.
    /// It must successfully execute the exact bundled bridge over its RPC transport.
    private func probeRPCAndBridge(
        _ candidate: Candidate,
        environment: [String: String],
        workingDirectory: URL
    ) async -> Bool {
        guard let bridgeURL = configuration.bridgeURL,
              FileManager.default.isReadableFile(atPath: bridgeURL.path) else {
            return false
        }
        let envelope = BridgeEnvelopeV1(nonce: BridgeCodec.randomNonce(), action: .ping)
        guard let commandMessage = try? BridgeCodec.commandMessage(for: envelope) else { return false }
        let command = JSONValue.object([
            "id": .string("apple-pi-compatibility-probe"),
            "type": .string("prompt"),
            "message": .string(commandMessage),
        ])
        guard var input = try? command.encodedData() else { return false }
        input.append(0x0A)

        let result: CapturedProcessResult
        do {
            result = try await ProcessCapture.run(
                executable: candidate.url,
                arguments: [
                    "--mode", "rpc", "--offline", "--no-session",
                    "--no-extensions", "--no-skills", "--no-prompt-templates",
                    "--no-themes", "--no-context-files",
                    "--extension", bridgeURL.path, "--no-approve",
                ],
                environment: environment,
                currentDirectory: workingDirectory,
                input: input,
                timeout: 8,
                maximumOutputBytes: 2 * 1_024 * 1_024
            )
        } catch {
            return false
        }

        var sawPromptResponse = false
        var sawValidBridgeResponse = false
        var framer = BoundedLineBuffer(maximumLineBytes: 1 * 1_024 * 1_024, maximumBufferedBytes: 2 * 1_024 * 1_024)
        guard let lines = try? framer.append(result.standardOutput) else { return false }
        var allLines = lines
        if let tail = try? framer.finish(), !tail.isEmpty { allLines.append(tail) }
        for line in allLines {
            guard let raw = try? JSONValue.decode(data: line), let object = raw.objectValue else { continue }
            if object["type"]?.stringValue == "response",
               object["id"]?.stringValue == "apple-pi-compatibility-probe",
               object["success"]?.boolValue == true {
                sawPromptResponse = true
            }
            if object["type"]?.stringValue == "extension_ui_request",
               object["method"]?.stringValue == "notify",
               let message = object["message"]?.stringValue,
               let response = try? BridgeCodec.decodeNotification(message),
               (try? BridgeCodec.validate(response, for: envelope)) != nil,
               response.success {
                sawValidBridgeResponse = true
            }
        }
        return sawPromptResponse && sawValidBridgeResponse
    }

    public static func defaultCommonLocations() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(filePath: "/opt/homebrew/bin/pi"),
            URL(filePath: "/usr/local/bin/pi"),
            home.appending(path: ".local/bin/pi"),
        ]
    }

    public static func defaultBridgeURL(bundle: Bundle = .main) -> URL? {
        [
            bundle.url(forResource: "apple-pi-bridge", withExtension: "ts"),
            bundle.url(forResource: "apple-pi-bridge", withExtension: "ts", subdirectory: "Bridge"),
        ].compactMap { $0 }.first(where: { FileManager.default.isReadableFile(atPath: $0.path) })
    }
}
