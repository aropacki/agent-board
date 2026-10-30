import AppKit
import SwiftUI

extension Board {
    /// Keeps every board PR's checks warm, and the discussions of PRs with open feedback, so the hover
    /// list, the checks view, and the comments open at once.
    func prefetch() {
        var seen = Set<String>()
        let prs = (allPRs + (state?.allCards ?? []).flatMap(\.prs)).filter { $0.hidden != true && seen.insert($0.key).inserted }
        loadChecks(prs.filter { Date().timeIntervalSince(checksFetchedAt[$0.key] ?? .distantPast) > 45 })
        prefetchDiscussions(prs)
    }

    /// A comment the board announces is fetched as it is announced, so opening the PR shows it at once.
    func prefetchDiscussions(_ prs: [PR]) {
        let fresh = prs.filter { commentedSinceFetch($0) }
        let stale = prs.filter { pr in
            guard pr.unresolved > 0 || pr.hasFeedback, !commentedSinceFetch(pr) else { return false }
            return discussionsUnresolved[pr.key] != pr.unresolved
                || Date().timeIntervalSince(discussionsFetchedAt[pr.key] ?? .distantPast) > 300
        }
        (fresh + stale).prefix(4).forEach { loadDiscussion($0) }
    }

    func commentedSinceFetch(_ pr: PR) -> Bool {
        guard let newest = pr.unread.map(\.at).max() else { return false }
        return newest > (discussionsFetchedAt[pr.key]?.timeIntervalSince1970 ?? 0)
    }

    func restoreFetchCache() {
        let cache = fetchCacheStore.load().pruned(now: Date())
        checks = cache.checks
        checksFetchedAt = cache.checksAt
        discussions = cache.discussions
        discussionsFetchedAt = cache.discussionsAt
        discussionsUnresolved = cache.discussionsUnresolved
    }

