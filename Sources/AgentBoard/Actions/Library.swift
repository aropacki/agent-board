import AppKit

/// A rule, skill, or command from Cursor's own folders, ready to become a quick action.
struct LibraryItem: Identifiable, Equatable {
    enum Kind: String {
        case skill, rule, command
        var icon: String {
            switch self {
            case .skill: return "sparkles"
            case .rule: return "text.book.closed"
            case .command: return "terminal"
            }
        }
    }
    let kind: Kind
    let name: String
    let about: String
    let path: String
    let source: String
    var id: String { path }
    var shortPath: String { (path as NSString).abbreviatingWithTildeInPath }

    func matches(_ query: String) -> Bool {
        let words = query.lowercased().split(separator: " ")
        let text = "\(name) \(about) \(source) \(kind.rawValue)".lowercased()
        return words.allSatisfy { text.contains($0) }
    }

    var actionTemplate: String {
        switch kind {
        case .skill: return "Use the \(name) skill: read \(shortPath) and follow it.\n\n{{target}}"
        case .rule: return "Follow the rule in \(shortPath).\n\n{{target}}"
        case .command: return "Run the /\(name) command: read \(shortPath) and follow it.\n\n{{target}}"
        }
    }

    var actionTitle: String {
        let words = name.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

enum Library {
    /// Front matter fields and the text after them. Handles one-line values and folded `>` or `|` blocks.
    static func parse(_ text: String) -> (fields: [String: String], body: String) {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return ([:], text) }
        var fields: [String: String] = [:]
        var key: String?
        var block: [String] = []
        func flush() {
            if let key, !block.isEmpty { fields[key] = block.joined(separator: " ") }
            block = []
        }
        for line in lines[1..<end] {
            if let m = line.range(of: #"^([A-Za-z_][A-Za-z0-9_-]*):\s*(.*)$"#, options: .regularExpression), m.lowerBound == line.startIndex {
                flush()
                let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
                let k = parts[0].trimmingCharacters(in: .whitespaces)
                var value = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
                if [">", "|", ">-", "|-"].contains(value) { key = k; continue }
                if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q { value = String(value.dropFirst().dropLast()) }
                fields[k] = value
                key = nil
            } else if key != nil {
                let t = line.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { block.append(t) }
            }
        }
        flush()
        return (fields, lines[(end + 1)...].joined(separator: "\n"))
    }

    static func item(_ path: String, kind: LibraryItem.Kind, source: String) -> LibraryItem? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let (fields, body) = parse(text)
        let url = URL(fileURLWithPath: path)
        let fileName = url.deletingPathExtension().lastPathComponent
        let name = fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? (kind == .skill ? url.deletingLastPathComponent().lastPathComponent : fileName)
        let firstLine = body.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("<") } ?? ""
        let about = fields["description"].flatMap { $0.isEmpty ? nil : $0 } ?? firstLine
        return LibraryItem(kind: kind, name: name, about: about, path: path, source: source)
    }

    /// Files under `dir` named like `match`, skipping git folders and dependencies.
    static func files(_ dir: String, depth: Int, _ match: (URL) -> Bool) -> [URL] {
        let root = URL(fileURLWithPath: dir)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        let base = root.pathComponents.count
        for case let url as URL in walker {
            let name = url.lastPathComponent
            if name == ".git" || name == "node_modules" { walker.skipDescendants(); continue }
            if url.pathComponents.count - base > depth { walker.skipDescendants(); continue }
            if match(url) { out.append(url) }
        }
        return out
    }

    /// Your rules and skills first, then each tool's own, the library repo's, and each plugin's. A name seen twice in one
    /// source keeps its newest copy.
    static func scan(home: String = NSHomeDirectory(), repo: String? = Config.shared.libraryRepo) -> [LibraryItem] {
        let skill: (URL) -> Bool = { $0.lastPathComponent == "SKILL.md" }
        let rule: (URL) -> Bool = { $0.pathExtension == "mdc" }
        let command: (URL) -> Bool = { $0.pathExtension == "md" }
        var found: [(LibraryItem, Date)] = []
        func add(_ urls: [URL], _ kind: LibraryItem.Kind, _ source: String) {
            for url in urls {
                guard let item = item(url.path, kind: kind, source: source) else { continue }
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                found.append((item, date))
            }
        }
        func matcher(_ kind: LibraryItem.Kind) -> (URL) -> Bool {
            switch kind {
            case .skill: return skill
            case .rule: return rule
            case .command: return command
            }
        }
        // Every known tool's folders, enabled or not: a folder that exists is one the user keeps prompts in.
        let shared = LibraryDir(path: home + "/.agents/skills", depth: 3, kind: .skill, source: "Your skills")
        for dir in [shared] + Tools.known.flatMap({ $0.libraryDirs(home: home) }) {
            add(files(dir.path, depth: dir.depth, matcher(dir.kind)), dir.kind, dir.source)
        }
        let repoSource = repo.map { URL(fileURLWithPath: $0).lastPathComponent + " repo" }
        if let repo, let repoSource {
            add(files(repo + "/.agents/skills", depth: 3, skill), .skill, repoSource)
            add(files(repo + "/.claude/skills", depth: 3, skill), .skill, repoSource)
            add(files(repo + "/.cursor/rules", depth: 3, rule), .rule, repoSource)
        }
        var pluginNames: [String: String] = [:]
        for cache in Tools.known.compactMap({ $0.pluginCache(home: home) }) {
            for url in files(cache.path, depth: 8, { skill($0) || rule($0) }) {
                let parts = url.pathComponents
                let base = URL(fileURLWithPath: cache.path).pathComponents.count
                guard parts.count > base + 3 else { continue }
                let isSkill = skill(url)
                guard parts[parts.count - (isSkill ? 3 : 2)] == (isSkill ? "skills" : "rules") else { continue }
                let version = parts[0...(base + 2)].joined(separator: "/").replacingOccurrences(of: "//", with: "/")
                if pluginNames[version] == nil {
                    let manifest = (try? Data(contentsOf: URL(fileURLWithPath: version + "/" + cache.manifest)))
                        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    pluginNames[version] = manifest?["name"] as? String ?? parts[base + 1]
                }
                add([url], isSkill ? .skill : .rule, "Plugin · \(pluginNames[version]!)")
            }
        }
        var newest: [String: (LibraryItem, Date)] = [:]
        var order: [String] = []
        for (item, date) in found {
            let key = "\(item.source)|\(item.kind.rawValue)|\(item.name)"
            if let seen = newest[key] {
                if date > seen.1 { newest[key] = (item, date) }
            } else {
                newest[key] = (item, date)
                order.append(key)
            }
        }
        let sources = ["Your rules", "Your skills", "Personal store", "Your commands", "Cursor"] + (repoSource.map { [$0] } ?? [])
        return order.compactMap { newest[$0]?.0 }.sorted {
            let a = sources.firstIndex(of: $0.source) ?? sources.count, b = sources.firstIndex(of: $1.source) ?? sources.count
            return (a, $0.source, $0.name.lowercased()) < (b, $1.source, $1.name.lowercased())
        }
    }
}
