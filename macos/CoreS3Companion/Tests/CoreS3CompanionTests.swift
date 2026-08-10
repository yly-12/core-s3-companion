import Foundation
import Testing

#if SWIFT_PACKAGE
@testable import CoreS3CompanionCore
#else
@testable import CoreS3Companion
#endif

@Suite("Agent status message")
struct AgentStatusMessageTests {
    @Test("Encodes compact status header and UTF-8 title")
    func encodesStatusFrame() throws {
        let snapshot = AgentSnapshot(
            source: .claude,
            state: .waitingAuthorization,
            title: "Firmware CI",
            fiveHourRemaining: 68,
            weeklyRemaining: 42,
            contextUsed: 61,
            updatedAt: nil
        )

        let data = try AgentStatusMessageEncoder.encode(snapshot)
        #expect(Array(data.prefix(8)) == [0x01, 0x02, 0x02, 0x01, 68, 42, 61, 11])
        #expect(String(decoding: data.dropFirst(8), as: UTF8.self) == "FIRMWARE CI")
    }

    @Test("Unknown metrics use the sentinel value")
    func unknownMetricsUseSentinel() throws {
        let data = try AgentStatusMessageEncoder.encode(.idle)
        #expect(Array(Array(data)[4...6]) == [0xFF, 0xFF, 0xFF])
    }

    @Test("Display title preserves Chinese and stays bounded")
    func sanitizesDisplayTitle() {
        let title = DisplayTitle.sanitize("修复蓝牙配对 · CoreS3 Companion")
        #expect(title.utf8.count <= DisplayTitle.maximumByteCount)
        #expect(title.hasPrefix("修复蓝牙配对"))
    }
}

@Suite("CPU message compatibility")
struct CPUMessageTests {
    @Test("Encodes the legacy three-byte frame")
    func encodesVersionedCPUFrame() throws {
        let data = try CPUMessageEncoder.encode(cpuUsage: 42)
        #expect(Array(data) == [0x01, 0x01, 42])
    }
}

@Suite("CPU usage calculation")
struct CPUUsageCalculatorTests {
    @Test("Calculates aggregate usage from tick deltas")
    func calculatesAggregateUsageFromTickDelta() {
        var calculator = CPUUsageCalculator()
        _ = calculator.consume(CPUTicks(user: 10, system: 10, idle: 80, nice: 0))
        let result = calculator.consume(CPUTicks(user: 20, system: 20, idle: 160, nice: 0))
        #expect(result == 20)
    }
}

@Suite("BLE selection policy")
struct BLESelectionPolicyTests {
    @Test("Only the saved device is auto-connected")
    func onlySavedDeviceIsAutoConnected() {
        let savedID = UUID()
        #expect(BLESelectionPolicy.shouldAutoConnect(discoveredID: savedID, targetID: savedID))
        #expect(!BLESelectionPolicy.shouldAutoConnect(discoveredID: UUID(), targetID: savedID))
        #expect(!BLESelectionPolicy.shouldAutoConnect(discoveredID: savedID, targetID: nil))
    }
}

@Suite("Agent integration manager")
struct AgentIntegrationManagerTests {
    @Test("Claude install preserves existing hooks and restores status line")
    func claudeInstallAndUninstallAreReversible() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("core-s3-integration-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let settingsURL = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try jsonData([
            "hooks": [
                "SessionStart": [["hooks": [["type": "command", "command": "echo existing"]]]]
            ],
            "statusLine": ["type": "command", "command": "/tmp/original-status"],
        ]).write(to: settingsURL)

        let manager = AgentIntegrationManager(homeURL: home, applicationSupportURL: support)
        try manager.install(.claude)
        #expect(manager.status(for: .claude).isInstalled)

        let hookScript = support.appendingPathComponent("bin/core-s3-agent-hook.js")
        try runHook(
            scriptURL: hookScript,
            source: "claude",
            payload: [
                "session_id": "claude-test-session",
                "hook_event_name": "PermissionRequest",
                "cwd": "/tmp/core-s3",
                "prompt": "Allow firmware upload?",
            ]
        )
        try runHook(
            scriptURL: hookScript,
            source: "claude-status",
            payload: [
                "session_id": "claude-test-session",
                "session_name": "中文会话",
                "context_window": ["used_percentage": 37],
                "rate_limits": [
                    "five_hour": ["used_percentage": 12],
                    "seven_day": ["used_percentage": 34],
                ],
            ]
        )
        let stateURL = support.appendingPathComponent("state/claude-session-claude-test-session.json")
        let state = try jsonObject(at: stateURL)
        #expect(state["state"] as? String == "waiting_authorization")

        let monitor = AgentStatusMonitor(
            stateDirectoryURL: support.appendingPathComponent("state"),
            codexSessionsURL: root.appendingPathComponent("no-codex-sessions")
        )
        monitor.selectedSource = .claude
        var snapshots: [AgentSnapshot] = []
        monitor.onSnapshots = { snapshots = $0 }
        monitor.refresh()
        #expect(snapshots.first?.title == "中文会话")
        #expect(snapshots.first?.fiveHourRemaining == 88)
        #expect(snapshots.first?.weeklyRemaining == 66)
        #expect(snapshots.first?.contextUsed == 37)

        try manager.uninstall(.claude)
        let restored = try jsonObject(at: settingsURL)
        let statusLine = restored["statusLine"] as? [String: Any]
        #expect(statusLine?["command"] as? String == "/tmp/original-status")
        #expect(jsonText(restored).contains("echo existing"))
        #expect(!manager.status(for: .claude).isInstalled)
    }

    @Test("Codex install enables hooks without deleting config")
    func codexInstallPreservesConfig() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("core-s3-codex-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "model = \"gpt-5\"\n".write(to: configURL, atomically: true, encoding: .utf8)

        let manager = AgentIntegrationManager(homeURL: home, applicationSupportURL: support)
        try manager.install(.codex)
        let config = try String(contentsOf: configURL, encoding: .utf8)
        #expect(config.contains("model = \"gpt-5\""))
        #expect(config.contains("[features]"))
        #expect(config.contains("hooks = true"))
        #expect(manager.status(for: .codex).isInstalled)
    }
}

