import Foundation
import Testing
@testable import ApplePi

@Suite("Lightweight task runtime coordination", .serialized)
struct RuntimeCoordinatorTests {
    @Test("A third generating turn queues until capacity is released")
    func thirdTurnQueues() async throws {
        let fixture = try CoordinatorFixture(settleDelay: 0, holdsTurnsUntilReleased: true)
        defer {
            try? fixture.releaseTurns()
            fixture.remove()
        }
        let coordinator = PiTaskRuntimeCoordinator(maximumConcurrentTurns: 2, idleGracePeriod: 60)
        let configurations = (0..<3).map { fixture.configuration(name: "task-\($0)") }

        for configuration in configurations {
            let opened = try await coordinator.open(configuration)
            #expect(opened.state.phase == .ready)
        }
        try await coordinator.submit(to: configurations[0].id, message: "first")
        try await coordinator.submit(to: configurations[1].id, message: "second")
        try await coordinator.submit(to: configurations[2].id, message: "third")

        let queuedSnapshot = await coordinator.snapshot(for: configurations[2].id)
        let queued = try #require(queuedSnapshot)
        #expect(queued.state.phase == .queued)
        #expect(queued.pendingTurnCount == 1)

        try fixture.releaseTurns()
        let drained = try await waitForSnapshot(
            coordinator,
            id: configurations[2].id,
            timeout: .seconds(10)
        ) { snapshot in
            snapshot.pendingTurnCount == 0
                && [.generating, .ready].contains(snapshot.state.phase)
        }
        #expect([.generating, .ready].contains(drained.state.phase))
        await coordinator.stopAll()
    }

    @Test("Idle standard runtimes stop while extension-backed runtimes stay resident")
    func idleEvictionPolicy() async throws {
        let fixture = try CoordinatorFixture(settleDelay: 0)
        defer { fixture.remove() }
        let coordinator = PiTaskRuntimeCoordinator(maximumConcurrentTurns: 2, idleGracePeriod: 0.05)
        let standard = fixture.configuration(name: "standard", hasUserExtensions: false)
        let extended = fixture.configuration(name: "extended", hasUserExtensions: true)

        _ = try await coordinator.open(standard)
        _ = try await coordinator.open(extended)
        try await Task.sleep(for: .milliseconds(180))

        let standardSnapshot = await coordinator.snapshot(for: standard.id)
        let extendedSnapshot = await coordinator.snapshot(for: extended.id)
        #expect(standardSnapshot?.state.phase == .stopped)
        #expect(extendedSnapshot?.state.phase == .ready)
        await coordinator.stopAll()
    }

    @Test("An idle-evicted runtime resumes before a control command")
    func idleEvictedRuntimeResumesForControlCommand() async throws {
        let fixture = try CoordinatorFixture(settleDelay: 0)
        defer { fixture.remove() }
        let coordinator = PiTaskRuntimeCoordinator(maximumConcurrentTurns: 2, idleGracePeriod: 0.15)
        let configuration = fixture.configuration(name: "idle-control")

        _ = try await coordinator.open(configuration)
        _ = try await waitForSnapshot(coordinator, id: configuration.id, timeout: .seconds(2)) {
            $0.state.phase == .stopped
        }

        let resumed = try await coordinator.ensureRunning(configuration.id)
        #expect(resumed.state.phase == .ready)
        let client = try #require(await coordinator.client(for: configuration.id))
        let response = try await client.send(.getAvailableModels, timeout: 1)
        #expect(response.success)
        #expect(response.command == "get_available_models")
        await coordinator.stopAll()
    }

