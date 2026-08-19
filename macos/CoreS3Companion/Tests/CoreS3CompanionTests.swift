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
            modelName: "Opus 4.7",
            effort: "xhigh",
            fiveHourRemaining: 68,
            weeklyRemaining: 42,
            contextUsed: 61,
            updatedAt: nil
        )

        let data = try AgentStatusMessageEncoder.encode(snapshot)
        #expect(Array(data.prefix(8)) == [0x01, 0x02, 0x02, 0x01, 68, 42, 61, 11])
        #expect(String(decoding: data.dropFirst(8).prefix(11), as: UTF8.self) == "FIRMWARE CI")
        #expect(Array(data.dropFirst(19).prefix(2)) == [8, 5])
        #expect(String(decoding: data.dropFirst(21).prefix(8), as: UTF8.self) == "OPUS 4.7")
        #expect(String(decoding: data.dropFirst(29).prefix(5), as: UTF8.self) == "XHIGH")
        #expect(Array(data.suffix(10)) == [0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF])
    }

    @Test("Encodes display timeout and activity marker")
    func encodesDisplaySettings() throws {
        var snapshot = AgentSnapshot.idle
        snapshot.updatedAt = Date(timeIntervalSince1970: 1.234)

        let data = try AgentStatusMessageEncoder.encode(
            snapshot,
            screenTimeoutOnBattery: .fiveMinutes
        )

        #expect(Array(data.suffix(10)) == [5, 0, 0, 0, 4, 210, 0xFF, 0xFF, 0xFF, 0xFF])
    }

    @Test("Encodes separate power timeouts and reset countdowns")
    func encodesPowerTimeoutsAndResetCountdowns() throws {
        var snapshot = AgentSnapshot.idle
        let now = Date(timeIntervalSince1970: 1_000)
        snapshot.fiveHourResetsAt = now.addingTimeInterval(134 * 60)
        snapshot.weeklyResetsAt = now.addingTimeInterval(4_800 * 60)

        let data = try AgentStatusMessageEncoder.encode(
            snapshot,
            screenTimeoutOnBattery: .fiveMinutes,
            screenTimeoutOnExternalPower: .never,
            now: now
        )

        #expect(Array(data.suffix(10)) == [5, 0, 0, 0, 0, 0, 0x00, 0x86, 0x12, 0xC0])
        #expect(UsageResetCountdown.display(minutes: 134, weekly: false) == "2H14m")
        #expect(UsageResetCountdown.display(minutes: 121, weekly: false) == "2H1m")
        #expect(UsageResetCountdown.display(minutes: 4_800, weekly: true) == "3D8H")
        #expect(UsageResetCountdown.display(minutes: 1_112, weekly: true) == "18H32m")
        #expect(UsageResetCountdown.display(minutes: 48, weekly: false) == "48m")
        #expect(UsageResetCountdown.display(minutes: 0, weekly: false) == "0m")
        #expect(UsageResetCountdown.display(minutes: 60, weekly: false) == "1H0m")
    }

    @Test("Unknown metrics use the sentinel value")
    func unknownMetricsUseSentinel() throws {
        let data = try AgentStatusMessageEncoder.encode(.idle)
        #expect(Array(Array(data)[4...6]) == [0xFF, 0xFF, 0xFF])
    }

    @Test("Encodes cancelled and failed terminal states")
    func encodesTerminalFailureStates() throws {
        var snapshot = AgentSnapshot.idle
        snapshot.state = .cancelled
        #expect(try AgentStatusMessageEncoder.encode(snapshot)[2] == 5)
        snapshot.state = .failed
        #expect(try AgentStatusMessageEncoder.encode(snapshot)[2] == 6)
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

@Suite("Claude usage refresher")
struct ClaudeUsageRefresherTests {
    @Test("Uses the isolated non-interactive Claude usage command")
    func usesSafeUsageCommand() {
        #expect(ClaudeCLIUsageRefresher.arguments == [
            "--safe-mode",
            "--no-session-persistence",
            "--tools", "",
            "--max-turns", "1",
            "--output-format", "json",
            "-p", "/usage",
        ])
    }

    @Test("Accepts only zero-inference usage output")
    func parsesVerifiedUsageOutput() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let response = try jsonData([
            "subtype": "success",
            "is_error": false,
            "num_turns": 0,
            "total_cost_usd": 0,
            "usage": [
                "input_tokens": 0,
                "cache_creation_input_tokens": 0,
                "cache_read_input_tokens": 0,
                "output_tokens": 0,
            ],
            "modelUsage": [String: Any](),
            "result": """
                Current session: 45% used · resets Aug 12 at 2:40pm
                Current week (all models): 25% used · resets Aug 18 at 11am
                """,
        ])

        let snapshot = ClaudeCLIUsageRefresher.parseVerifiedResponse(response, now: now)
        #expect(snapshot?.fiveHourRemaining == 55)
        #expect(snapshot?.weeklyRemaining == 75)
        #expect(snapshot?.updatedAt == now)
    }

    @Test("Rejects usage output that consumed model tokens")
    func rejectsInferenceOutput() throws {
        let response = try jsonData([
            "subtype": "success",
            "is_error": false,
            "num_turns": 1,
            "total_cost_usd": 0.01,
            "usage": [
                "input_tokens": 10,
                "cache_creation_input_tokens": 0,
                "cache_read_input_tokens": 0,
                "output_tokens": 5,
            ],
            "modelUsage": ["claude": ["inputTokens": 10]],
            "result": "Current session: 45% used",
        ])

        #expect(ClaudeCLIUsageRefresher.parseVerifiedResponse(response) == nil)
    }

    @Test("Reads only the Claude cache fetch timestamp")
    func readsCacheTimestamp() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("core-s3-claude-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try jsonData([
            "cachedUsageUtilization": ["fetchedAtMs": 1_234_567],
            "oauthAccount": ["accessToken": "must-not-be-read"],
        ]).write(to: url)

        #expect(ClaudeCLIUsageRefresher.cachedFetchedAtMs(at: url) == 1_234_567)
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
        let claudeSessionsURL = home.appendingPathComponent(".claude/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeSessionsURL, withIntermediateDirectories: true)
        try jsonData([
            "sessionId": "claude-test-session",
            "name": "core-s3-7a",
            "nameSource": "derived",
        ]).write(to: claudeSessionsURL.appendingPathComponent("12345.json"))
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
        let stateURL = support.appendingPathComponent("state/claude-session-claude-test-session.json")
        let hookState = try jsonObject(at: stateURL)
        #expect(hookState["title"] as? String == "core-s3")
        #expect(hookState["state"] as? String == "waiting_authorization")
        try runHook(
            scriptURL: hookScript,
            source: "claude",
            payload: [
                "session_id": "claude-test-session",
                "hook_event_name": "PermissionRequest",
                "tool_name": "ExitPlanMode",
                "cwd": "/tmp/core-s3",
            ]
        )
        let replyState = try jsonObject(at: stateURL)
        #expect(replyState["state"] as? String == "waiting_reply")
        try runHook(
            scriptURL: hookScript,
            source: "claude",
            payload: [
                "session_id": "claude-test-session",
                "hook_event_name": "StopFailure",
                "error": "server_error",
                "last_assistant_message": "API Error: Connection lost mid-response",
            ]
        )
        let failureState = try jsonObject(at: stateURL)
        #expect(failureState["state"] as? String == "failed")
        try runHook(
            scriptURL: hookScript,
            source: "claude-status",
            payload: [
                "session_id": "claude-test-session",
                "session_name": "状态栏旧标题",
                "model": ["id": "claude-opus-5", "display_name": "Opus 5"],
                "effort": ["level": "xhigh"],
                "context_window": ["used_percentage": 37],
                "rate_limits": [
                    "five_hour": ["used_percentage": 12, "resets_at": 2_000_000_000],
                    "seven_day": ["used_percentage": 34, "resets_at": 2_000_300_000],
                ],
            ]
        )
        let state = try jsonObject(at: stateURL)
        #expect(state["state"] as? String == "failed")

        let claudeProjectsURL = root.appendingPathComponent("claude-projects/project", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeProjectsURL, withIntermediateDirectories: true)
        let transcriptLines = [
            jsonText(["type": "ai-title", "sessionId": "claude-test-session", "aiTitle": "实现 CoreS3 状态显示"]),
            jsonText(["type": "ai-title", "sessionId": "claude-test-session", "aiTitle": "完善 CoreS3 状态显示"]),
        ]
        try transcriptLines.joined(separator: "\n").write(
            to: claudeProjectsURL.appendingPathComponent("claude-test-session.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let monitor = AgentStatusMonitor(
            stateDirectoryURL: support.appendingPathComponent("state"),
            codexSessionsURL: root.appendingPathComponent("no-codex-sessions"),
            claudeSessionsURL: claudeSessionsURL,
            claudeProjectsURL: root.appendingPathComponent("claude-projects"),
            claudeConfigurationURL: root.appendingPathComponent("no-claude-configuration"),
            codexSessionIndexURL: root.appendingPathComponent("no-codex-index")
        )
        monitor.selectedSource = .claude
        var snapshots: [AgentSnapshot] = []
        monitor.onSnapshots = { snapshots = $0 }
        monitor.refresh()
        #expect(snapshots.first?.title == "完善 CoreS3 状态显示")
        #expect(snapshots.first?.modelName == "Opus 5")
        #expect(snapshots.first?.effort == "xhigh")
        #expect(snapshots.first?.fiveHourRemaining == 88)
        #expect(snapshots.first?.weeklyRemaining == 66)
        #expect(snapshots.first?.contextUsed == 37)
        #expect(snapshots.first?.fiveHourResetsAt == Date(timeIntervalSince1970: 2_000_000_000))
        #expect(snapshots.first?.weeklyResetsAt == Date(timeIntervalSince1970: 2_000_300_000))

        try jsonData([
            "sessionId": "claude-test-session",
            "name": "用户指定标题",
            "nameSource": "custom",
        ]).write(to: claudeSessionsURL.appendingPathComponent("12345.json"))
        monitor.refresh()
        #expect(snapshots.first?.title == "用户指定标题")

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
            try rolloutRecord(outerType: "session_meta", payload: [
                "id": "codex-test-session",
                "cwd": "/tmp/core-s3-companion",
            ]),
            try rolloutRecord(outerType: "turn_context", payload: [
                "model": "gpt-5.6-sol",
                "effort": "high",
            ]),
            try rolloutLine(type: "user_message", payload: ["message": "This must not become the title"]),
            try rolloutLine(type: "request_user_input", payload: ["prompt": "Choose a layout"]),
            try rolloutLine(type: "token_count", payload: [
                "rate_limits": [
                    "primary": [
                        "used_percent": 32,
                        "window_minutes": 10_080,
                        "resets_at": 2_000_300_000,
                    ],
                ],
                "info": [
                    "total_token_usage": ["total_tokens": 9_999_999],
                    "last_token_usage": ["total_tokens": 61_000],
                    "model_context_window": 100_000,
                ],
            ]),
        ]
        try lines.joined(separator: "\n").write(to: rollout, atomically: true, encoding: .utf8)
        let sessionIndex = root.appendingPathComponent("session_index.jsonl")
        try rolloutRecord(outerType: nil, payload: [
            "id": "codex-test-session",
            "thread_name": "菜单栏状态实现",
            "updated_at": isoTimestamp(.now),
        ]).write(to: sessionIndex, atomically: true, encoding: .utf8)

        let monitor = AgentStatusMonitor(
            stateDirectoryURL: states,
            codexSessionsURL: root.appendingPathComponent("sessions"),
            claudeSessionsURL: root.appendingPathComponent("no-claude-sessions"),
            claudeProjectsURL: root.appendingPathComponent("no-claude-projects"),
            claudeConfigurationURL: root.appendingPathComponent("no-claude-configuration"),
            codexSessionIndexURL: sessionIndex
        )
        monitor.selectedSource = .codex
        var snapshot: AgentSnapshot?
        monitor.onSnapshots = { snapshot = $0.first }
        monitor.refresh()

        #expect(snapshot?.source == .codex)
        #expect(snapshot?.state == .waitingReply)
        #expect(snapshot?.title == "菜单栏状态实现")
        #expect(snapshot?.modelName == "gpt-5.6-sol")
        #expect(snapshot?.effort == "high")
        #expect(snapshot?.fiveHourRemaining == nil)
        #expect(snapshot?.weeklyRemaining == 68)
        #expect(snapshot?.contextUsed == 61)
        #expect(snapshot?.weeklyResetsAt == Date(timeIntervalSince1970: 2_000_300_000))
    }

    @Test("Codex resumes running after a request-user-input response")
    func codexReplyResponseResumesRunning() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("core-s3-codex-reply-\(UUID().uuidString)", isDirectory: true)
        let states = root.appendingPathComponent("state", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions/2026/08/17", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: states, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        let rollout = sessions.appendingPathComponent("rollout-reply.jsonl")
        let lines = [
            try rolloutRecord(outerType: "session_meta", payload: [
                "id": "codex-reply-session",
                "cwd": "/tmp/core-s3-companion",
            ]),
            try rolloutLine(type: "task_started", payload: [:]),
            try rolloutRecord(outerType: "response_item", payload: [
                "type": "function_call",
                "name": "request_user_input",
                "call_id": "call-question",
            ]),
            try rolloutRecord(outerType: "response_item", payload: [
                "type": "function_call_output",
                "call_id": "call-question",
                "output": "{\"answer\":\"continue\"}",
            ]),
        ]
        try lines.joined(separator: "\n").write(to: rollout, atomically: true, encoding: .utf8)

        let monitor = AgentStatusMonitor(
            stateDirectoryURL: states,
            codexSessionsURL: root.appendingPathComponent("sessions"),
            claudeSessionsURL: root.appendingPathComponent("no-claude-sessions"),
            claudeProjectsURL: root.appendingPathComponent("no-claude-projects"),
            claudeConfigurationURL: root.appendingPathComponent("no-claude-configuration"),
            codexSessionIndexURL: root.appendingPathComponent("no-session-index.jsonl")
        )
        monitor.selectedSource = .codex
        var snapshot: AgentSnapshot?
        monitor.onSnapshots = { snapshot = $0.first }
        monitor.refresh()

        #expect(snapshot?.source == .codex)
        #expect(snapshot?.state == .running)
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
            codexSessionsURL: root.appendingPathComponent("no-codex"),
            claudeSessionsURL: root.appendingPathComponent("no-claude-sessions"),
            claudeProjectsURL: root.appendingPathComponent("no-claude-projects"),
            claudeConfigurationURL: root.appendingPathComponent("no-claude-configuration"),
            codexSessionIndexURL: root.appendingPathComponent("no-codex-index")
        )
        monitor.selectedSource = .claude
        var snapshots: [AgentSnapshot] = []
        monitor.onSnapshots = { snapshots = $0 }
        monitor.refresh()

        #expect(snapshots.map(\.sessionID) == ["session-auth", "session-running"])
    }

    @Test("Uses the configured default tool only when no session is active")
    func usesConfiguredIdleFallback() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("core-s3-default-tool-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let now = Date().timeIntervalSince1970
        try jsonData([
            "sessionID": "claude-idle",
            "state": "idle",
            "title": "Claude idle",
            "updatedAt": now,
        ]).write(to: root.appendingPathComponent("claude-session-idle.json"))
        try jsonData([
            "sessionID": "codex-idle",
            "state": "idle",
            "title": "Codex idle",
            "updatedAt": now - 60,
        ]).write(to: root.appendingPathComponent("codex-session-idle.json"))

        let monitor = AgentStatusMonitor(
            stateDirectoryURL: root,
            codexSessionsURL: root.appendingPathComponent("no-rollouts"),
            claudeSessionsURL: root.appendingPathComponent("no-claude-sessions"),
            claudeProjectsURL: root.appendingPathComponent("no-claude-projects"),
            claudeConfigurationURL: root.appendingPathComponent("no-claude-configuration"),
            codexSessionIndexURL: root.appendingPathComponent("no-codex-index")
        )
        monitor.selectedSource = .automatic
        monitor.defaultTool = .codex
        var snapshots: [AgentSnapshot] = []
        monitor.onSnapshots = { snapshots = $0 }
        monitor.refresh()

        #expect(snapshots.first?.sessionID == "codex-idle")
        #expect(snapshots.first?.source == .codex)
    }

    @Test("Reads Claude quotas and model-specific context from local caches")
    func readsClaudeCachedUsageAndTranscriptContext() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("core-s3-claude-usage-\(UUID().uuidString)", isDirectory: true)
        let states = root.appendingPathComponent("state", isDirectory: true)
        let projects = root.appendingPathComponent("projects/workspace", isDirectory: true)
        let configuration = root.appendingPathComponent(".claude.json")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: states, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)

        let sessionID = "claude-cached-session"
        try jsonData([
            "sessionID": sessionID,
            "state": "running",
            "title": "Claude usage",
            "updatedAt": Date().timeIntervalSince1970,
        ]).write(to: states.appendingPathComponent("claude-session-cached.json"))
        try jsonData([
            "cachedUsageUtilization": [
                "fetchedAtMs": Date().timeIntervalSince1970 * 1_000,
                "utilization": [
                    "five_hour": ["utilization": 25],
                    "seven_day": ["utilization": 40],
                ],
            ],
        ]).write(to: configuration)
        let transcriptLines = [
            jsonText([
                "type": "ai-title",
                "sessionId": sessionID,
                "aiTitle": "实现 Claude 会话标题读取",
            ]),
            jsonText([
                "type": "assistant",
                "message": [
                    "model": "claude-opus-5",
                    "usage": [
                        "input_tokens": 1_000,
                        "cache_creation_input_tokens": 49_000,
                        "cache_read_input_tokens": 200_000,
                        "output_tokens": 50_000,
                    ],
                ],
            ]),
        ]
        try transcriptLines.joined(separator: "\n")
            .write(
                to: projects.appendingPathComponent("\(sessionID).jsonl"),
                atomically: true,
                encoding: .utf8
            )
        let transcript = ClaudeTranscriptReader.read(
            from: projects.appendingPathComponent("\(sessionID).jsonl")
        )
        #expect(transcript?.aiTitle == "实现 Claude 会话标题读取")
        #expect(transcript?.contextUsed == 30)

        let monitor = AgentStatusMonitor(
            stateDirectoryURL: states,
            codexSessionsURL: root.appendingPathComponent("no-codex"),
            claudeSessionsURL: root.appendingPathComponent("no-claude-sessions"),
            claudeProjectsURL: root.appendingPathComponent("projects"),
            claudeConfigurationURL: configuration,
            codexSessionIndexURL: root.appendingPathComponent("no-codex-index")
        )
        monitor.selectedSource = .claude
        var snapshot: AgentSnapshot?
        monitor.onSnapshots = { snapshot = $0.first }
        monitor.refresh()

        #expect(snapshot?.title == "实现 Claude 会话标题读取")
        #expect(snapshot?.modelName == "claude-opus-5")
        #expect(snapshot?.fiveHourRemaining == 75)
        #expect(snapshot?.weeklyRemaining == 60)
        #expect(snapshot?.contextUsed == 30)
    }

    @Test("Marks a stopped Claude turn as cancelled after the user rejects a plan")
    func detectsCancelledClaudePlan() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("core-s3-claude-rejection-\(UUID().uuidString)", isDirectory: true)
        let states = root.appendingPathComponent("state", isDirectory: true)
        let projects = root.appendingPathComponent("projects/workspace", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: states, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)

        let sessionID = "claude-rejected-plan"
        let permissionAt = Date().addingTimeInterval(-5)
        let rejectedAt = permissionAt.addingTimeInterval(2)
        let stoppedAt = rejectedAt.addingTimeInterval(1)
        try jsonData([
            "sessionID": sessionID,
            "state": "completed",
            "title": "Claude plan",
            "updatedAt": stoppedAt.timeIntervalSince1970,
        ]).write(to: states.appendingPathComponent("claude-session-plan.json"))
        let transcript = [
            jsonText([
                "type": "user",
                "timestamp": isoTimestamp(rejectedAt),
                "toolUseResult": "User rejected tool use",
            ]),
            jsonText([
                "type": "user",
                "timestamp": isoTimestamp(rejectedAt.addingTimeInterval(0.01)),
                "message": ["content": "[Request interrupted by user for tool use]"],
            ]),
        ].joined(separator: "\n")
        try transcript.write(
            to: projects.appendingPathComponent("\(sessionID).jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let monitor = AgentStatusMonitor(
            stateDirectoryURL: states,
            codexSessionsURL: root.appendingPathComponent("no-codex"),
            claudeSessionsURL: root.appendingPathComponent("no-claude-sessions"),
            claudeProjectsURL: root.appendingPathComponent("projects"),
            claudeConfigurationURL: root.appendingPathComponent("no-claude-configuration"),
            codexSessionIndexURL: root.appendingPathComponent("no-codex-index")
        )
        monitor.selectedSource = .claude
        var snapshot: AgentSnapshot?
        monitor.onSnapshots = { snapshot = $0.first }
        monitor.refresh()

        #expect(snapshot?.state == .cancelled)
        #expect(abs((snapshot?.updatedAt?.timeIntervalSince1970 ?? 0) - stoppedAt.timeIntervalSince1970) < 0.01)
    }

    @Test("Clears a running Claude state after the user interrupts the request")
    func detectsInterruptedClaudeRequest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("core-s3-claude-interrupt-\(UUID().uuidString)", isDirectory: true)
        let states = root.appendingPathComponent("state", isDirectory: true)
        let projects = root.appendingPathComponent("projects/workspace", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: states, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)

        let sessionID = "claude-interrupted-request"
        let startedAt = Date().addingTimeInterval(-5)
        let interruptedAt = startedAt.addingTimeInterval(2)
        try jsonData([
            "sessionID": sessionID,
            "state": "running",
            "title": "Claude request",
            "updatedAt": startedAt.timeIntervalSince1970,
        ]).write(to: states.appendingPathComponent("claude-session-interrupted.json"))
        try jsonText([
            "type": "user",
            "timestamp": isoTimestamp(interruptedAt),
            "message": [
                "role": "user",
                "content": [["type": "text", "text": "[Request interrupted by user]"]],
            ],
        ]).write(
            to: projects.appendingPathComponent("\(sessionID).jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let monitor = AgentStatusMonitor(
            stateDirectoryURL: states,
            codexSessionsURL: root.appendingPathComponent("no-codex"),
            claudeSessionsURL: root.appendingPathComponent("no-claude-sessions"),
            claudeProjectsURL: root.appendingPathComponent("projects"),
            claudeConfigurationURL: root.appendingPathComponent("no-claude-configuration"),
            codexSessionIndexURL: root.appendingPathComponent("no-codex-index")
        )
        monitor.selectedSource = .claude
        var snapshot: AgentSnapshot?
        monitor.onSnapshots = { snapshot = $0.first }
        monitor.refresh()

        #expect(snapshot?.state == .cancelled)
        #expect(abs((snapshot?.updatedAt?.timeIntervalSince1970 ?? 0) - interruptedAt.timeIntervalSince1970) < 0.01)
    }

    @Test("Marks a completed Claude hook record as failed from an API error transcript")
    func detectsClaudeAPIErrorFromTranscript() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("core-s3-claude-api-error-\(UUID().uuidString)", isDirectory: true)
        let states = root.appendingPathComponent("state", isDirectory: true)
        let projects = root.appendingPathComponent("projects/workspace", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: states, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)

        let sessionID = "claude-api-error"
        let errorAt = Date().addingTimeInterval(-2)
        try jsonData([
            "sessionID": sessionID,
            "state": "completed",
            "title": "Claude API request",
            "updatedAt": errorAt.addingTimeInterval(1).timeIntervalSince1970,
        ]).write(to: states.appendingPathComponent("claude-session-api-error.json"))
        try jsonText([
            "type": "assistant",
            "timestamp": isoTimestamp(errorAt),
            "isApiErrorMessage": true,
            "error": "server_error",
            "message": [
                "model": "<synthetic>",
                "content": [["type": "text", "text": "API Error: Connection lost mid-response"]],
            ],
        ]).write(
            to: projects.appendingPathComponent("\(sessionID).jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let monitor = AgentStatusMonitor(
            stateDirectoryURL: states,
            codexSessionsURL: root.appendingPathComponent("no-codex"),
            claudeSessionsURL: root.appendingPathComponent("no-claude-sessions"),
            claudeProjectsURL: root.appendingPathComponent("projects"),
            claudeConfigurationURL: root.appendingPathComponent("no-claude-configuration"),
            codexSessionIndexURL: root.appendingPathComponent("no-codex-index")
        )
        monitor.selectedSource = .claude
        var snapshot: AgentSnapshot?
        monitor.onSnapshots = { snapshot = $0.first }
        monitor.refresh()

        #expect(snapshot?.state == .failed)
    }

    @Test("Prefers verified CLI usage over a newer stale status-line file")
    func prefersVerifiedCLIUsage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("core-s3-claude-cli-\(UUID().uuidString)", isDirectory: true)
        let states = root.appendingPathComponent("state", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: states, withIntermediateDirectories: true)
        let now = Date()
        try jsonData([
            "sessionID": "claude-cli-session",
            "state": "running",
            "title": "Claude CLI refresh",
            "updatedAt": now.timeIntervalSince1970,
        ]).write(to: states.appendingPathComponent("claude-session-cli.json"))
        try jsonData([
            "fiveHourUsed": 10,
            "weeklyUsed": 20,
            "updatedAt": now.addingTimeInterval(60).timeIntervalSince1970,
        ]).write(to: states.appendingPathComponent("claude-usage.json"))

        let refresher = MockClaudeUsageRefresher(outcome: .commandOutput(
            ClaudeUsageRefreshSnapshot(
                fiveHourRemaining: 55,
                weeklyRemaining: 75,
                updatedAt: now
            )
        ))
        let monitor = AgentStatusMonitor(
            stateDirectoryURL: states,
            codexSessionsURL: root.appendingPathComponent("no-codex"),
            claudeSessionsURL: root.appendingPathComponent("no-claude-sessions"),
            claudeProjectsURL: root.appendingPathComponent("no-claude-projects"),
            claudeConfigurationURL: root.appendingPathComponent("no-claude-configuration"),
            codexSessionIndexURL: root.appendingPathComponent("no-codex-index"),
            claudeUsageRefresher: refresher,
            currentDate: { now }
        )
        monitor.selectedSource = .claude
        var snapshot: AgentSnapshot?
        monitor.onSnapshots = { snapshot = $0.first }
        monitor.start()
        defer { monitor.stop() }

        #expect(refresher.callCount == 1)
        #expect(snapshot?.fiveHourRemaining == 55)
        #expect(snapshot?.weeklyRemaining == 75)
    }

    @Test("Uses explicit Claude model context windows")
    func usesExplicitClaudeModelContextWindows() {
        #expect(ClaudeModelContextWindow.tokens(for: "claude-opus-5") == 1_000_000)
        #expect(ClaudeModelContextWindow.tokens(for: "claude-opus-4.7-20260801") == 1_000_000)
        #expect(ClaudeModelContextWindow.tokens(for: "claude-sonnet-4-6") == 1_000_000)
        #expect(ClaudeModelContextWindow.tokens(for: "claude-haiku-4-5") == 200_000)
        #expect(ClaudeModelContextWindow.tokens(for: "claude-sonnet-4.5") == 200_000)
        #expect(ClaudeModelContextWindow.tokens(for: "claude-future-unknown") == nil)
    }
}

