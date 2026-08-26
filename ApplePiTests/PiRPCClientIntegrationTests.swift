import Foundation
import Testing
@testable import ApplePi

@Suite("Pi JSONL RPC client", .serialized)
struct PiRPCClientIntegrationTests {
    @Test("Concurrent responses are correlated by ID even when Pi replies out of order")
    func correlatesOutOfOrderResponses() async throws {
        let fixture = try RPCFixture(
            script: """
            IFS= read -r first
            IFS= read -r second
            first_id=$(printf '%s\\n' "$first" | /usr/bin/sed -E 's/.*"id":"([^"]+)".*/\\1/')
            second_id=$(printf '%s\\n' "$second" | /usr/bin/sed -E 's/.*"id":"([^"]+)".*/\\1/')
            first_type=$(printf '%s\\n' "$first" | /usr/bin/sed -E 's/.*"type":"([^"]+)".*/\\1/')
            second_type=$(printf '%s\\n' "$second" | /usr/bin/sed -E 's/.*"type":"([^"]+)".*/\\1/')
            printf '{"type":"response","id":"%s","command":"%s","success":true,"data":{"order":2}}\\n' "$second_id" "$second_type"
            printf '{"type":"response","id":"%s","command":"%s","success":true,"data":{"order":1}}\\n' "$first_id" "$first_type"
            /bin/sleep 10
            """
        )
        defer { fixture.remove() }
        let client = fixture.client()
        try await client.start()

        async let state = client.send(.getState, timeout: 2)
        async let stats = client.send(.getSessionStats, timeout: 2)
        let (stateResponse, statsResponse) = try await (state, stats)

        #expect(stateResponse.command == "get_state")
        #expect(statsResponse.command == "get_session_stats")
        #expect(stateResponse.success)
        #expect(statsResponse.success)
        await client.stop(gracePeriod: 0)
    }

    @Test("Fragmented event lines are reduced without losing streaming deltas")
    func fragmentedStreamingEvent() async throws {
        let fixture = try RPCFixture(
            script: """
            printf '%s' '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","del'
            /bin/sleep 0.05
            printf '%s\\n' 'ta":"hello"}}'
            /bin/sleep 10
            """
        )
        defer { fixture.remove() }
        let client = fixture.client()
        try await client.start()

        let event = try await TestSupport.nextEvent(in: client.events) {
            if case .messageUpdated = $0 { return true }
            return false
        }
        guard case let .messageUpdated(kind, delta, raw) = event else {
            Issue.record("Expected a message update event")
            return
        }
        #expect(kind == "text_delta")
        #expect(delta == "hello")
        #expect(raw["type"]?.stringValue == "message_update")
        await client.stop(gracePeriod: 0)
    }

    @Test("Unknown extension events remain available as lossless JSON")
    func unknownEventsAreLossless() async throws {
        let fixture = try RPCFixture(
            script: """
            printf '%s\\n' '{"type":"creator_specific_event","payload":{"number":7,"kept":true}}'
            /bin/sleep 10
            """
        )
        defer { fixture.remove() }
        let client = fixture.client()
        try await client.start()

        let event = try await TestSupport.nextEvent(in: client.events) {
            if case .unknown(type: "creator_specific_event", raw: _) = $0 { return true }
            return false
        }
        guard case let .unknown(type, raw) = event else {
            Issue.record("Expected an unknown event")
            return
        }
        #expect(type == "creator_specific_event")
        #expect(raw["payload"]?["number"]?.numberValue == 7)
        #expect(raw["payload"]?["kept"]?.boolValue == true)
        await client.stop(gracePeriod: 0)
    }

    @Test("Reserved bridge notifications become bridge events, not visible extension UI")
    func bridgeNotificationIsSuppressed() async throws {
        let response = BridgeResponseV1(
            version: 1,
            requestID: "bridge-request",
            nonce: "bridge-nonce",
            success: true,
            result: .object(["ready": .bool(true)]),
            error: nil
        )
        let encoded = try JSONEncoder.applePi.encode(response)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let marker = BridgeCodec.notificationPrefix + encoded
        let fixture = try RPCFixture(
            script: """
            printf '%s\\n' '{"type":"extension_ui_request","id":"notification-1","method":"notify","message":"\(marker)","notifyType":"info"}'
            /bin/sleep 10
            """
        )
        defer { fixture.remove() }
        let client = fixture.client()
        try await client.start()

        let event = try await TestSupport.nextEvent(in: client.events) {
            if case .bridge = $0 { return true }
            return false
        }
        guard case let .bridge(decoded) = event else {
            Issue.record("Expected a reserved bridge event")
            return
        }
        #expect(decoded.requestID == "bridge-request")
        #expect(decoded.nonce == "bridge-nonce")
        #expect(decoded.result?["ready"]?.boolValue == true)
        await client.stop(gracePeriod: 0)
    }