    /// Batches the writes: a prefetch lands many results within a second or two.
    func saveFetchCache() {
        guard !isBench else { return }
        cacheSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            fetchCacheStore.save(FetchCache(checks: self.checks, checksAt: self.checksFetchedAt, discussions: self.discussions,
                                            discussionsAt: self.discussionsFetchedAt, discussionsUnresolved: self.discussionsUnresolved))
        }
        cacheSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// Reacts to file changes instead of polling, so a prompt or a finished chat shows within a second.
    func watch(_ path: String, events: DispatchSource.FileSystemEvent = .write, onGone: (() -> Void)? = nil,
                       _ handler: @escaping () -> Void) {
        let fd = Darwin.open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: .main)
        source.setEventHandler { [weak source] in
            guard let source else { return }
            if !source.data.isDisjoint(with: [.delete, .rename]) {
                source.cancel()
                onGone?()
            } else {
                handler()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watchers.append(source)
    }

    func watchJournal() {
        let events = boardDir.appendingPathComponent("journal/events.jsonl").path
        guard FileManager.default.fileExists(atPath: events) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.watchJournal() }
            return
        }
        watch(events, events: [.write, .extend, .delete, .rename], onGone: { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.watchJournal() }
        }) { [weak self] in
            guard let self else { return }
            self.journalCollect?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.collect() }
            self.journalCollect = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
    }

    /// Reads, decodes, and diffs off the main thread; the main thread only takes a changed state.
    func reload() {
        decodeQueue.async { [weak self] in
            guard let self,
                  let attrs = try? FileManager.default.attributesOfItem(atPath: stateURL.path),
                  let modified = attrs[.modificationDate] as? Date, modified != self.lastModified,
                  let data = try? Data(contentsOf: stateURL) else { return }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            guard let decoded = try? decoder.decode(BoardState.self, from: data) else {
                DispatchQueue.main.async { self.refreshFailed("state", "Couldn't read the board's state file. Showing the last good copy.") }
                return
            }
            self.lastModified = modified
            let previous = self.lastDecoded
            self.lastDecoded = decoded
            let changed = previous == nil || previous?.cards != decoded.cards
                || previous?.looseSlots != decoded.looseSlots || previous?.prs != decoded.prs
            DispatchQueue.main.async {
                self.generatedAt = decoded.generatedAt
                self.refreshSucceeded("state")
                self.notePRRefresh(decoded, explicit: false)
                guard changed else { return }
                self.present(decoded)
                if !isBench { self.prefetchDiscussions(self.allPRs.filter { $0.hidden != true }) }
                if let previous {
                    let events = tickerEvents(from: previous, to: decoded)
                    self.pushTicker(events)
                    self.alert?(events)
                }
            }
        }
    }

    /// The first board appears at once; later ones animate their changes in, after any scroll in progress settles.
    func present(_ decoded: BoardState) {
        if state == nil { state = decoded; return }
        guard scrolling.isEmpty else { heldState = decoded; return }
        withAnimation(.snappy(duration: 0.3)) { state = decoded }
    }

    func scrollMoved(_ id: UUID, moving: Bool) {
        if moving { scrolling.insert(id) } else { scrolling.remove(id) }
        if scrolling.isEmpty, let held = heldState {
            heldState = nil
            present(held)
        }
    }

    func collect(fresh: Bool = false) {
        guard !isBench else { return }
        if collecting {
            pendingCollect = (pendingCollect ?? false) || fresh
            return
        }
        collecting = true
        lastCollect = Date()
        if fresh { refreshing = true }
        DispatchQueue.global(qos: .utility).async {
            let (code, output) = runTool("/usr/bin/python3", fresh ? [collectScript, "--fresh"] : [collectScript], qos: .utility)
            DispatchQueue.main.async {
                self.collecting = false
                if fresh { self.refreshing = false }
                if code == 0 {
                    self.refreshSucceeded("collector")
                } else {
                    let last = output.split(separator: "\n").last.map { String($0.prefix(140)) }
                    self.refreshFailed("collector", "Couldn't refresh the board" + (last.map { " (\($0))" } ?? "."), explicit: fresh)
                }
                self.reload()
                if fresh, code == 0 {
                    // The decode queue is serial, so this reads the state the reload above takes.
                    self.decodeQueue.async { [weak self] in
                        guard let self, let state = self.lastDecoded else { return }
                        DispatchQueue.main.async { self.notePRRefresh(state, explicit: true) }
                    }
                }
                if let next = self.pendingCollect {
                    self.pendingCollect = nil
                    self.collect(fresh: next)
                }
            }
        }
    }

    func collectIfStale() {
        if Date().timeIntervalSince(lastCollect) > 3 { collect() }
    }

    func markSeen(_ id: String) {
        var seen = (try? JSONSerialization.jsonObject(with: Data(contentsOf: seenURL))) as? [String: Double] ?? [:]
        seen[id] = Date().timeIntervalSince1970
        if let data = try? JSONSerialization.data(withJSONObject: seen) { try? data.write(to: seenURL, options: .atomic) }
    }

    /// A source toasts when it starts failing, then stays quiet until it recovers. `explicit` is a
    /// refresh the user asked for, which always reports.
    func refreshFailed(_ source: String, _ message: String, explicit: Bool = false) {
        if failingRefreshes.insert(source).inserted || explicit { show(.error, message) }
    }

    func refreshSucceeded(_ source: String) { failingRefreshes.remove(source) }

    func notePRRefresh(_ state: BoardState, explicit: Bool) {
        guard let error = state.prError else { refreshSucceeded("github"); return }
        let minutes = state.prsFetchedAt.map { Int((Date().timeIntervalSince1970 - $0) / 60) } ?? 0
        let age = minutes >= 1 ? " Showing PRs from \(minutes) min ago." : ""
        refreshFailed("github", "Couldn't refresh PRs from GitHub (\(error)).\(age)", explicit: explicit)
    }
}