@Suite("Agent status monitor")
struct AgentStatusMonitorTests {
    @Test("Reads Codex status and quotas from the latest rollout")
    func readsCodexRollout() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("core-s3-monitor-\(UUID().uuidString)", isDirectory: true)
        let states = root.appendingPathComponent("state", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions/2026/08/10", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: states, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        let rollout = sessions.appendingPathComponent("rollout-test.jsonl")
        let lines = [
            try rolloutLine(type: "user_message", payload: ["message": "Implement menu bar status"]),
            try rolloutLine(type: "request_user_input", payload: ["prompt": "Choose a layout"]),
            try rolloutLine(type: "token_count", payload: [
                "rate_limits": [
                    "primary": ["used_percent": 32, "window_minutes": 10_080],
                ],
                "info": [
                    "total_token_usage": ["total_tokens": 9_999_999],
                    "last_token_usage": ["total_tokens": 61_000],
                    "model_context_window": 100_000,
                ],
            ]),
        ]
        try lines.joined(separator: "\n").write(to: rollout, atomically: true, encoding: .utf8)

        let monitor = AgentStatusMonitor(stateDirectoryURL: states, codexSessionsURL: root.appendingPathComponent("sessions"))
        monitor.selectedSource = .codex
        var snapshot: AgentSnapshot?
        monitor.onSnapshots = { snapshot = $0.first }
        monitor.refresh()

        #expect(snapshot?.source == .codex)
        #expect(snapshot?.state == .waitingReply)
        #expect(snapshot?.title == "Implement menu bar status")
        #expect(snapshot?.fiveHourRemaining == nil)
        #expect(snapshot?.weeklyRemaining == 68)
        #expect(snapshot?.contextUsed == 61)
    }

    @Test("Returns multiple active sessions in alert priority order")
    func returnsMultipleActiveSessions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("core-s3-multi-session-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let now = Date().timeIntervalSince1970
        try jsonData([
            "sessionID": "session-running",
            "state": "running",
            "title": "运行会话",
            "updatedAt": now,
        ]).write(to: root.appendingPathComponent("claude-session-running.json"))
        try jsonData([
            "sessionID": "session-auth",
            "state": "waiting_authorization",
            "title": "授权会话",
            "updatedAt": now,
        ]).write(to: root.appendingPathComponent("claude-session-auth.json"))

        let monitor = AgentStatusMonitor(
            stateDirectoryURL: root,
            codexSessionsURL: root.appendingPathComponent("no-codex")
        )
        monitor.selectedSource = .claude
        var snapshots: [AgentSnapshot] = []
        monitor.onSnapshots = { snapshots = $0 }
        monitor.refresh()

        #expect(snapshots.map(\.sessionID) == ["session-auth", "session-running"])
    }
}

@Suite("Companion view model")
struct CompanionViewModelTests {
    @Test("Manual pairing is saved only after service discovery succeeds")
    func manualPairIsSavedOnlyAfterTransportIsReady() {
        let transport = MockBLETransport()
        let store = MemoryPairedDeviceStore()
        let model = makeModel(transport: transport, pairedStore: store)
        let device = DiscoveredDevice(id: UUID(), name: "Desk CoreS3", rssi: -40)

        model.start()
        model.pair(device)
        #expect(transport.pairedDeviceID == device.id)
        #expect(store.deviceID == nil)

        transport.onReady?(device.id, device.name)
        #expect(store.deviceID == device.id)
        #expect(model.pairedDeviceID == device.id)
    }

