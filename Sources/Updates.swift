// Version comparison and the two update feeds Harness Desk checks:
// the published npm dist-tags for DeepSeek Harness, and the latest GitHub
// release of Harness Desk itself.

import Foundation

/// Compares the version strings both projects publish: `MAJOR.MINOR.PATCH`
/// with an optional `-prerelease` suffix and an ignored `+build` suffix.
/// Semver ordering, so `0.2.1-rc.4` sorts above `0.2.1-rc.2` and below
/// `0.2.2-alpha.2`.
enum VersionOrder {

    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = parse(lhs)
        let right = parse(rhs)

        let core = compareNumbers(left.core, right.core)
        if core != .orderedSame { return core }

        switch (left.prerelease, right.prerelease) {
        case (nil, nil):
            return .orderedSame
        case (nil, _):
            return .orderedDescending       // a release outranks a prerelease
        case (_, nil):
            return .orderedAscending
        case let (a?, b?):
            return compareIdentifiers(a, b)
        }
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }

    private static func parse(_ raw: String) -> (core: [Int], prerelease: [String]?) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        if let plus = text.firstIndex(of: "+") { text = String(text[..<plus]) }

        let halves = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = halves[0].split(separator: ".").map { Int($0) ?? 0 }
        guard halves.count == 2, !halves[1].isEmpty else { return (core, nil) }
        let prerelease = halves[1].split(separator: ".").map(String.init)
        return (core, prerelease.isEmpty ? nil : prerelease)
    }

    private static func compareNumbers(_ a: [Int], _ b: [Int]) -> ComparisonResult {
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left < right ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private static func compareIdentifiers(_ a: [String], _ b: [String]) -> ComparisonResult {
        for index in 0..<min(a.count, b.count) {
            let left = a[index]
            let right = b[index]
            switch (Int(left), Int(right)) {
            case let (l?, r?):
                if l != r { return l < r ? .orderedAscending : .orderedDescending }
            case (_?, nil):
                return .orderedAscending    // numeric identifiers sort first
            case (nil, _?):
                return .orderedDescending
            default:
                if left != right { return left < right ? .orderedAscending : .orderedDescending }
            }
        }
        if a.count == b.count { return .orderedSame }
        return a.count < b.count ? .orderedAscending : .orderedDescending
    }
}

/// Read-only lookups used by the About window. Everything here blocks, so it
/// is only ever called off the main queue.
enum UpdateFeed {

    enum FeedError: LocalizedError {
        case timedOut
        case badStatus(Int)
        case malformed

        var errorDescription: String? {
            switch self {
            case .timedOut: return "the request timed out"
            case .badStatus(let code): return "the server answered \(code)"
            case .malformed: return "the response could not be read"
            }
        }
    }

    static let dshDistTagsURL = URL(string:
        "https://registry.npmjs.org/-/package/@deepseek-ai%2Fdsh/dist-tags")!
    static let latestReleaseURL = URL(string:
        "https://api.github.com/repos/NaleenB/harness-desk-macos/releases/latest")!

    /// `{"latest": "0.2.1-rc.2", "next": "0.2.1-rc.4", ...}`
    static func parseDistTags(_ data: Data) throws -> [String: String] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let raw = object as? [String: Any] else { throw FeedError.malformed }
        var tags: [String: String] = [:]
        for (name, value) in raw {
            if let version = value as? String { tags[name] = version }
        }
        guard let latest = tags["latest"], !latest.isEmpty else { throw FeedError.malformed }
        return tags
    }

    /// The release tag without its `v`, or nil when the repository has no
    /// published releases.
    static func parseLatestReleaseTag(_ data: Data) throws -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let raw = object as? [String: Any] else { throw FeedError.malformed }
        guard let tag = raw["tag_name"] as? String, !tag.isEmpty else { throw FeedError.malformed }
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    static func dshDistTags() throws -> [String: String] {
        guard let data = try get(dshDistTagsURL) else { throw FeedError.malformed }
        return try parseDistTags(data)
    }

    /// nil means "no releases published yet", which is different from a failure.
    static func latestDeskRelease() throws -> String? {
        guard let data = try get(latestReleaseURL) else { return nil }
        return try parseLatestReleaseTag(data)
    }

    /// Runs `dsh --version`, which prints the CLI version alone.
    static func installedDSHVersion(atPath path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        var environment = ProcessInfo.processInfo.environment
        let basePath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = environment["PATH"].map { basePath + ":" + $0 } ?? basePath
        process.environment = environment

        let output = Pipe()
        process.standardOutput = output

        do { try process.run() } catch { return nil }

        let deadline = Date().addingTimeInterval(6)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text.split(separator: "\n").last.map(String.init)
    }

    /// Returns nil for 404 so "no releases yet" is not mistaken for an error.
    private static func get(_ url: URL) throws -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("HarnessDesk", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let semaphore = DispatchSemaphore(value: 0)
        var payload: Data?
        var status = 0
        var failure: Error?

        URLSession.shared.dataTask(with: request) { data, response, error in
            payload = data
            failure = error
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            semaphore.signal()
        }.resume()

        if semaphore.wait(timeout: .now() + 15) == .timedOut { throw FeedError.timedOut }
        if let failure { throw failure }
        if status == 404 { return nil }
        guard status == 200, let payload else { throw FeedError.badStatus(status) }
        return payload
    }
}