    @Test("A manually stopped runtime resumes with its canonical session path")
    func manuallyStoppedRuntimeResumesForControlCommand() async throws {
        let fixture = try CoordinatorFixture(settleDelay: 0)
        defer { fixture.remove() }
        let coordinator = PiTaskRuntimeCoordinator(maximumConcurrentTurns: 2, idleGracePeriod: 5)
        let configuration = fixture.configuration(name: "manual-control")
        let canonicalSession = fixture.directory.appending(path: "canonical-resume.jsonl")

        _ = try await coordinator.open(configuration)
        await coordinator.setResumeSessionPath(canonicalSession, for: configuration.id)
        await coordinator.stop(configuration.id)
        #expect(await coordinator.snapshot(for: configuration.id)?.state.phase == .stopped)

        let resumed = try await coordinator.ensureRunning(configuration.id)
        #expect(resumed.state.phase == .ready)
        let client = try #require(await coordinator.client(for: configuration.id))
        let response = try await client.send(
            .setModel(provider: "test-provider", modelID: "test-model"),
            timeout: 1
        )
        #expect(response.success)
        #expect(response.command == "set_model")

        let launches = try String(contentsOf: fixture.launchArgumentsURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        #expect(launches.count == 2)
        #expect(launches.last?.contains("--session\t\(canonicalSession.path)") == true)
        await coordinator.stopAll()
    }

    @Test("A restart overlapping idle termination wins without a stale stopped state")
    func restartOverlappingIdleTerminationRemainsReady() async throws {
        let fixture = try CoordinatorFixture(settleDelay: 0, terminationDelay: 0.2)
        defer { fixture.remove() }
        let coordinator = PiTaskRuntimeCoordinator(maximumConcurrentTurns: 2, idleGracePeriod: 0.05)
        let configuration = fixture.configuration(name: "idle-race")

        _ = try await coordinator.open(configuration)
        _ = try await waitForSnapshot(coordinator, id: configuration.id, timeout: .seconds(2)) {
            $0.state.phase == .stopped
        }

        let resumed = try await coordinator.ensureRunning(configuration.id)
        #expect(resumed.state.phase == .ready)
        let client = try #require(await coordinator.client(for: configuration.id))
        #expect(await client.isRunning)
        let response = try await client.send(.getAvailableThinkingLevels, timeout: 1)
        #expect(response.success)
        #expect(await coordinator.snapshot(for: configuration.id)?.state.phase == .ready)
        await coordinator.stopAll()
    }

    @Test("An unretried agent error remains failed after the agent settles")
    func terminalAgentErrorRemainsFailed() async throws {
        let fixture = try CoordinatorFixture(settleDelay: 0, emitsTerminalAgentError: true)
        defer { fixture.remove() }
        let coordinator = PiTaskRuntimeCoordinator(maximumConcurrentTurns: 2, idleGracePeriod: 5)
        let configuration = fixture.configuration(name: "terminal-error")

        _ = try await coordinator.open(configuration)
        try await coordinator.submit(to: configuration.id, message: "run")

        let failed = try await waitForSnapshot(
            coordinator,
            id: configuration.id,
            timeout: .seconds(2)
        ) { $0.state.phase == .failed }
        #expect(failed.state.detail == "API rate limit reached")
        try await Task.sleep(for: .milliseconds(80))
        #expect(await coordinator.snapshot(for: configuration.id)?.state.phase == .failed)
        await coordinator.stopAll()
    }

    @Test("Streaming RPC updates do not emit duplicate runtime snapshots")
    func streamingUpdatesDoNotEmitChangedSnapshots() async throws {
        let fixture = try CoordinatorFixture(settleDelay: 0, streamUpdateCount: 50)
        defer { fixture.remove() }
        let coordinator = PiTaskRuntimeCoordinator(maximumConcurrentTurns: 2, idleGracePeriod: 5)
        let configuration = fixture.configuration(name: "stream-updates")
        _ = try await coordinator.open(configuration)

        let observedChanges = Task {
            var updateCount = 0
            var changedAfterStreamingBegan = 0
            for await event in coordinator.events {
                switch event {
                case .rpc(_, .messageUpdated):
                    updateCount += 1
                    if updateCount == 50 { return changedAfterStreamingBegan }
                case .changed where updateCount > 0:
                    changedAfterStreamingBegan += 1
                default:
                    break
                }
            }
            return changedAfterStreamingBegan
        }

        try await coordinator.submit(to: configuration.id, message: "stream")
        #expect(await observedChanges.value == 0)
        await coordinator.stopAll()
    }

    private func waitForSnapshot(
        _ coordinator: PiTaskRuntimeCoordinator,
        id: PiTaskID,
        timeout: Duration,
        predicate: (PiTaskSnapshot) -> Bool
    ) async throws -> PiTaskSnapshot {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let snapshot = await coordinator.snapshot(for: id), predicate(snapshot) {
                return snapshot
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TestTimeoutError()
    }
}

private struct CoordinatorFixture: @unchecked Sendable {
    let directory: URL
    let executable: URL
    let launchArgumentsURL: URL
    let settleGateURL: URL?

    init(
        settleDelay: TimeInterval,
        terminationDelay: TimeInterval = 0,
        emitsTerminalAgentError: Bool = false,
        streamUpdateCount: Int = 0,
        holdsTurnsUntilReleased: Bool = false
    ) throws {
        directory = try TestSupport.temporaryDirectory(named: "CoordinatorFixture")
        executable = directory.appending(path: "fake-pi")
        launchArgumentsURL = directory.appending(path: "launch-arguments.txt")
        settleGateURL = holdsTurnsUntilReleased
            ? directory.appending(path: "settle-gate")
            : nil
        let settleAction = holdsTurnsUntilReleased
            ? "while [ ! -e settle-gate ]; do /bin/sleep 0.02; done"
            : "/bin/sleep \(settleDelay)"
        try TestSupport.writeExecutableShellScript(
            """
            trap '/bin/sleep \(terminationDelay); exit 0' TERM
            {
              printf 'launch'
              for argument in "$@"; do printf '\t%s' "$argument"; done
              printf '\n'
            } >> launch-arguments.txt
            while IFS= read -r line; do
              request_id=$(printf '%s\\n' "$line" | /usr/bin/sed -E 's/.*"id":"([^"]+)".*/\\1/')
              request_type=$(printf '%s\\n' "$line" | /usr/bin/sed -E 's/.*"type":"([^"]+)".*/\\1/')
              printf '{"type":"response","id":"%s","command":"%s","success":true,"data":{}}\\n' "$request_id" "$request_type"
              if [ "$request_type" = "prompt" ]; then
                printf '%s\\n' '{"type":"agent_start"}'
                i=0
                while [ "$i" -lt "\(streamUpdateCount)" ]; do
                  printf '%s\\n' '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"x"}}'
                  i=$((i + 1))
                done
                \(settleAction)
                if [ "\(emitsTerminalAgentError)" = "true" ]; then
                  printf '%s\\n' '{"type":"agent_end","messages":[{"role":"assistant","stopReason":"error","errorMessage":"API rate limit reached"}],"willRetry":false}'
                fi
                printf '%s\\n' '{"type":"agent_settled"}'
              fi
            done
            """,
            to: executable
        )
    }

    func configuration(name: String, hasUserExtensions: Bool = false) -> PiTaskLaunchConfiguration {
        PiTaskLaunchConfiguration(
            workingDirectory: directory,
            sessionPath: directory.appending(path: "\(name).jsonl"),
            projectTrusted: true,
            hasUserExtensions: hasUserExtensions,
            runtime: TestSupport.nativeRuntime(executable: executable),
            environment: ["PATH": "/usr/bin:/bin"],
            bridgeURL: nil
        )
    }

    func releaseTurns() throws {
        guard let settleGateURL else { return }
        try Data().write(to: settleGateURL, options: .atomic)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
