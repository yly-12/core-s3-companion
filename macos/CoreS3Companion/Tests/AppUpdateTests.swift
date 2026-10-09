import CryptoKit
import Foundation
import Testing

#if SWIFT_PACKAGE
@testable import CoreS3CompanionCore
#else
@testable import CoreS3Companion
#endif

private func updateFixture(tag: String = "v0.0.12", draft: Bool = false,
                           prerelease: Bool = false, host: String = "github.com") throws -> AppUpdateRelease {
    let base = "https://\(host)/\(AppUpdateRelease.repository)/releases"
    let name = "CoreS3Companion-\(tag)-macOS-unsigned.dmg"
    return try AppUpdateRelease(GitHubRelease(tag_name: tag, body: "修复与改进", html_url: URL(string: "\(base)/tag/\(tag)")!,
        draft: draft, prerelease: prerelease, assets: [
            .init(name: name, browser_download_url: URL(string: "\(base)/download/\(tag)/\(name)")!, size: 3),
            .init(name: "SHA256SUMS.txt", browser_download_url: URL(string: "\(base)/download/\(tag)/SHA256SUMS.txt")!, size: 100)
        ]))
}

@Suite("App update validation")
struct AppUpdateValidationTests {
    @Test func comparesNumericVersions() throws {
        #expect(try #require(AppVersion("0.0.9")) < #require(AppVersion("v0.0.11")))
        #expect(try #require(AppVersion("0.9.99")) < #require(AppVersion("0.10.0")))
        #expect(try #require(AppVersion("0.99.99")) < #require(AppVersion("1.0.0")))
        #expect(AppVersion("0.0.11") == AppVersion("v0.0.11"))
    }

    @Test(arguments: ["", "1.0", "1.2.3.4", "1.2.3-beta", "1.2.3+4", "01.2.3", "1.-2.3", "１.2.3", "1.2.999999999999999999999999"])
    func rejectsInvalidVersions(_ value: String) { #expect(AppVersion(value) == nil) }

    @Test func acceptsExpectedAssets() throws {
        let release = try updateFixture()
        #expect(release.tag == "v0.0.12")
        #expect(release.notes == "修复与改进")
        #expect(release.downloadSize == 3)
    }

    @Test func rejectsDraftPrereleaseAndUntrustedHost() {
        #expect(throws: (any Error).self) { try updateFixture(draft: true) }
        #expect(throws: (any Error).self) { try updateFixture(prerelease: true) }
        #expect(throws: (any Error).self) { try updateFixture(host: "example.com") }
    }

    @Test func requiresDmgAndChecksum() throws {
        let release = GitHubRelease(tag_name: "v0.0.12", body: nil,
            html_url: URL(string: "https://github.com/\(AppUpdateRelease.repository)/releases/tag/v0.0.12")!,
            draft: false, prerelease: false, assets: [])
        #expect(throws: (any Error).self) { try AppUpdateRelease(release) }
    }

    @Test func parsesExactChecksumAndRejectsDuplicates() throws {
        let release = try updateFixture()
        let hash = String(repeating: "A", count: 64)
        #expect(try AppUpdateRelease.checksum(in: "\(hash)  \(release.assetName)\n", for: release.assetName) == hash.lowercased())
        #expect(try AppUpdateRelease.checksum(in: "\(hash) *\(release.assetName)\n", for: release.assetName) == hash.lowercased())
        for text in ["abcd  \(release.assetName)", "\(hash)  wrong.dmg",
                     "\(hash)  \(release.assetName)\n\(hash)  \(release.assetName)", "\(String(repeating: "g", count: 64))  \(release.assetName)"] {
            #expect(throws: (any Error).self) { try AppUpdateRelease.checksum(in: text, for: release.assetName) }
        }
    }

    @Test func verifiesBytesAndDetectsTampering() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        try Data("abc".utf8).write(to: path)
        let digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        try GitHubAppUpdateClient.verifyDownload(at: path, expected: digest, size: 3)
        #expect(throws: (any Error).self) { try GitHubAppUpdateClient.verifyDownload(at: path, expected: digest, size: 4) }
        try Data("abd".utf8).write(to: path)
        #expect(throws: (any Error).self) { try GitHubAppUpdateClient.verifyDownload(at: path, expected: digest, size: 3) }
    }