@Suite("Companion view model")
struct CompanionViewModelTests {
    @Test("Migrates the legacy timeout to battery and defaults external power to never")
    func migratesPowerAwareDisplayTimeouts() {
        let suiteName = "CoreS3CompanionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(10, forKey: "displaySleepTimeoutMinutes")

        let preferences = UserDefaultsAgentPreferenceStore(defaults: defaults)
        #expect(preferences.displaySleepTimeoutOnBattery == .tenMinutes)
        #expect(preferences.displaySleepTimeoutOnExternalPower == .never)
    }

    @Test("Persists the configured default tool")
    func persistsDefaultTool() {
        let preferences = MemoryAgentPreferenceStore()
        let model = makeModel(preferenceStore: preferences)

        #expect(model.defaultAgentTool == .claude)
        model.defaultAgentTool = .codex

        #expect(preferences.defaultTool == .codex)
    }

    @Test("Persists and sends the configured display timeout")
    func persistsAndSendsDisplayTimeout() throws {
        let preferences = MemoryAgentPreferenceStore()
        let transport = MockBLETransport()
        let monitor = MockAgentStatusMonitor()
        let model = makeModel(
            transport: transport,
            monitor: monitor,
            preferenceStore: preferences
        )
        transport.onStateChange?(.connected(UUID()))
        monitor.onSnapshots?([.idle])

        model.displaySleepTimeoutOnBattery = .tenMinutes

        #expect(preferences.displaySleepTimeoutOnBattery == .tenMinutes)
        let expected = try AgentStatusMessageEncoder.encode(
            .idle,
            screenTimeoutOnBattery: .tenMinutes,
            screenTimeoutOnExternalPower: .never
        )
        #expect(transport.sentPackets.last == expected)

        model.displaySleepTimeoutOnExternalPower = .fifteenMinutes
        #expect(preferences.displaySleepTimeoutOnExternalPower == .fifteenMinutes)
        let poweredExpected = try AgentStatusMessageEncoder.encode(
            .idle,
            screenTimeoutOnBattery: .tenMinutes,
            screenTimeoutOnExternalPower: .fifteenMinutes
        )
        #expect(transport.sentPackets.last == poweredExpected)
    }

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

