import Foundation

protocol AgentIntegrationManaging: AnyObject {
    func status(for kind: AgentIntegrationKind) -> AgentIntegrationStatus
    func install(_ kind: AgentIntegrationKind) throws
    func uninstall(_ kind: AgentIntegrationKind) throws
}

enum AgentIntegrationError: LocalizedError {
    case invalidJSON(String)
    case invalidConfiguration(String)

    var errorDescription: String? {
        switch self {
        case let .invalidJSON(path): "配置文件不是有效的 JSON：\(path)"
        case let .invalidConfiguration(message): message
        }
    }
}

final class AgentIntegrationManager: AgentIntegrationManaging {
    private let homeURL: URL
    private let applicationSupportURL: URL
    private let fileManager: FileManager

    private let originalClaudeStatusLineKey = "_coreS3CompanionOriginalStatusLine"
    private let managedScriptNeedle = "core-s3-agent-hook.js"
    private let managedAssetMarker = "core-s3-hook-schema-v2"

    init(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationSupportURL: URL = AgentStatusMonitor.defaultApplicationSupportURL,
        fileManager: FileManager = .default
    ) {
        self.homeURL = homeURL
        self.applicationSupportURL = applicationSupportURL
        self.fileManager = fileManager
    }

    func status(for kind: AgentIntegrationKind) -> AgentIntegrationStatus {
        switch kind {
        case .claude:
            let url = claudeSettingsURL
            let settings = (try? loadJSONObject(at: url)) ?? [:]
            let hooksInstalled = containsManagedHook(in: settings["hooks"] as? [String: Any] ?? [:])
            let statusLine = settings["statusLine"] as? [String: Any]
            let statusLineInstalled = statusLine?["command"] as? String == claudeStatusLineScriptURL.path
            let installed = hooksInstalled && statusLineInstalled && managedAssetsAreCurrent
            return AgentIntegrationStatus(
                kind: kind,
                isInstalled: installed,
                detail: installed ? "Hooks、额度和 Context 采集已启用" : "需要安装或更新 Claude 采集器",
                configPath: url.path
            )
        case .codex:
            let hooksURL = codexHooksURL
            let hooks = (try? loadJSONObject(at: hooksURL)) ?? [:]
            let installed = containsManagedHook(in: hooks["hooks"] as? [String: Any] ?? [:])
                && managedAssetsAreCurrent
            return AgentIntegrationStatus(
                kind: kind,
                isInstalled: installed,
                detail: installed ? "Hooks 已启用；额度从本地 rollout 被动读取" : "需要安装 Codex hooks",
                configPath: codexConfigURL.path
            )
        }
    }

    func install(_ kind: AgentIntegrationKind) throws {
        try ensureSharedAssets()
        switch kind {
        case .claude:
            try installClaude()
        case .codex:
            try installCodex()
        }
    }

    func uninstall(_ kind: AgentIntegrationKind) throws {
        switch kind {
        case .claude:
            try uninstallClaude()
        case .codex:
            try uninstallCodex()
        }
    }

    private var binDirectoryURL: URL {
        applicationSupportURL.appendingPathComponent("bin", isDirectory: true)
    }

    private var stateDirectoryURL: URL {
        applicationSupportURL.appendingPathComponent("state", isDirectory: true)
    }

    private var hookScriptURL: URL {
        binDirectoryURL.appendingPathComponent(managedScriptNeedle)
    }

    private var claudeStatusLineScriptURL: URL {
        binDirectoryURL.appendingPathComponent("core-s3-claude-statusline")
    }

    private var claudeStatusLineDelegateURL: URL {
        binDirectoryURL.appendingPathComponent("core-s3-claude-statusline-delegate")
    }

    private var claudeSettingsURL: URL {
        homeURL.appendingPathComponent(".claude/settings.json")
    }

    private var codexHooksURL: URL {
        homeURL.appendingPathComponent(".codex/hooks.json")
    }

    private var codexConfigURL: URL {
        homeURL.appendingPathComponent(".codex/config.toml")
    }

    private var managedAssetsAreCurrent: Bool {
        guard let contents = try? String(contentsOf: hookScriptURL, encoding: .utf8) else {
            return false
        }
        return contents.contains(managedAssetMarker)
    }