    @Test func validatesApplicationIdentityAndVersion() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: app) }
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let executable = macOS.appendingPathComponent("Companion")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let info = app.appendingPathComponent("Contents/Info.plist")
        let plist = ["CFBundleIdentifier": "com.cores3companion.macos", "CFBundleShortVersionString": "0.0.12",
                     "CFBundleExecutable": "Companion"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: info)
        let version = try #require(AppVersion("0.0.12"))
        try DMGAppUpdateInstaller.validateStagedApp(app, identifier: "com.cores3companion.macos", version: version)
        #expect(throws: (any Error).self) { try DMGAppUpdateInstaller.validateStagedApp(app, identifier: "other.app", version: version) }
        #expect(throws: (any Error).self) {
            try DMGAppUpdateInstaller.validateStagedApp(app, identifier: "com.cores3companion.macos", version: #require(AppVersion("0.0.13")))
        }
    }
}

private actor StubUpdateClient: AppUpdateFetching {
    var latest: AppUpdateRelease?
    var error: AppUpdateError?
    var downloadError: AppUpdateError?
    var holdDownload = false
    private(set) var checkCount = 0
    private(set) var downloadCount = 0
    private(set) var downloadDirectory: URL?
    init(latest: AppUpdateRelease?) { self.latest = latest }
    func setError(_ error: AppUpdateError?) { self.error = error }
    func setDownloadError(_ error: AppUpdateError?) { downloadError = error }
    func setHoldDownload(_ value: Bool = true) { holdDownload = value }
    func latestRelease() async throws -> AppUpdateRelease? {
        checkCount += 1
        if let error { throw error }
        return latest
    }
    func download(_ release: AppUpdateRelease, to directory: URL,
                  progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        downloadCount += 1
        downloadDirectory = directory
        if let downloadError { throw downloadError }
        progress(0.5)
        if holdDownload { try await Task.sleep(for: .seconds(60)) }
        return directory.appendingPathComponent("test.dmg")
    }
}

@MainActor
private final class StubUpdateInstaller: AppUpdateInstalling {
    var validationError: AppUpdateError?
    var preparationError: AppUpdateError?
    var didPrepare = false
    var didRestart = false
    var directory: URL?
    func validateDestination() throws { if let validationError { throw validationError } }
    func prepareAndHandoff(dmg: URL, release: AppUpdateRelease, directory: URL) async throws {
        if let preparationError { throw preparationError }
        didPrepare = true
        self.directory = directory
    }
    func restart() { didRestart = true }
    func previousFailure() -> String? { nil }
}

