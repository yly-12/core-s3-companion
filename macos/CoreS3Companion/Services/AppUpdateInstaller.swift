import AppKit
import Foundation

@MainActor
final class DMGAppUpdateInstaller: AppUpdateInstalling {
    private let bundle: Bundle
    private let resultURL: URL

    init(bundle: Bundle = .main, resultURL: URL? = nil) {
        self.bundle = bundle
        self.resultURL = resultURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CoreS3Companion/Updates/result.txt")
    }

    func validateDestination() throws {
        let app = bundle.bundleURL.resolvingSymlinksInPath()
        guard app.pathExtension == "app", !app.path.hasPrefix("/Volumes/"),
              !app.path.contains("/AppTranslocation/") else {
            throw AppUpdateError.message("请先将 CoreS3 Companion 拖到“应用程序”，从那里启动后再更新。")
        }
        guard FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path),
              FileManager.default.isWritableFile(atPath: app.path) else {
            throw AppUpdateError.message("应用所在目录不可写。请将应用移到 ~/Applications 并从那里启动，或联系管理员后重试。")
        }
    }

    func previousFailure() -> String? {
        guard let result = try? String(contentsOf: resultURL, encoding: .utf8) else { return nil }
        try? FileManager.default.removeItem(at: resultURL)
        return result.hasPrefix("error:") ? String(result.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    func prepareAndHandoff(dmg: URL, release: AppUpdateRelease, directory: URL) async throws {
        try validateDestination()
        guard let helper = bundle.url(forResource: "update-helper", withExtension: "sh"),
              let identifier = bundle.bundleIdentifier else {
            throw AppUpdateError.message("应用缺少更新安装器，请重新安装完整版本。")
        }
        let target = bundle.bundleURL.resolvingSymlinksInPath()
        let resultURL = self.resultURL
        let parentPID = ProcessInfo.processInfo.processIdentifier
        // Disk image mounting, copying and signature verification must not block the UI.
        try await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let mount = directory.appendingPathComponent("volume", isDirectory: true)
            let staged = directory.appendingPathComponent("CoreS3Companion.app", isDirectory: true)
            try fm.createDirectory(at: mount, withIntermediateDirectories: true)
            var mounted = false
            defer {
                if mounted { _ = try? UpdateCommand.run("/usr/bin/hdiutil", ["detach", "-force", mount.path], directory: directory) }
            }
            // Even if attach partially fails, detach the explicit mount point in the defer.
            mounted = true
            try UpdateCommand.run("/usr/bin/hdiutil", ["attach", dmg.path, "-readonly", "-nobrowse",
                "-noautoopen", "-mountpoint", mount.path], directory: directory)
            let source = mount.appendingPathComponent("CoreS3 Companion.app", isDirectory: true)
            guard fm.fileExists(atPath: source.appendingPathComponent("Contents/Info.plist").path),
                  (try source.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
                throw AppUpdateError.message("DMG 中未找到完整的 CoreS3 Companion 应用。")
            }
            try UpdateCommand.run("/usr/bin/ditto", [source.path, staged.path], directory: directory)
            try UpdateCommand.run("/usr/bin/hdiutil", ["detach", mount.path], directory: directory)
            mounted = false
            let executable = try Self.validateStagedApp(staged, identifier: identifier, version: release.version)
            try UpdateCommand.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path], directory: directory)
            #if arch(arm64)
            let architecture = "arm64"
            #else
            let architecture = "x86_64"
            #endif
            try UpdateCommand.run("/usr/bin/lipo", ["-verify_arch", architecture,
                staged.appendingPathComponent("Contents/MacOS/\(executable)").path], directory: directory)

            try fm.createDirectory(at: resultURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            let copiedHelper = directory.appendingPathComponent("update-helper.sh")
            try fm.copyItem(at: helper, to: copiedHelper)
            let ready = directory.appendingPathComponent("ready")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [copiedHelper.path, String(parentPID), target.path, staged.path,
                                 directory.path, resultURL.path]
            let logURL = directory.appendingPathComponent("installer.log")
            fm.createFile(atPath: logURL.path, contents: nil)
            let log = try FileHandle(forWritingTo: logURL)
            defer { try? log.close() }
            process.standardOutput = log
            process.standardError = log
            try process.run()
            let deadline = Date().addingTimeInterval(120)
            while process.isRunning && !fm.fileExists(atPath: ready.path) && Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard process.isRunning, fm.fileExists(atPath: ready.path) else {
                if process.isRunning { process.terminate(); process.waitUntilExit() }
                let result = (try? String(contentsOf: resultURL, encoding: .utf8)) ?? "安装准备超时，请重试。"
                try? fm.removeItem(at: resultURL)
                throw AppUpdateError.message(result.replacingOccurrences(of: "error:", with: ""))
            }
            // The helper has prepared a sibling app on the target filesystem. It now waits
            // for this process to exit, then performs the rename and relaunch independently.
        }.value
    }

    @discardableResult
    nonisolated static func validateStagedApp(_ app: URL, identifier: String, version: AppVersion) throws -> String {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == identifier,
              let versionString = plist["CFBundleShortVersionString"] as? String,
              AppVersion(versionString) == version,
              let executable = plist["CFBundleExecutable"] as? String,
              !executable.isEmpty, !executable.contains("/"), executable != ".", executable != "..",
              FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/\(executable)").path) else {
            throw AppUpdateError.message("安装包的应用标识、版本或可执行文件不匹配，已停止更新。")
        }
        if let minimum = plist["LSMinimumSystemVersion"] as? String {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            let current = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
            guard minimum.compare(current, options: .numeric) != .orderedDescending else {
                throw AppUpdateError.message("此更新需要 macOS \(minimum) 或更新版本，当前系统无法安装。")
            }
        }
        return executable
    }

    func restart() { NSApp.terminate(nil) }
}

private enum UpdateCommand {
    @discardableResult
    static func run(_ executable: String, _ arguments: [String], directory: URL) throws -> Data {
        let output = directory.appendingPathComponent("command-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: output) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        let deadline = Date().addingTimeInterval(120)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            throw AppUpdateError.message("安装准备超时（\(URL(fileURLWithPath: executable).lastPathComponent)）。")
        }
        guard process.terminationStatus == 0 else {
            throw AppUpdateError.message("安装包处理失败（\(URL(fileURLWithPath: executable).lastPathComponent)），请重新下载或重试。")
        }
        return (try? Data(contentsOf: output)) ?? Data()
    }
}