    @Test("RPC launch uses literal argv for session, bridge, offline, and trust flags")
    func launchArgumentSafety() async throws {
        let fixture = try RPCFixture(
            sessionName: "session; touch injected file.jsonl",
            bridgeName: "bridge $(touch injected).ts",
            projectTrusted: false,
            script: """
            : > argv.txt
            for argument in "$@"; do
              printf '%s\\n' "$argument" >> argv.txt
            done
            /bin/sleep 10
            """
        )
        defer { fixture.remove() }
        let client = fixture.client()
        try await client.start()
        let argumentsURL = fixture.directory.appending(path: "argv.txt")
        try await TestSupport.waitUntil {
            FileManager.default.fileExists(atPath: argumentsURL.path)
        }
        let arguments = try String(contentsOf: argumentsURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)

        #expect(arguments == [
            "--mode", "rpc", "--offline",
            "--session", fixture.sessionURL.path,
            "--extension", fixture.bridgeURL.path,
            "--no-approve",
        ])
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appending(path: "injected").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appending(path: "injected file.jsonl").path))
        await client.stop(gracePeriod: 0)
    }

    @Test("Failed responses and missing responses surface typed errors")
    func errorsAreTyped() async throws {
        let rejection = try RPCFixture(
            script: """
            IFS= read -r line
            request_id=$(printf '%s\\n' "$line" | /usr/bin/sed -E 's/.*"id":"([^"]+)".*/\\1/')
            printf '{"type":"response","id":"%s","command":"get_state","success":false,"error":"denied"}\\n' "$request_id"
            /bin/sleep 10
            """
        )
        defer { rejection.remove() }
        let rejectingClient = rejection.client()
        try await rejectingClient.start()
        do {
            _ = try await rejectingClient.send(.getState, timeout: 2)
            Issue.record("Expected a rejected response")
        } catch let error as PiRPCClientError {
            guard case let .requestFailed(command, message) = error else {
                Issue.record("Unexpected RPC error: \(error)")
                return
            }
            #expect(command == "get_state")
            #expect(message == "denied")
        }
        await rejectingClient.stop(gracePeriod: 0)

        let timeout = try RPCFixture(script: "/bin/sleep 10")
        defer { timeout.remove() }
        let silentClient = timeout.client()
        try await silentClient.start()
        do {
            _ = try await silentClient.send(.getState, timeout: 0.05)
            Issue.record("Expected an RPC timeout")
        } catch let error as PiRPCClientError {
            guard case let .requestTimedOut(command) = error else {
                Issue.record("Unexpected RPC error: \(error)")
                return
            }
            #expect(command == "get_state")
        }
        await silentClient.stop(gracePeriod: 0)
    }

    @Test("An immediate exit preserves its final unterminated response")
    func immediateExitFinalResponse() async throws {
        let fixture = try RPCFixture(
            script: """
            IFS= read -r line
            request_id=$(printf '%s\n' "$line" | /usr/bin/sed -E 's/.*"id":"([^"]+)".*/\\1/')
            printf '{"type":"response","id":"%s","command":"get_state","success":true,"data":{"final":true}}' "$request_id"
            """
        )
        defer { fixture.remove() }
        let client = fixture.client()
        try await client.start()

        let response = try await client.send(.getState, timeout: 2)

        #expect(response.success)
        #expect(response.data?["final"]?.boolValue == true)
    }

    @Test("Canceling a request does not wait for its response deadline")
    func requestCancellation() async throws {
        let fixture = try RPCFixture(script: "/bin/sleep 10")
        defer { fixture.remove() }
        let client = fixture.client()
        try await client.start()
        let clock = ContinuousClock()
        let started = clock.now
        let request = Task { try await client.send(.getState, timeout: 30) }
        try await Task.sleep(for: .milliseconds(50))
        request.cancel()

        do {
            _ = try await request.value
            Issue.record("Expected request cancellation")
        } catch is CancellationError {
            // Expected.
        }
        #expect(started.duration(to: clock.now) < .seconds(1))
        await client.stop(gracePeriod: 0)
    }

    @Test("A blocked outbound write does not block stop or cancellation")
    func blockedWriteDoesNotBlockActor() async throws {
        let fixture = try RPCFixture(script: "/bin/sleep 10")
        defer { fixture.remove() }
        let client = fixture.client()
        try await client.start()
        let request = Task {
            try await client.send(
                .prompt(message: String(repeating: "x", count: 2 * 1_024 * 1_024), images: [], behavior: nil),
                timeout: 30
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        request.cancel()
        await client.stop(gracePeriod: 0)

        do {
            _ = try await request.value
            Issue.record("Expected blocked request cancellation")
        } catch is CancellationError {
            // Expected.
        } catch let error as PiRPCClientError {
            // Closing the transport may win the cancellation race.
            if case .protocolViolation = error { return }
            Issue.record("Unexpected RPC error: \(error)")
        }
    }

    @Test("A stalled consumer drops only deltas across ten thousand mixed events")
    func stalledConsumerPreservesLifecycleOrderWithinByteCap() async throws {
        let directory = try TestSupport.temporaryDirectory(named: "RPCFlood")
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appending(path: "flood-pi")
        try TestSupport.writeExecutable(
            """
            #!/usr/bin/python3
            import json
            import os

            def emit(value):
                os.write(1, (json.dumps(value, separators=(",", ":")) + "\\n").encode())

            for index in range(10000):
                if index % 1000 == 0:
                    emit({"type":"agent_start", "seq":str(index)})
                    emit({"type":"tool_execution_start", "toolCallId":str(index), "toolName":"fixture", "seq":str(index)})
                if index % 2 == 0:
                    emit({"type":"message_update", "assistantMessageEvent":{"type":"text_delta", "delta":"x" * 64}, "seq":str(index)})
                else:
                    emit({"type":"tool_execution_update", "toolCallId":str(index), "toolName":"fixture", "delta":"y" * 64, "seq":str(index)})
                if index % 1000 == 999:
                    emit({"type":"tool_execution_end", "toolCallId":str(index - 999), "toolName":"fixture", "isError":False, "seq":str(index)})
                    emit({"type":"agent_settled", "seq":str(index)})

            emit({"type":"message_end", "seq":"final"})
            os.write(2, b"final-stderr")
            """,
            to: executable
        )
        let retainedDeltaCap = 8 * 1_024
        let client = PiRPCClient(configuration: .init(
            runtime: TestSupport.nativeRuntime(executable: executable),
            workingDirectory: directory,
            projectTrusted: true,
            bridgeURL: nil,
            environment: ["PATH": "/usr/bin:/bin"],
            maximumLineBytes: 32 * 1_024,
            maximumBufferedBytes: 64 * 1_024,
            maximumEventBufferedBytes: retainedDeltaCap,
            stderrCapacity: 1_024
        ))

        try await client.start()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if !(await client.hasActiveProcessResources) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let stillActive = await client.hasActiveProcessResources
        #expect(!stillActive)
        let retainedDeltaBytes = await client.bufferedLossyEventByteCount
        let totalRetainedBytes = await client.bufferedEventByteCount
        #expect(retainedDeltaBytes <= retainedDeltaCap)
        #expect(totalRetainedBytes < 64 * 1_024)

        let events = try await withThrowingTaskGroup(of: [PiRPCEvent].self) { group in
            group.addTask {
                var retained: [PiRPCEvent] = []
                for await event in client.events {
                    retained.append(event)
                    if case .processTerminated = event { return retained }
                }
                throw EventStreamEndedError()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(3))
                throw TestTimeoutError()
            }
            let result = try await group.next() ?? []
            group.cancelAll()
            return result
        }

        var lifecycle: [String] = []
        var sawGap = false
        var deliveredDeltaCount = 0
        for event in events {
            switch event {
            case .streamGap:
                sawGap = true
            case let .agentStarted(raw):
                lifecycle.append("agent-start:\(raw["seq"]?.stringValue ?? "?")")
            case let .toolStarted(_, _, raw):
                lifecycle.append("tool-start:\(raw["seq"]?.stringValue ?? "?")")
            case let .toolEnded(_, _, _, raw):
                lifecycle.append("tool-end:\(raw["seq"]?.stringValue ?? "?")")
            case let .agentSettled(raw):
                lifecycle.append("settled:\(raw["seq"]?.stringValue ?? "?")")
            case let .messageEnded(raw):
                lifecycle.append("message-end:\(raw["seq"]?.stringValue ?? "?")")
            case .messageUpdated, .toolUpdated:
                deliveredDeltaCount += 1
            case let .processTerminated(status, stderr):
                lifecycle.append("terminated:\(status):\(stderr)")
            default:
                break
            }
        }

        var expected: [String] = []
        for block in 0..<10 {
            expected.append("agent-start:\(block * 1_000)")
            expected.append("tool-start:\(block * 1_000)")
            expected.append("tool-end:\(block * 1_000 + 999)")
            expected.append("settled:\(block * 1_000 + 999)")
        }
        expected.append("message-end:final")
        expected.append("terminated:0:final-stderr")
        #expect(sawGap)
        #expect(deliveredDeltaCount < 10_000)
        #expect(lifecycle == expected)
    }
}

private struct RPCFixture: @unchecked Sendable {
    let directory: URL
    let executable: URL
    let sessionURL: URL
    let bridgeURL: URL
    let projectTrusted: Bool

    init(
        sessionName: String = "session.jsonl",
        bridgeName: String = "apple-pi-bridge.ts",
        projectTrusted: Bool = true,
        script: String
    ) throws {
        directory = try TestSupport.temporaryDirectory(named: "RPCFixture")
        executable = directory.appending(path: "fake-pi")
        sessionURL = directory.appending(path: sessionName)
        bridgeURL = directory.appending(path: bridgeName)
        self.projectTrusted = projectTrusted
        try TestSupport.writeExecutableShellScript(script, to: executable)
    }

    func client() -> PiRPCClient {
        PiRPCClient(configuration: .init(
            runtime: TestSupport.nativeRuntime(executable: executable),
            workingDirectory: directory,
            sessionPath: sessionURL,
            projectTrusted: projectTrusted,
            bridgeURL: bridgeURL,
            environment: ["PATH": "/usr/bin:/bin"],
            offlineStartup: true,
            maximumLineBytes: 32 * 1_024,
            maximumBufferedBytes: 64 * 1_024,
            stderrCapacity: 1_024
        ))
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