@MainActor
@Suite("App update lifecycle")
struct AppUpdateLifecycleTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "AppUpdateTests.\(UUID().uuidString)")!
    }
    private func settle(_ service: AppUpdateService) async throws {
        for _ in 0..<200 {
            if !service.state.isBusy || service.state == .restarting { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Update operation did not complete")
    }

    @Test func defaultsToAutomaticChecksAndPersistsChoice() {
        let preferences = defaults()
        let service = AppUpdateService(currentVersion: "0.0.11", client: StubUpdateClient(latest: nil),
            installer: StubUpdateInstaller(), defaults: preferences)
        #expect(service.automaticChecks)
        service.automaticChecks = false
        #expect(preferences.bool(forKey: "updates.automaticChecks") == false)
    }

    @Test func automaticallyPromptsOnceAndManualCheckIgnoresSkip() async throws {
        let latest = try updateFixture()
        let preferences = defaults()
        let service = AppUpdateService(currentVersion: "0.0.11", client: StubUpdateClient(latest: latest),
            installer: StubUpdateInstaller(), defaults: preferences)
        service.check(manual: false)
        try await settle(service)
        #expect(service.promptRelease == latest)
        service.promptRelease = nil
        service.check(manual: false)
        try await settle(service)
        #expect(service.promptRelease == nil)
        service.check()
        try await settle(service)
        #expect(service.promptRelease == latest)
        service.skipRelease()
        #expect(preferences.string(forKey: "updates.skippedVersion") == latest.tag)
        service.check(manual: false)
        try await settle(service)
        #expect(service.promptRelease == nil)
        service.check()
        try await settle(service)
        #expect(service.promptRelease == latest)
    }

    @Test func nextVersionPromptsAfterSkippingPreviousVersion() async throws {
        let preferences = defaults()
        preferences.set("v0.0.12", forKey: "updates.skippedVersion")
        preferences.set(["v0.0.12"], forKey: "updates.notifiedVersions")
        let latest = try updateFixture(tag: "v0.0.13")
        let service = AppUpdateService(currentVersion: "0.0.11", client: StubUpdateClient(latest: latest),
            installer: StubUpdateInstaller(), defaults: preferences)
        service.check(manual: false)
        try await settle(service)
        #expect(service.promptRelease == latest)
    }

    @Test(arguments: ["v0.0.10", "v0.0.11"])
    func doesNotDowngradeOrReinstall(_ tag: String) async throws {
        let service = AppUpdateService(currentVersion: "0.0.11", client: StubUpdateClient(latest: try updateFixture(tag: tag)),
            installer: StubUpdateInstaller(), defaults: defaults())
        service.check()
        try await settle(service)
        #expect(service.state == .upToDate)
        #expect(service.release == nil)
        #expect(service.promptRelease == nil)
    }

    @Test func networkErrorCanBeRetried() async throws {
        let client = StubUpdateClient(latest: nil)
        await client.setError(.message("offline"))
        let service = AppUpdateService(currentVersion: "0.0.11", client: client, installer: StubUpdateInstaller(), defaults: defaults())
        service.check()
        try await settle(service)
        guard case .failed = service.state else { Issue.record("Expected check failure"); return }
        await client.setError(nil)
        service.check()
        try await settle(service)
        #expect(service.state == .upToDate)
        #expect(service.lastCheckedAt != nil)
    }

    @Test func preparesBeforeRestartAndRejectsConcurrentOperations() async throws {
        let client = StubUpdateClient(latest: try updateFixture())
        let installer = StubUpdateInstaller()
        let service = AppUpdateService(currentVersion: "0.0.11", client: client, installer: installer, defaults: defaults())
        service.check()
        service.check()
        try await settle(service)
        #expect(await client.checkCount == 1)
        service.install()
        service.install()
        service.check()
        try await settle(service)
        #expect(await client.downloadCount == 1)
        #expect(installer.didPrepare && installer.didRestart)
        #expect(service.state == .restarting)
        if let directory = installer.directory { try? FileManager.default.removeItem(at: directory) }
    }

    @Test func doesNotDownloadIntoUnwritableInstallation() async throws {
        let client = StubUpdateClient(latest: try updateFixture())
        let installer = StubUpdateInstaller()
        installer.validationError = .message("not writable")
        let service = AppUpdateService(currentVersion: "0.0.11", client: client, installer: installer, defaults: defaults())
        service.check()
        try await settle(service)
        service.install()
        #expect(await client.downloadCount == 0)
        #expect(service.state == .failed("not writable"))
        #expect(!installer.didRestart)
    }

    @Test func failedPreparationNeverRestarts() async throws {
        let installer = StubUpdateInstaller()
        installer.preparationError = .message("invalid image")
        let service = AppUpdateService(currentVersion: "0.0.11", client: StubUpdateClient(latest: try updateFixture()),
            installer: installer, defaults: defaults())
        service.check()
        try await settle(service)
        service.install()
        try await settle(service)
        #expect(!installer.didRestart)
        guard case .failed = service.state else { Issue.record("Expected preparation failure"); return }
    }

    @Test func failedDownloadCleansFilesAndCanBeRetried() async throws {
        let client = StubUpdateClient(latest: try updateFixture())
        await client.setDownloadError(.message("checksum mismatch"))
        let installer = StubUpdateInstaller()
        let service = AppUpdateService(currentVersion: "0.0.11", client: client, installer: installer, defaults: defaults())
        service.check()
        try await settle(service)
        service.install()
        try await settle(service)
        guard case .failed = service.state else { Issue.record("Expected download failure"); return }
        #expect(!installer.didPrepare && !installer.didRestart)
        if let directory = await client.downloadDirectory {
            #expect(!FileManager.default.fileExists(atPath: directory.path))
        }
        await client.setDownloadError(nil)
        service.install()
        try await settle(service)
        #expect(installer.didRestart)
        #expect(await client.downloadCount == 2)
        if let directory = installer.directory { try? FileManager.default.removeItem(at: directory) }
    }

    @Test func cancelledDownloadCanBeRetriedWithoutRestarting() async throws {
        let client = StubUpdateClient(latest: try updateFixture())
        await client.setHoldDownload()
        let installer = StubUpdateInstaller()
        let service = AppUpdateService(currentVersion: "0.0.11", client: client, installer: installer, defaults: defaults())
        service.check()
        try await settle(service)
        service.install()
        try await Task.sleep(for: .milliseconds(20))
        service.cancelDownload()
        try await settle(service)
        #expect(service.state == .available)
        #expect(!installer.didRestart)
        await client.setHoldDownload(false)
        service.install()
        try await settle(service)
        #expect(installer.didRestart)
        if let directory = installer.directory { try? FileManager.default.removeItem(at: directory) }
    }

    @Test func startupAndPeriodicChecksRespectToggle() async throws {
        let client = StubUpdateClient(latest: nil)
        let service = AppUpdateService(currentVersion: "0.0.11", client: client, installer: StubUpdateInstaller(),
            defaults: defaults(), checkInterval: 0.03)
        service.automaticChecks = false
        service.start()
        try await Task.sleep(for: .milliseconds(70))
        #expect(await client.checkCount == 0)
        service.automaticChecks = true
        // Wait for actual ticks: a hosted app's main actor can be busy with other tests.
        for _ in 0..<200 {
            if await client.checkCount >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await client.checkCount >= 2)
        service.automaticChecks = false
        try await settle(service)
        let stoppedCount = await client.checkCount
        try await Task.sleep(for: .milliseconds(70))
        #expect(await client.checkCount == stoppedCount)
    }
}

private final class UpdateAPIURLProtocol: URLProtocol {
    static var status = 200
    static var data = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("GitHub update API", .serialized)
struct GitHubUpdateAPITests {
    private func client(status: Int, data: Data = Data()) -> GitHubAppUpdateClient {
        UpdateAPIURLProtocol.status = status
        UpdateAPIURLProtocol.data = data
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UpdateAPIURLProtocol.self]
        return GitHubAppUpdateClient(session: URLSession(configuration: config))
    }

    @Test func decodesGitHubReleaseResponse() async throws {
        let fixture = try updateFixture()
        let object: [String: Any] = ["tag_name": fixture.tag, "body": fixture.notes,
            "html_url": fixture.pageURL.absoluteString, "draft": false, "prerelease": false,
            "assets": [
                ["name": fixture.assetName, "browser_download_url": fixture.downloadURL.absoluteString, "size": 3],
                ["name": "SHA256SUMS.txt", "browser_download_url": fixture.checksumURL.absoluteString, "size": 100]
            ]]
        let api = client(status: 200, data: try JSONSerialization.data(withJSONObject: object))
        #expect(try await api.latestRelease() == fixture)
    }

    @Test func handlesNoPublishedRelease() async throws {
        #expect(try await client(status: 404).latestRelease() == nil)
    }

    @Test(arguments: [403, 429, 500])
    func rejectsHttpErrors(_ status: Int) async {
        do {
            _ = try await client(status: status).latestRelease()
            Issue.record("HTTP error was accepted")
        } catch {
            #expect(error is AppUpdateError)
        }
    }

    @Test func rejectsMalformedResponse() async {
        do {
            _ = try await client(status: 200, data: Data("invalid json".utf8)).latestRelease()
            Issue.record("Malformed JSON was accepted")
        } catch {
            #expect(error is DecodingError)
        }
    }
}
