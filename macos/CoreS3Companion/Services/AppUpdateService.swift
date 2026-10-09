import Combine
import CryptoKit
import Foundation

protocol AppUpdateFetching {
    func latestRelease() async throws -> AppUpdateRelease?
    func download(_ release: AppUpdateRelease, to directory: URL,
                  progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}

final class GitHubAppUpdateClient: AppUpdateFetching {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session { self.session = session } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 30 * 60
            self.session = URLSession(configuration: config)
        }
    }

    func latestRelease() async throws -> AppUpdateRelease? {
        var request = URLRequest(url: URL(string:
            "https://api.github.com/repos/\(AppUpdateRelease.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("CoreS3Companion", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 404 { return nil }
        try Self.validate(response)
        return try AppUpdateRelease(JSONDecoder().decode(GitHubRelease.self, from: data))
    }

    func download(_ release: AppUpdateRelease, to directory: URL,
                  progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let (checksumData, checksumResponse) = try await session.data(from: release.checksumURL)
        try Self.validate(checksumResponse)
        guard checksumData.count < 1_048_576,
              let checksumText = String(data: checksumData, encoding: .utf8) else {
            throw AppUpdateError.message("无法读取安装包校验文件。")
        }
        let expected = try AppUpdateRelease.checksum(in: checksumText, for: release.assetName)
        let delegate = DownloadProgressDelegate(progress: progress)
        let (temporaryURL, response) = try await session.download(
            for: URLRequest(url: release.downloadURL), delegate: delegate
        )
        try Self.validate(response)
        try Task.checkCancellation()
        let destination = directory.appendingPathComponent(release.assetName)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        try Self.verifyDownload(at: destination, expected: expected, size: release.downloadSize)
        return destination
    }

    static func verifyDownload(at destination: URL, expected: String, size expectedSize: Int64) throws {
        let handle = try FileHandle(forReadingFrom: destination)
        defer { try? handle.close() }
        var hash = SHA256()
        var size: Int64 = 0
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
            size += Int64(chunk.count)
        }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard size == expectedSize, actual == expected else {
            throw AppUpdateError.message("安装包完整性校验失败，请重试下载。旧版本未被修改。")
        }
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let text = (code == 403 || code == 429)
                ? "GitHub 请求暂时受限，请稍后重试。"
                : "无法获取更新文件（HTTP \(code)），请检查网络后重试。"
            throw AppUpdateError.message(text)
        }
        guard response.url?.scheme == "https" else {
            throw AppUpdateError.message("更新连接不安全，已停止下载。")
        }
    }
}

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double) -> Void
    init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}

@MainActor
protocol AppUpdateInstalling {
    func validateDestination() throws
    func prepareAndHandoff(dmg: URL, release: AppUpdateRelease, directory: URL) async throws
    func restart()
    func previousFailure() -> String?
}

@MainActor
final class AppUpdateService: ObservableObject {
    @Published private(set) var state: AppUpdateState = .idle
    @Published private(set) var release: AppUpdateRelease?
    @Published var promptRelease: AppUpdateRelease?
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var previousInstallationFailure: String?
    @Published var automaticChecks: Bool {
        didSet {
            defaults.set(automaticChecks, forKey: "updates.automaticChecks")
            if started { scheduleAutomaticChecks() }
        }
    }

    let currentVersion: String
    private let client: AppUpdateFetching
    private let installer: AppUpdateInstalling
    private let defaults: UserDefaults
    private var started = false
    private var automaticTask: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private let checkInterval: TimeInterval

    init(currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知",
         client: AppUpdateFetching = GitHubAppUpdateClient(),
         installer: AppUpdateInstalling? = nil, defaults: UserDefaults = .standard,
         checkInterval: TimeInterval = 24 * 60 * 60) {
        self.currentVersion = currentVersion
        self.client = client
        self.installer = installer ?? DMGAppUpdateInstaller()
        self.defaults = defaults
        self.checkInterval = checkInterval
        automaticChecks = defaults.object(forKey: "updates.automaticChecks") as? Bool ?? true
        lastCheckedAt = defaults.object(forKey: "updates.lastCheckedAt") as? Date
    }

    deinit { automaticTask?.cancel(); operation?.cancel() }

    func start() {
        guard !started else { return }
        started = true
        previousInstallationFailure = installer.previousFailure()
        scheduleAutomaticChecks()
    }

    private func scheduleAutomaticChecks() {
        automaticTask?.cancel()
        guard automaticChecks else { return }
        automaticTask = Task { [weak self, checkInterval] in
            guard !Task.isCancelled else { return }
            self?.check(manual: false)
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(checkInterval))
                    try Task.checkCancellation()
                } catch { return }
                self?.check(manual: false)
            }
        }
    }

    func check(manual: Bool = true) {
        guard !state.isBusy, manual || automaticChecks else { return }
        state = .checking
        operation = Task { [weak self] in await self?.performCheck(manual: manual) }
    }

    private func performCheck(manual: Bool) async {
        do {
            guard let current = AppVersion(currentVersion) else {
                throw AppUpdateError.message("无法读取当前应用版本，暂时不能检查更新。")
            }
            let latest = try await client.latestRelease()
            try Task.checkCancellation()
            lastCheckedAt = .now
            defaults.set(lastCheckedAt, forKey: "updates.lastCheckedAt")
            guard let latest, latest.version > current else {
                release = nil
                state = .upToDate
                return
            }
            release = latest
            state = .available
            let notifiedVersions = defaults.stringArray(forKey: "updates.notifiedVersions") ?? []
            if manual || (defaults.string(forKey: "updates.skippedVersion") != latest.tag
                && !notifiedVersions.contains(latest.tag)) {
                if !notifiedVersions.contains(latest.tag) {
                    defaults.set(notifiedVersions + [latest.tag], forKey: "updates.notifiedVersions")
                }
                promptRelease = latest
            }
        } catch {
            state = .failed("检查更新失败：\(error.localizedDescription)")
        }
    }

    func skipRelease() {
        guard let release, !state.isBusy else { return }
        defaults.set(release.tag, forKey: "updates.skippedVersion")
        promptRelease = nil
    }

    func install() {
        guard let release, !state.isBusy else { return }
        do { try installer.validateDestination() } catch {
            state = .failed(error.localizedDescription)
            return
        }
        state = .downloading(0)
        operation = Task { [weak self] in await self?.performInstall(release) }
    }

    private func performInstall(_ release: AppUpdateRelease) async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreS3Companion-update-\(UUID().uuidString)", isDirectory: true)
        var handedOff = false
        defer { if !handedOff { try? FileManager.default.removeItem(at: directory) } }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                  attributes: [.posixPermissions: 0o700])
            let dmg = try await client.download(release, to: directory) { [weak self] progress in
                Task { @MainActor in
                    guard let self, case .downloading = self.state else { return }
                    self.state = .downloading(progress)
                }
            }
            try Task.checkCancellation()
            state = .preparing
            try await installer.prepareAndHandoff(dmg: dmg, release: release, directory: directory)
            handedOff = true
            state = .restarting
            installer.restart()
        } catch is CancellationError {
            state = .available
        } catch let error as URLError where error.code == .cancelled {
            state = .available
        } catch {
            state = .failed("更新失败：\(error.localizedDescription)")
        }
    }

    func cancelDownload() {
        guard case .downloading = state else { return }
        operation?.cancel()
    }
}