    @Test("Suppresses unchanged snapshots until the BLE heartbeat is due")
    func suppressesUnchangedSnapshotsUntilHeartbeat() {
        let transport = MockBLETransport()
        let monitor = MockAgentStatusMonitor()
        var now = Date(timeIntervalSince1970: 1_000)
        let model = makeModel(
            transport: transport,
            monitor: monitor,
            currentDate: { now }
        )
        var snapshot = AgentSnapshot(
            source: .claude,
            state: .running,
            title: "Heartbeat",
            fiveHourRemaining: 80,
            weeklyRemaining: 70,
            contextUsed: 20,
            updatedAt: now
        )
        transport.onStateChange?(.connected(UUID()))

        monitor.onSnapshots?([snapshot])
        monitor.onSnapshots?([snapshot])
        #expect(transport.sentPackets.count == 1)

        snapshot.updatedAt = now.addingTimeInterval(1)
        monitor.onSnapshots?([snapshot])
        #expect(transport.sentPackets.count == 1)

        now.addTimeInterval(14)
        monitor.onSnapshots?([snapshot])
        #expect(transport.sentPackets.count == 1)

        now.addTimeInterval(1)
        monitor.onSnapshots?([snapshot])
        #expect(transport.sentPackets.count == 2)
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
            state: .running,
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

    @Test("Attention states preempt and pause session rotation")
    func attentionStatesPreemptAndPauseRotation() {
        #expect(AgentRunState.waitingAuthorization.requiresUserAttention)
        #expect(AgentRunState.waitingReply.requiresUserAttention)
        #expect(!AgentRunState.running.requiresUserAttention)
        #expect(!AgentRunState.cancelled.requiresUserAttention)
        #expect(!AgentRunState.failed.requiresUserAttention)

        let transport = MockBLETransport()
        let monitor = MockAgentStatusMonitor()
        let model = makeModel(transport: transport, monitor: monitor)
        transport.onStateChange?(.connected(UUID()))
        let running = AgentSnapshot(
            sessionID: "running",
            source: .claude,
            state: .running,
            title: "普通会话",
            fiveHourRemaining: nil,
            weeklyRemaining: nil,
            contextUsed: nil,
            updatedAt: .now
        )
        var authorization = AgentSnapshot(
            sessionID: "authorization",
            source: .codex,
            state: .waitingAuthorization,
            title: "等待授权",
            fiveHourRemaining: nil,
            weeklyRemaining: nil,
            contextUsed: nil,
            updatedAt: .now
        )

        monitor.onSnapshots?([running])
        monitor.onSnapshots?([authorization, running])
        #expect(model.agentSnapshot.sessionID == authorization.sessionID)

        model.rotateSession()
        #expect(model.agentSnapshot.sessionID == authorization.sessionID)

        authorization.state = .running
        monitor.onSnapshots?([authorization, running])
        model.rotateSession()
        #expect(model.agentSnapshot.sessionID == running.sessionID)
    }
}

private func makeModel(
    transport: MockBLETransport = MockBLETransport(),
    monitor: MockAgentStatusMonitor = MockAgentStatusMonitor(),
    pairedStore: MemoryPairedDeviceStore = MemoryPairedDeviceStore(),
    preferenceStore: MemoryAgentPreferenceStore = MemoryAgentPreferenceStore(),
    currentDate: @escaping () -> Date = Date.init
) -> CompanionViewModel {
    CompanionViewModel(
        transport: transport,
        monitor: monitor,
        pairedDeviceStore: pairedStore,
        preferenceStore: preferenceStore,
        integrationManager: MockAgentIntegrationManager(),
        currentDate: currentDate
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
    var defaultTool: DefaultAgentTool = .claude
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
    var defaultTool: DefaultAgentTool = .claude
    var displaySleepTimeoutOnBattery: DisplaySleepTimeout = .never
    var displaySleepTimeoutOnExternalPower: DisplaySleepTimeout = .never
}

private final class MockAgentIntegrationManager: AgentIntegrationManaging {
    func status(for kind: AgentIntegrationKind) -> AgentIntegrationStatus {
        AgentIntegrationStatus(kind: kind, isInstalled: false, detail: "", configPath: "")
    }
    func install(_ kind: AgentIntegrationKind) throws {}
    func uninstall(_ kind: AgentIntegrationKind) throws {}
}

private final class MockClaudeUsageRefresher: ClaudeUsageRefreshing {
    private let outcome: ClaudeUsageRefreshOutcome?
    private(set) var callCount = 0

    init(outcome: ClaudeUsageRefreshOutcome?) {
        self.outcome = outcome
    }

    func refresh(
        configurationURL: URL,
        completion: @escaping (ClaudeUsageRefreshOutcome?) -> Void
    ) {
        callCount += 1
        completion(outcome)
    }
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
    return try rolloutRecord(outerType: "event_msg", payload: eventPayload)
}

private func rolloutRecord(outerType: String?, payload: [String: Any]) throws -> String {
    var object: [String: Any] = [
        "timestamp": isoTimestamp(.now),
        "payload": payload,
    ]
    if let outerType {
        object["type"] = outerType
    } else {
        object = payload
    }
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