    @Test("Agent snapshots are sent only while connected")
    func snapshotsAreSentOnlyWhenConnected() throws {
        let transport = MockBLETransport()
        let monitor = MockAgentStatusMonitor()
        let model = makeModel(transport: transport, monitor: monitor)
        let snapshot = AgentSnapshot(
            source: .codex,
            state: .running,
            title: "Status UI",
            fiveHourRemaining: 80,
            weeklyRemaining: 70,
            contextUsed: 20,
            updatedAt: nil
        )

        monitor.onSnapshots?([snapshot])
        #expect(transport.sentPackets.isEmpty)

        transport.onStateChange?(.connected(UUID()))
        monitor.onSnapshots?([snapshot])
        #expect(transport.sentPackets == [try AgentStatusMessageEncoder.encode(snapshot)])
        _ = model
    }

    @Test("Rotates active sessions before sending")
    func rotatesActiveSessions() throws {
        let transport = MockBLETransport()
        let monitor = MockAgentStatusMonitor()
        let model = makeModel(transport: transport, monitor: monitor)
        transport.onStateChange?(.connected(UUID()))
        let first = AgentSnapshot(
            sessionID: "first",
            source: .claude,
            state: .running,
            title: "第一个会话",
            fiveHourRemaining: nil,
            weeklyRemaining: nil,
            contextUsed: 20,
            updatedAt: .now
        )
        let second = AgentSnapshot(
            sessionID: "second",
            source: .codex,
            state: .waitingReply,
            title: "第二个会话",
            fiveHourRemaining: nil,
            weeklyRemaining: 70,
            contextUsed: 40,
            updatedAt: .now
        )

        monitor.onSnapshots?([first, second])
        model.rotateSession()

        #expect(model.agentSnapshot.sessionID == "second")
        #expect(transport.sentPackets.suffix(2) == [
            try AgentStatusMessageEncoder.encode(first),
            try AgentStatusMessageEncoder.encode(second),
        ])
    }
}

private func makeModel(
    transport: MockBLETransport = MockBLETransport(),
    monitor: MockAgentStatusMonitor = MockAgentStatusMonitor(),
    pairedStore: MemoryPairedDeviceStore = MemoryPairedDeviceStore()
) -> CompanionViewModel {
    CompanionViewModel(
        transport: transport,
        monitor: monitor,
        pairedDeviceStore: pairedStore,
        preferenceStore: MemoryAgentPreferenceStore(),
        integrationManager: MockAgentIntegrationManager()
    )
}

private final class MockBLETransport: BLETransporting {
    var onStateChange: ((BLEConnectionState) -> Void)?
    var onDevicesChange: (([DiscoveredDevice]) -> Void)?
    var onReady: ((UUID, String) -> Void)?
    var onError: ((String) -> Void)?
    var pairedDeviceID: UUID?
    var sentPackets: [Data] = []

    func start(savedDeviceID: UUID?) {}
    func scan() {}
    func pair(deviceID: UUID) { pairedDeviceID = deviceID }
    func retry(deviceID: UUID) {}
    func unpair() {}
    func send(_ data: Data) -> Bool { sentPackets.append(data); return true }
}

private final class MockAgentStatusMonitor: AgentStatusMonitoring {
    var onSnapshots: (([AgentSnapshot]) -> Void)?
    var selectedSource: AgentSource = .automatic
    func start() {}
    func stop() {}
    func refresh() {}
}

private final class MemoryPairedDeviceStore: PairedDeviceStoring {
    var deviceID: UUID?
    var deviceName: String?
    init(deviceID: UUID? = nil, deviceName: String? = nil) {
        self.deviceID = deviceID
        self.deviceName = deviceName
    }
    func clear() { deviceID = nil; deviceName = nil }
}

private final class MemoryAgentPreferenceStore: AgentPreferenceStoring {
    var selectedSource: AgentSource = .automatic
}

private final class MockAgentIntegrationManager: AgentIntegrationManaging {
    func status(for kind: AgentIntegrationKind) -> AgentIntegrationStatus {
        AgentIntegrationStatus(kind: kind, isInstalled: false, detail: "", configPath: "")
    }
    func install(_ kind: AgentIntegrationKind) throws {}
    func uninstall(_ kind: AgentIntegrationKind) throws {}
}

private func jsonData(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
}

private func jsonObject(at url: URL) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
}

private func jsonText(_ object: [String: Any]) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
}

private func rolloutLine(type: String, payload: [String: Any]) throws -> String {
    var eventPayload = payload
    eventPayload["type"] = type
    let object: [String: Any] = [
        "timestamp": isoTimestamp(.now),
        "type": "event_msg",
        "payload": eventPayload,
    ]
    return String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
}

private func isoTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private func runHook(scriptURL: URL, source: String, payload: [String: Any]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    let stateDirectory = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("state")
    process.arguments = ["-l", "JavaScript", scriptURL.path, source, stateDirectory.path]
    let input = Pipe()
    process.standardInput = input
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    try input.fileHandleForWriting.write(contentsOf: jsonData(payload))
    try input.fileHandleForWriting.close()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}
