import Foundation

/// A version number like 0.1.0 or v1.2.0-beta.1. Pre-releases sort before their release.
public struct SemVer: Comparable, Sendable, CustomStringConvertible {
    public let numbers: [Int]
    public let prerelease: String?

    public init?(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let parts = s.split(separator: "-", maxSplits: 1).map(String.init)
        guard let core = parts.first, !core.isEmpty else { return nil }
        let nums = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !nums.isEmpty, nums.count <= 4, nums.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        numbers = nums.map { $0! }
        prerelease = parts.count > 1 ? parts[1] : nil
    }

    public var description: String { numbers.map(String.init).joined(separator: ".") + (prerelease.map { "-" + $0 } ?? "") }

    public static func < (a: SemVer, b: SemVer) -> Bool {
        for i in 0..<max(a.numbers.count, b.numbers.count) {
            let x = i < a.numbers.count ? a.numbers[i] : 0, y = i < b.numbers.count ? b.numbers[i] : 0
            if x != y { return x < y }
        }
        switch (a.prerelease, b.prerelease) {
        case (nil, nil), (nil, _?): return false
        case (_?, nil): return true
        case (let p?, let q?): return p.compare(q, options: .numeric) == .orderedAscending
        }
    }

    public static func == (a: SemVer, b: SemVer) -> Bool { !(a < b) && !(b < a) }
}

/// A published GitHub release of AFM Studio.
public struct ReleaseInfo: Codable, Sendable, Equatable {
    public struct Asset: Codable, Sendable, Equatable {
        public var name: String
        public var url: String
        public var size: Int
    }
    public var tag: String
    public var name: String
    public var notes: String
    public var url: String
    public var publishedAt: Date?
    public var assets: [Asset]

    public var version: SemVer? { SemVer(tag) }
    /// The zipped app, when the release has one.
    public var appZip: Asset? { assets.first { $0.name.hasPrefix("AFM-Studio-") && $0.name.hasSuffix(".zip") } }
}

/// Checks GitHub for a newer release. One unauthenticated request; nothing about you is sent.
public enum Updates {
    public static let repo = "ry-ops/afm-studio"
    public static let releasesPage = "https://github.com/\(repo)/releases"
    /// Background checks (when turned on) run at most this often.
    public static let interval: TimeInterval = 24 * 60 * 60

    public enum Status: Sendable, Equatable {
        case upToDate(latest: String)
        case available(ReleaseInfo)
        case noReleases
    }

    /// What the last check found, so a background check can skip the network until it's due.
    public struct Saved: Codable, Sendable {
        public var checked: Date
        public var latest: ReleaseInfo?
    }

    static var stateFile: URL { AFMPaths.root.appendingPathComponent("updates.json") }

    public static func saved() -> Saved? {
        guard let d = try? Data(contentsOf: stateFile) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Saved.self, from: d)
    }

    static func save(_ s: Saved) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(s).write(to: stateFile, options: .atomic)
    }

    public static var current: SemVer { SemVer(AFMVersion.string)! }

    /// Compares a release with the running version.
    public static func status(for latest: ReleaseInfo?, current: SemVer = Updates.current) -> Status {
        guard let latest else { return .noReleases }
        if let v = latest.version, v > current { return .available(latest) }
        return .upToDate(latest: latest.version?.description ?? latest.tag)
    }

    /// Asks GitHub for the latest release, records the answer and compares it with this build.
    public static func check() async throws -> Status {
        let latest = try await fetchLatest()
        save(Saved(checked: Date(), latest: latest))
        return status(for: latest)
    }

    /// A background check: nil when it isn't due yet or the network fails, so it never bothers you.
    public static func checkIfDue(now: Date = Date()) async -> Status? {
        if let s = saved(), now.timeIntervalSince(s.checked) < interval { return status(for: s.latest) }
        return try? await check()
    }

    public static func fetchLatest() async throws -> ReleaseInfo? {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("afm-studio/\(AFMVersion.string)", forHTTPHeaderField: "User-Agent")
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await URLSession.shared.data(for: req) } catch {
            throw AFMError(code: "update_network", message: "Couldn't reach GitHub to check for updates.", suggestion: "Check your connection and try again.")
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return nil }
        guard code == 200 else {
            throw AFMError(code: "update_http", message: code == 403 || code == 429 ? "GitHub is rate-limiting update checks right now." : "GitHub answered the update check with HTTP \(code).",
                           suggestion: "Try again later, or see \(releasesPage).")
        }
        return try parse(data)
    }

    /// Keeps only what's needed, and only links that point at this repo on github.com.
    public static func parse(_ data: Data) throws -> ReleaseInfo {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let tag = o["tag_name"] as? String else {
            throw AFMError(code: "update_parse", message: "GitHub's release information wasn't in the expected format.")
        }
        func trusted(_ s: String?) -> String? {
            guard let s, s.hasPrefix("https://github.com/\(repo)/") else { return nil }
            return s
        }
        let assets = ((o["assets"] as? [[String: Any]]) ?? []).compactMap { a -> ReleaseInfo.Asset? in
            guard let n = a["name"] as? String, let u = trusted(a["browser_download_url"] as? String) else { return nil }
            return ReleaseInfo.Asset(name: n, url: u, size: a["size"] as? Int ?? 0)
        }
        let date = (o["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        let notes = String(((o["body"] as? String) ?? "").prefix(20_000))
        return ReleaseInfo(tag: tag, name: (o["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? tag, notes: notes,
                           url: trusted(o["html_url"] as? String) ?? "\(releasesPage)/tag/\(tag)", publishedAt: date, assets: assets)
    }

    /// The checkout this app was built from, written into Info.plist by build-app.sh. Nil for downloaded builds.
    public static func sourceCheckout(bundle: Bundle = .main) -> String? {
        guard let p = bundle.object(forInfoDictionaryKey: "AFMSourcePath") as? String, !p.isEmpty,
              FileManager.default.fileExists(atPath: p + "/.git") else { return nil }
        return p
    }

    /// How to install a release, for whichever way this copy was installed.
    public static func howToUpdate(_ r: ReleaseInfo, source: String?) -> String {
        if let source {
            return "cd \(ClaudeHook.shellQuote(source))\ngit pull --ff-only\nbash scripts/build-app.sh --install"
        }
        return "Download \(r.appZip?.name ?? "the app") from \(r.url), unzip it and move AFM Studio to Applications."
    }
}
