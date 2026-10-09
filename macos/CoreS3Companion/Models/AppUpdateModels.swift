import Foundation

struct AppVersion: Comparable, Equatable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ string: String) {
        let value = string.hasPrefix("v") ? String(string.dropFirst()) : string
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber })
                  && ($0.count == 1 || $0.first != "0") }),
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]) else {
            return nil
        }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
        let size: Int64
    }

    let tag_name: String
    let body: String?
    let html_url: URL
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
}

struct AppUpdateRelease: Identifiable, Equatable {
    static let repository = "yly-12/core-s3-companion"
    let tag: String
    let version: AppVersion
    let notes: String
    let pageURL: URL
    let downloadURL: URL
    let checksumURL: URL
    let assetName: String
    let downloadSize: Int64
    var id: String { tag }

    init(_ release: GitHubRelease) throws {
        guard !release.draft, !release.prerelease,
              release.tag_name.hasPrefix("v"), let version = AppVersion(release.tag_name) else {
            throw AppUpdateError.message("发布版本信息无效，或该版本不是正式版。")
        }
        let name = "CoreS3Companion-\(release.tag_name)-macOS-unsigned.dmg"
        let matches = release.assets.filter { $0.name == name }
        let checksums = release.assets.filter { $0.name == "SHA256SUMS.txt" }
        let base = "https://github.com/\(Self.repository)/releases"
        guard matches.count == 1, checksums.count == 1,
              let asset = matches.first, let checksum = checksums.first,
              asset.size > 0,
              release.html_url.absoluteString == "\(base)/tag/\(release.tag_name)",
              asset.browser_download_url.absoluteString == "\(base)/download/\(release.tag_name)/\(name)",
              checksum.browser_download_url.absoluteString == "\(base)/download/\(release.tag_name)/SHA256SUMS.txt" else {
            throw AppUpdateError.message("该 Release 缺少可用的 macOS 安装包或校验文件。")
        }
        tag = release.tag_name
        self.version = version
        notes = release.body ?? "此版本没有提供更新说明。"
        pageURL = release.html_url
        downloadURL = asset.browser_download_url
        checksumURL = checksum.browser_download_url
        assetName = name
        downloadSize = asset.size
    }

    static func checksum(in text: String, for assetName: String) throws -> String {
        let matches = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2 else { return nil }
            let name = parts[1].trimmingCharacters(in: .whitespaces)
            guard name == assetName || name == "*\(assetName)" else { return nil }
            return String(parts[0])
        }
        guard matches.count == 1, let hash = matches.first, hash.count == 64,
              hash.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw AppUpdateError.message("安装包的 SHA-256 校验信息无效。")
        }
        return hash.lowercased()
    }
}

enum AppUpdateError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): text }
    }
}

enum AppUpdateState: Equatable {
    case idle, checking, upToDate
    case available
    case downloading(Double)
    case preparing, restarting
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .preparing, .restarting: true
        default: false
        }
    }

    var isInstalling: Bool {
        switch self {
        case .downloading, .preparing, .restarting: true
        default: false
        }
    }
}