    private func installClaude() throws {
        try fileManager.createDirectory(
            at: claudeSettingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var settings = try loadJSONObject(at: claudeSettingsURL)
        let hookCommand = managedHookCommand(source: "claude")
        settings["hooks"] = mergedHooks(
            existing: settings["hooks"] as? [String: Any] ?? [:],
            eventSpecs: [
                ("SessionStart", nil),
                ("SessionEnd", nil),
                ("UserPromptSubmit", nil),
                ("PreToolUse", "*"),
                ("PostToolUse", "*"),
                ("PermissionRequest", "*"),
                ("Notification", "*"),
                ("Stop", nil),
                ("StopFailure", nil),
            ],
            command: hookCommand
        )

        let currentStatusLine = settings["statusLine"] as? [String: Any]
        let currentCommand = currentStatusLine?["command"] as? String
        if currentCommand != claudeStatusLineScriptURL.path,
           settings[originalClaudeStatusLineKey] == nil,
           let currentStatusLine {
            settings[originalClaudeStatusLineKey] = currentStatusLine
        }

        let originalCommand = (settings[originalClaudeStatusLineKey] as? [String: Any])?["command"] as? String
        try writeClaudeStatusLineScripts(originalCommand: originalCommand)
        settings["statusLine"] = [
            "type": "command",
            "command": claudeStatusLineScriptURL.path,
            "padding": 0,
            "refreshInterval": 1,
        ]
        try writeJSONObject(settings, to: claudeSettingsURL, backingUpExisting: true)
    }

    private func uninstallClaude() throws {
        guard fileManager.fileExists(atPath: claudeSettingsURL.path) else { return }
        var settings = try loadJSONObject(at: claudeSettingsURL)
        settings["hooks"] = removingManagedHooks(from: settings["hooks"] as? [String: Any] ?? [:])
        if let original = settings[originalClaudeStatusLineKey] {
            settings["statusLine"] = original
            settings.removeValue(forKey: originalClaudeStatusLineKey)
        } else if (settings["statusLine"] as? [String: Any])?["command"] as? String == claudeStatusLineScriptURL.path {
            settings.removeValue(forKey: "statusLine")
        }
        try writeJSONObject(settings, to: claudeSettingsURL, backingUpExisting: true)
    }

    private func installCodex() throws {
        try fileManager.createDirectory(
            at: codexHooksURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var root = try loadJSONObject(at: codexHooksURL)
        root["hooks"] = mergedHooks(
            existing: root["hooks"] as? [String: Any] ?? [:],
            eventSpecs: [
                ("SessionStart", "startup|resume"),
                ("UserPromptSubmit", nil),
                ("PreToolUse", nil),
                ("PostToolUse", nil),
                ("PermissionRequest", nil),
                ("Stop", nil),
            ],
            command: managedHookCommand(source: "codex")
        )
        try writeJSONObject(root, to: codexHooksURL, backingUpExisting: true)

        let existingConfig = (try? String(contentsOf: codexConfigURL, encoding: .utf8)) ?? ""
        let updatedConfig = enablingCodexHooks(in: existingConfig)
        if updatedConfig != existingConfig {
            try backupIfNeeded(codexConfigURL)
            try updatedConfig.write(to: codexConfigURL, atomically: true, encoding: .utf8)
        }
    }

    private func uninstallCodex() throws {
        guard fileManager.fileExists(atPath: codexHooksURL.path) else { return }
        var root = try loadJSONObject(at: codexHooksURL)
        root["hooks"] = removingManagedHooks(from: root["hooks"] as? [String: Any] ?? [:])
        try writeJSONObject(root, to: codexHooksURL, backingUpExisting: true)
        // Keep the hooks feature enabled: another integration may still depend on it.
    }

    private func ensureSharedAssets() throws {
        try fileManager.createDirectory(at: binDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stateDirectoryURL, withIntermediateDirectories: true)
        try Self.jxaHookScript.write(to: hookScriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookScriptURL.path)
    }

    private func writeClaudeStatusLineScripts(originalCommand: String?) throws {
        if let originalCommand, !originalCommand.isEmpty {
            let delegate = "#!/bin/bash\n\(originalCommand)\n"
            try delegate.write(to: claudeStatusLineDelegateURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claudeStatusLineDelegateURL.path)
        } else if fileManager.fileExists(atPath: claudeStatusLineDelegateURL.path) {
            try fileManager.removeItem(at: claudeStatusLineDelegateURL)
        }

        let captureCommand = managedHookCommand(source: "claude-status")
        let delegateBlock: String
        if originalCommand?.isEmpty == false {
            delegateBlock = "printf '%s' \"$input\" | \(shellQuote(claudeStatusLineDelegateURL.path))"
        } else {
            delegateBlock = "printf '[CoreS3] Claude status active\\n'"
        }
        let wrapper = """
        #!/bin/bash
        input=$(cat)
        printf '%s' "$input" | \(captureCommand) >/dev/null 2>&1 || true
        \(delegateBlock)
        """
        try wrapper.write(to: claudeStatusLineScriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claudeStatusLineScriptURL.path)
    }

    private func managedHookCommand(source: String) -> String {
        "/usr/bin/osascript -l JavaScript \(shellQuote(hookScriptURL.path)) \(shellQuote(source)) \(shellQuote(stateDirectoryURL.path)) >/dev/null 2>&1 || true"
    }

    private func mergedHooks(
        existing: [String: Any],
        eventSpecs: [(String, String?)],
        command: String
    ) -> [String: Any] {
        var result = removingManagedHooks(from: existing)
        for (event, matcher) in eventSpecs {
            var groups = result[event] as? [[String: Any]] ?? []
            var group: [String: Any] = [
                "hooks": [[
                    "type": "command",
                    "command": command,
                    "timeout": event == "PermissionRequest" ? 3_600 : 30,
                ]]
            ]
            if let matcher { group["matcher"] = matcher }
            groups.append(group)
            result[event] = groups
        }
        return result
    }

    private func removingManagedHooks(from hooks: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (event, value) in hooks {
            let groups = (value as? [Any] ?? []).compactMap { item -> [String: Any]? in
                guard var group = item as? [String: Any] else { return nil }
                let remaining = (group["hooks"] as? [Any] ?? []).compactMap { hook -> [String: Any]? in
                    guard let hook = hook as? [String: Any] else { return nil }
                    let command = hook["command"] as? String ?? ""
                    return command.contains(managedScriptNeedle) ? nil : hook
                }
                guard !remaining.isEmpty else { return nil }
                group["hooks"] = remaining
                return group
            }
            if !groups.isEmpty { result[event] = groups }
        }
        return result
    }

    private func containsManagedHook(in hooks: [String: Any]) -> Bool {
        hooks.values.contains { value in
            (value as? [Any] ?? []).contains { item in
                guard let group = item as? [String: Any] else { return false }
                return (group["hooks"] as? [Any] ?? []).contains { hook in
                    guard let hook = hook as? [String: Any],
                          let command = hook["command"] as? String else { return false }
                    return command.contains(managedScriptNeedle)
                }
            }
        }
    }

    private func enablingCodexHooks(in contents: String) -> String {
        var lines = contents.components(separatedBy: "\n")
        var inFeatures = false
        var featureLine: Int?
        var insertAfterFeatures: Int?

        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                inFeatures = trimmed == "[features]"
                if inFeatures { insertAfterFeatures = index + 1 }
                continue
            }
            if inFeatures {
                if trimmed.hasPrefix("hooks =") || trimmed.hasPrefix("codex_hooks =") {
                    featureLine = index
                    break
                }
                insertAfterFeatures = index + 1
            }
        }

        if let featureLine {
            lines[featureLine] = "hooks = true"
        } else if let insertAfterFeatures {
            lines.insert("hooks = true", at: insertAfterFeatures)
        } else {
            if !lines.isEmpty, lines.last?.isEmpty == false { lines.append("") }
            lines.append("[features]")
            lines.append("hooks = true")
        }
        return lines.joined(separator: "\n")
    }

