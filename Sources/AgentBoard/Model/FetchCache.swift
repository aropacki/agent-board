import AppKit

/// Checks and discussions as last fetched, kept on disk so a restart shows them at once while they refresh.
struct FetchCache: Codable, Equatable {
    var checks: [String: [CICheck]] = [:]
    var checksAt: [String: Date] = [:]
    var discussions: [String: PRDiscussion] = [:]
    var discussionsAt: [String: Date] = [:]
    var discussionsUnresolved: [String: Int] = [:]

    /// Drops what was fetched more than `age` ago.
    func pruned(now: Date, age: TimeInterval = 2 * 86400) -> FetchCache {
        let checksKept = checksAt.filter { now.timeIntervalSince($0.value) < age }
        let discussionsKept = discussionsAt.filter { now.timeIntervalSince($0.value) < age }
        return FetchCache(checks: checks.filter { checksKept[$0.key] != nil }, checksAt: checksKept,
                          discussions: discussions.filter { discussionsKept[$0.key] != nil }, discussionsAt: discussionsKept,
                          discussionsUnresolved: discussionsUnresolved.filter { discussionsKept[$0.key] != nil })
    }

    var entries: [String: FetchCacheEntry] {
        var out: [String: FetchCacheEntry] = [:]
        for key in Set(checksAt.keys).union(discussionsAt.keys) {
            out[key] = FetchCacheEntry(key: key, checks: checks[key], checksAt: checksAt[key], discussion: discussions[key],
                                       discussionAt: discussionsAt[key], unresolved: discussionsUnresolved[key])
        }
        return out
    }

    init(checks: [String: [CICheck]] = [:], checksAt: [String: Date] = [:], discussions: [String: PRDiscussion] = [:],
         discussionsAt: [String: Date] = [:], discussionsUnresolved: [String: Int] = [:]) {
        self.checks = checks
        self.checksAt = checksAt
        self.discussions = discussions
        self.discussionsAt = discussionsAt
        self.discussionsUnresolved = discussionsUnresolved
    }

    init(entries: [FetchCacheEntry]) {
        for e in entries {
            checks[e.key] = e.checks
            checksAt[e.key] = e.checksAt
            discussions[e.key] = e.discussion
            discussionsAt[e.key] = e.discussionAt
            discussionsUnresolved[e.key] = e.unresolved
        }
    }
}

/// One PR's part of the cache, saved as its own file so a refresh rewrites only the PRs that changed.
struct FetchCacheEntry: Codable, Equatable {
    var key: String
    var checks: [CICheck]?
    var checksAt: Date?
    var discussion: PRDiscussion?
    var discussionAt: Date?
    var unresolved: Int?

    /// Every refetch moves the timestamps. When nothing else changed, the file is rewritten only once the saved
    /// times fall `slack` behind, which is enough for pruning by age.
    func needsWrite(over old: FetchCacheEntry?, slack: TimeInterval = 3600) -> Bool {
        guard let old else { return true }
        guard checks == old.checks, discussion == old.discussion, unresolved == old.unresolved else { return true }
        func behind(_ saved: Date?, _ now: Date?) -> Bool {
            guard let saved, let now else { return (saved == nil) != (now == nil) }
            return now.timeIntervalSince(saved) > slack
        }
        return behind(old.checksAt, checksAt) || behind(old.discussionAt, discussionAt)
    }
}

/// Reads and writes the per-PR cache files. Writes run in order on one queue, which also owns what each file holds.
final class FetchCacheStore {
    let dir: URL
    private let queue = DispatchQueue(label: "agentboard.fetch-cache", qos: .utility)
    private var saved: [String: FetchCacheEntry] = [:]

    init(dir: URL) { self.dir = dir }

    func fileURL(_ key: String) -> URL {
        let name = key.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")) ?? key
        return dir.appendingPathComponent(name + ".json")
    }

    func load() -> FetchCache {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        let entries = urls.filter { $0.pathExtension == "json" }.compactMap { url in
            (try? Data(contentsOf: url)).flatMap { try? decoder.decode(FetchCacheEntry.self, from: $0) }
        }
        queue.sync { saved = Dictionary(entries.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a }) }
        return FetchCache(entries: entries)
    }

    /// `done` runs on the store's queue with the keys written and removed.
    func save(_ cache: FetchCache, done: (([String], [String]) -> Void)? = nil) {
        queue.async { [self] in
            let entries = cache.pruned(now: Date()).entries
            let encoder = JSONEncoder()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var written: [String] = []
            for (key, entry) in entries where entry.needsWrite(over: saved[key]) {
                guard let data = try? encoder.encode(entry), (try? data.write(to: fileURL(key), options: .atomic)) != nil else { continue }
                saved[key] = entry
                written.append(key)
            }
            let removed = saved.keys.filter { entries[$0] == nil }
            for key in removed {
                try? FileManager.default.removeItem(at: fileURL(key))
                saved[key] = nil
            }
            done?(written, removed)
        }
    }
}