    private func loadJSONObject(at url: URL) throws -> [String: Any] {
        guard fileManager.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentIntegrationError.invalidJSON(url.path)
        }
        return object
    }

    private func writeJSONObject(
        _ object: [String: Any],
        to url: URL,
        backingUpExisting: Bool
    ) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if backingUpExisting { try backupIfNeeded(url) }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func backupIfNeeded(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let backupURL = URL(fileURLWithPath: url.path + ".core-s3-companion.backup")
        guard !fileManager.fileExists(atPath: backupURL.path) else { return }
        try fileManager.copyItem(at: url, to: backupURL)
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static let jxaHookScript = #"""
    // core-s3-hook-schema-v2
    ObjC.import('Foundation');

    function readInput() {
      var data = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;
      var text = ObjC.unwrap($.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding));
      if (!text) return {};
      try { return JSON.parse(text); } catch (_) { return {}; }
    }

    function readJSON(path) {
      var data = $.NSData.dataWithContentsOfFile(path);
      if (!data) return {};
      var text = ObjC.unwrap($.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding));
      try { return JSON.parse(text); } catch (_) { return {}; }
    }

    function writeJSON(path, value) {
      var text = $(JSON.stringify(value));
      text.writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null);
    }

    function numberValue(value) {
      if (value === null || value === undefined || value === '') return null;
      var number = Number(value);
      return isFinite(number) ? Math.max(0, Math.min(100, number)) : null;
    }

    function contextValue(payload) {
      var window = payload.context_window || {};
      var direct = numberValue(window.used_percentage);
      if (direct != null) return direct;
      var usage = window.current_usage || {};
      var size = Number(window.context_window_size);
      var input = Number(usage.input_tokens || 0)
        + Number(usage.cache_creation_input_tokens || 0)
        + Number(usage.cache_read_input_tokens || 0);
      return size > 0 ? numberValue(input / size * 100) : null;
    }

    function firstLine(value) {
      return String(value || '').split(/\r?\n/)[0].replace(/\s+/g, ' ').trim().slice(0, 120);
    }

    function sessionID(payload, source) {
      return String(payload.session_id || payload.sessionId || payload.conversation_id || source + '-default');
    }

    function safeSessionID(value) {
      return String(value).replace(/[^A-Za-z0-9._-]/g, '_').slice(0, 96);
    }

    function directoryName(value) {
      var parts = String(value || '').split('/').filter(Boolean);
      return parts.length ? parts[parts.length - 1] : '';
    }

    function run(argv) {
      var mode = String(argv[0] || 'claude');
      var payload = readInput();
      var home = ObjC.unwrap($.NSHomeDirectory());
      var stateDirectory = argv[1] ? String(argv[1]) : home + '/Library/Application Support/CoreS3Companion/state';
      var now = Date.now() / 1000;

      if (mode === 'claude-status') {
        var limits = payload.rate_limits || {};
        var five = limits.five_hour || {};
        var weekly = limits.seven_day || {};
        var id = sessionID(payload, 'claude');
        var sessionPath = stateDirectory + '/claude-session-' + safeSessionID(id) + '.json';
        var session = readJSON(sessionPath);
        var workspace = payload.workspace || {};
        var sessionTitle = firstLine(payload.session_name || session.title || directoryName(workspace.current_dir));
        writeJSON(stateDirectory + '/claude-usage.json', {
          fiveHourUsed: numberValue(five.used_percentage != null ? five.used_percentage : five.utilization),
          weeklyUsed: numberValue(weekly.used_percentage != null ? weekly.used_percentage : weekly.utilization),
          contextUsed: contextValue(payload),
          updatedAt: now
        });
        writeJSON(sessionPath, {
          sessionID: id,
          source: 'claude',
          state: String(session.state || 'idle'),
          title: sessionTitle || 'CLAUDE SESSION',
          contextUsed: contextValue(payload),
          updatedAt: session.updatedAt || now,
          metricsUpdatedAt: now
        });
        return '';
      }

      var source = mode === 'codex' ? 'codex' : 'claude';
      var id = sessionID(payload, source);
      var path = stateDirectory + '/' + source + '-session-' + safeSessionID(id) + '.json';
      var previous = readJSON(path);
      var event = String(payload.hook_event_name || payload.hookEventName || '');
      var state = String(previous.state || 'idle');
      var notification = String(payload.notification_type || payload.subtype || '').toLowerCase();

      if (event === 'SessionStart' || event === 'SessionEnd') state = 'idle';
      if (event === 'UserPromptSubmit' || event === 'PreToolUse' || event === 'PostToolUse' || event === 'PostToolUseFailure') state = 'running';
      if (event === 'PermissionRequest') state = 'waiting_authorization';
      if (event === 'Notification' && notification.indexOf('permission') >= 0) state = 'waiting_authorization';
      if (event === 'Notification' && (notification.indexOf('idle') >= 0 || notification.indexOf('question') >= 0 || notification.indexOf('elicitation') >= 0 || notification.indexOf('away_summary') >= 0)) state = 'waiting_reply';
      if (event === 'Stop' || event === 'StopFailure') state = 'completed';

      var title = String(previous.title || '');
      if (event === 'UserPromptSubmit' && payload.prompt) title = firstLine(payload.prompt);
      if (!title && payload.cwd) title = String(payload.cwd).split('/').pop();
      if (!title) title = source === 'codex' ? 'CODEX SESSION' : 'CLAUDE SESSION';

      var context = contextValue(payload);
      writeJSON(path, {
        sessionID: id,
        source: source,
        state: state,
        title: title,
        contextUsed: context != null ? context : previous.contextUsed,
        updatedAt: now
      });
      return '';
    }
    """#
}
