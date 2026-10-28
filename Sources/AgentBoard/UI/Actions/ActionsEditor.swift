import AppKit
import SwiftUI

struct LibraryGroup: Identifiable {
    let source: String
    let items: [LibraryItem]
    var id: String { source }
}

/// Edits the quick actions: where each shows, how it sends, and its prompt. The library lists Cursor's
/// rules, skills, and commands; any of them can become a quick action.
struct ActionsEditor: View, Zoomed {
    @Environment(\.zoom) var zoom
    @Environment(Board.self) private var board
    enum Pick: Hashable { case action(String), item(String) }
    @State private var pick: Pick = ActionsEditor.initialPick
    @State private var query = ""
    @State private var previewSurface: ActionSurface?
    /// The template being typed, saved after a short pause so each keystroke does not redraw the board.
    @State private var template = ""
    @State private var templateFor = ""
    @State private var confirmDelete: String?
    @State private var fileText = ""
    @State private var fileFor = ""

    static var initialPick: Pick {
        let p = ProcessInfo.processInfo.environment["BENCH_ACTIONS_PICK"] ?? "review"
        return p.hasPrefix("/") ? .item(p) : .action(p)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(T.border).frame(width: 1)
            Group {
                switch pick {
                case .action(let id):
                    if let a = board.quickActions.first(where: { $0.id == id }) { actionDetail(a) } else { placeholder }
                case .item(let path):
                    if let item = board.library?.first(where: { $0.path == path }) { itemDetail(item) } else { placeholder }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear {
            load()
            board.loadLibrary()
        }
        .onChange(of: pick) {
            flush()
            load()
            confirmDelete = nil
        }
        .onDisappear { flush() }
        .task(id: template) {
            try? await Task.sleep(for: .milliseconds(350))
            if !Task.isCancelled { flush() }
        }
    }

    var placeholder: some View {
        Text(board.library == nil ? "Loading…" : "Pick a quick action, or something from the library.")
            .font(ui(12.5)).foregroundStyle(T.text3).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Sidebar

    var sidebar: some View {
        let words = query.lowercased().split(separator: " ")
        let actions = board.quickActions.filter { a in
            let text = "\(a.title) \(a.template) \(a.source ?? "")".lowercased()
            return words.allSatisfy { text.contains($0) }
        }
        let items = (board.library ?? []).filter { query.isEmpty || $0.matches(query) }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: z(6)) {
                Image(systemName: "magnifyingglass").font(.system(size: z(11))).foregroundStyle(T.text3)
                TextField("Search actions, rules, skills, commands", text: $query)
                    .textFieldStyle(.plain).font(ui(12.5)).foregroundStyle(T.text)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: z(11))).foregroundStyle(T.text3)
                    }
                    .buttonStyle(.plain).pointerOnly()
                }
            }
            .padding(.horizontal, z(10)).frame(height: z(30))
            .background(RoundedRectangle(cornerRadius: z(8), style: .continuous).fill(T.text.opacity(0.05)))
            .padding(z(10))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: z(1)) {
                    sectionHeader("Quick actions") { QuietButton(title: "New", icon: "plus") { addBlank() } }
                    ForEach(actions) { actionRow($0) }
                    if actions.isEmpty { sidebarNote("No quick action matches.") }
                    sectionHeader("Library") {
                        Button { board.loadLibrary(force: true) } label: {
                            ZStack {
                                if board.libraryScanning { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise") }
                            }
                            .font(.system(size: z(10), weight: .medium)).foregroundStyle(T.text3).frame(width: z(14), height: z(14))
                        }
                        .buttonStyle(HoverButtonStyle.icon).pointerOnly()
                        .help("Scan the folders again")
                    }
                    if board.library == nil {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, z(12))
                    } else if items.isEmpty {
                        sidebarNote(query.isEmpty ? "No rules, skills, or commands found." : "Nothing in the library matches.")
                    }
                    ForEach(groups(items)) { g in
                        Text(g.source).font(ui(11, .medium)).foregroundStyle(T.text3)
                            .padding(.horizontal, z(8)).padding(.top, z(8)).padding(.bottom, z(2))
                        ForEach(g.items) { itemRow($0) }
                    }
                }
                .padding(.horizontal, z(10)).padding(.bottom, z(20))
            }
            .scrollIndicators(.automatic)
            Rectangle().fill(T.border).frame(height: 1)
            Text("Saved to ~/.agent-board/actions.json").font(ui(11)).foregroundStyle(T.text3)
                .padding(.horizontal, z(18)).frame(height: z(30))
        }
        .frame(width: z(290))
    }

    func groups(_ items: [LibraryItem]) -> [LibraryGroup] {
        var order: [String] = []
        var bySource: [String: [LibraryItem]] = [:]
        for item in items {
            if bySource[item.source] == nil { order.append(item.source) }
            bySource[item.source, default: []].append(item)
        }
        return order.map { LibraryGroup(source: $0, items: bySource[$0] ?? []) }
    }

    func sectionHeader<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: z(6)) {
            Text(title).font(ui(11.5, .semibold)).foregroundStyle(T.text2)
            Spacer()
            trailing()
        }
        .padding(.horizontal, z(8)).padding(.top, z(10)).padding(.bottom, z(4))
    }

    func sidebarNote(_ text: String) -> some View {
        Text(text).font(ui(11.5)).foregroundStyle(T.text3).padding(.horizontal, z(8)).padding(.vertical, z(6))
    }

    func actionRow(_ a: QuickAction) -> some View {
        let on = pick == .action(a.id)
        return Button { pick = .action(a.id) } label: {
            HStack(spacing: z(8)) {
                Image(systemName: a.icon).font(.system(size: z(11))).foregroundStyle(a.enabled ? T.text2 : T.text3).frame(width: z(16))
                Text(a.title).font(ui(12.5, on ? .medium : .regular)).foregroundStyle(a.enabled ? T.text : T.text3).lineLimit(1)
                Spacer(minLength: z(4))
                Text(a.enabled ? placesSummary(a) : "off").font(ui(11)).foregroundStyle(T.text3).lineLimit(1)
            }
            .padding(.horizontal, z(8)).frame(height: z(28))
            .background(T.control.fill(on ? T.text.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerOnly()
        .pointerStyle(.link)
    }

    func placesSummary(_ a: QuickAction) -> String {
        switch a.placements.count {
        case 0: return "nowhere"
        case 1: return a.placements[0].surface.title
        default: return "\(a.placements.count) places"
        }
    }

    func itemRow(_ item: LibraryItem) -> some View {
        let on = pick == .item(item.path)
        return Button { pick = .item(item.path) } label: {
            HStack(alignment: .top, spacing: z(8)) {
                Image(systemName: item.kind.icon).font(.system(size: z(10.5))).foregroundStyle(T.text3).frame(width: z(16)).padding(.top, z(2))
                VStack(alignment: .leading, spacing: z(1)) {
                    Text(item.name).font(ui(12.5, on ? .medium : .regular)).foregroundStyle(T.text).lineLimit(1)
                    if !item.about.isEmpty { Text(item.about).font(ui(11)).foregroundStyle(T.text3).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, z(8)).padding(.vertical, z(5))
            .background(T.control.fill(on ? T.text.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerOnly()
        .pointerStyle(.link)
        .help(item.shortPath)
    }

    // MARK: Action detail

    func actionDetail(_ a: QuickAction) -> some View {
        let id = a.id
        var draft = a
        if templateFor == id { draft.template = template }
        let surfaces = a.placements.map(\.surface)
        let shown = previewSurface.flatMap { surfaces.contains($0) ? $0 : nil } ?? surfaces.first ?? .pr
        let index = board.quickActions.firstIndex { $0.id == id } ?? 0
        return ScrollView {
            VStack(alignment: .leading, spacing: z(18)) {
                HStack(spacing: z(10)) {
                    Menu {
                        ForEach(QuickAction.icons, id: \.self) { name in
                            Button { update(id) { $0.icon = name } } label: { Label(name, systemImage: name) }
                        }
                    } label: {
                        Image(systemName: a.icon).font(.system(size: z(14), weight: .medium)).foregroundStyle(T.text)
                            .frame(width: z(32), height: z(32))
                            .background(RoundedRectangle(cornerRadius: z(8), style: .continuous).fill(T.text.opacity(0.06)))
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().pointerOnly()
                    .help("Pick an icon")
                    VStack(alignment: .leading, spacing: z(2)) {
                        TextField("Title", text: field(id, \.title, ""))
                            .textFieldStyle(.plain).font(ui(16, .semibold)).foregroundStyle(T.text)
                        Text(origin(a)).font(ui(11.5)).foregroundStyle(T.text3).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: z(8))
                    Toggle(isOn: field(id, \.enabled, true)) { Text("On").font(ui(12)).foregroundStyle(T.text2) }
                        .toggleStyle(.switch).controlSize(.small)
                }

                group("Where it shows", a.placements.isEmpty ? "Pick at least one place, or it shows nowhere." : nil) {
                    VStack(alignment: .leading, spacing: z(2)) {
                        ForEach(ActionSurface.allCases) { surfaceRow(a, $0) }
                    }
                }

                group("How it sends", nil) {
                    VStack(alignment: .leading, spacing: z(6)) {
                        HStack(spacing: z(4)) {
                            ToggleChip(title: "Its own agent chat", icon: "text.bubble", on: a.delivery == .ownChat) { update(id) { $0.delivery = .ownChat } }
                            ToggleChip(title: "A new agent chat", icon: "plus.bubble", on: a.delivery == .newChat) { update(id) { $0.delivery = .newChat } }
                        }
                        Text(a.delivery == .ownChat
                             ? "Goes into the chat it was run on, or the chat that holds its worktree or all of its PRs. Opens a new chat when there is none."
                             : "Always opens a new agent chat.")
                            .font(ui(11.5)).foregroundStyle(T.text3)
                        HStack(spacing: z(4)) {
                            ToggleChip(title: "Ask first", icon: a.confirm ? "checkmark" : nil, on: a.confirm) { update(id) { $0.confirm.toggle() } }
                            ToggleChip(title: "Hide what it covers afterward", icon: a.hidesAfter ? "checkmark" : nil, on: a.hidesAfter) {
                                update(id) { $0.hidesAfter.toggle() }
                            }
                            ToggleChip(title: "Show findings in the diff", icon: a.emitsReview ? "checkmark" : "sparkles", on: a.emitsReview) {
                                update(id) { $0.emitsReview.toggle() }
                            }
                            .help("Adds a section asking the agent to write its summary, file order, and draft comments as JSON for the diff viewer")
                        }
                        .padding(.top, z(4))
                    }
                }

                group("Prompt", nil) { prompt(draft, shown: shown) }

                HStack(spacing: z(6)) {
                    if let source = a.source { QuietButton(title: "Open source", icon: "arrow.up.forward") { openSource(source) } }
                    Spacer()
                    QuietButton(title: "Move up", icon: "arrow.up") { move(id, by: -1) }.disabled(index == 0)
                    QuietButton(title: "Move down", icon: "arrow.down") { move(id, by: 1) }.disabled(index >= board.quickActions.count - 1)
                    if let builtIn = a.builtIn {
                        if draft != builtIn {
                            QuietButton(title: "Reset to default", icon: "arrow.counterclockwise") {
                                update(id) { $0 = builtIn }
                                template = builtIn.template
                            }
                        }
                    } else {
                        QuietButton(title: confirmDelete == id ? "Confirm delete" : "Delete", icon: "trash") {
                            if confirmDelete == id { delete(id) } else { confirmDelete = id }
                        }
                    }
                }
            }
            .padding(z(18))
        }
        .scrollIndicators(.automatic)
    }

    func prompt(_ a: QuickAction, shown: ActionSurface) -> some View {
        var seen = Set<String>()
        let surfaces = a.placements.isEmpty ? ActionSurface.allCases : a.placements.map(\.surface)
        let vars = surfaces.flatMap(\.variables).filter { seen.insert($0.name).inserted }
        let unknown = a.unknownNames
        return VStack(alignment: .leading, spacing: z(8)) {
            FlowLayout(spacing: z(4)) {
                ForEach(vars, id: \.name) { v in
                    Button { board.copy("{{\(v.name)}}"); board.show(.ok, "Copied {{\(v.name)}}") } label: {
                        Text("{{\(v.name)}}").font(mono(11)).foregroundStyle(T.purple)
                    }
                    .buttonStyle(HoverButtonStyle.chip).pointerOnly()
                    .help("\(v.about). Click to copy.")
                }
            }
            Text("{{#name}}…{{/name}} shows its text only when name is set. {{^name}}…{{/name}} only when it is not.")
                .font(ui(11)).foregroundStyle(T.text3)
            if !unknown.isEmpty {
                Label("No place it shows provides these, so they render as nothing: \(unknown.map { "{{\($0)}}" }.joined(separator: ", "))",
                      systemImage: "exclamationmark.triangle")
                    .font(ui(11.5)).foregroundStyle(T.orange)
            }
            HStack(alignment: .top, spacing: z(12)) {
                pane("Template") {
                    TextEditor(text: $template)
                        .font(mono(12.5)).foregroundStyle(T.text)
                        .scrollContentBackground(.hidden)
                        .padding(z(6))
                }
                VStack(alignment: .leading, spacing: z(6)) {
                    HStack(spacing: z(4)) {
                        Text("Preview on").font(ui(11.5, .medium)).foregroundStyle(T.text3)
                        ForEach(a.placements.isEmpty ? [ActionSurface.pr] : a.placements.map(\.surface)) { s in
                            ToggleChip(title: s.title, on: s == shown) { previewSurface = s }
                        }
                    }
                    ScrollView {
                        Text(ActionSamples.preview(a, on: shown))
                            .font(ui(12.5)).foregroundStyle(T.text2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(z(12))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(T.raised, in: RoundedRectangle(cornerRadius: T.rowRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: T.rowRadius, style: .continuous).strokeBorder(T.border))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: z(360))
        }
    }

    func surfaceRow(_ a: QuickAction, _ s: ActionSurface) -> some View {
        let p = a.placement(s)
        return VStack(alignment: .leading, spacing: z(6)) {
            Button { togglePlacement(a.id, s) } label: {
                HStack(alignment: .firstTextBaseline, spacing: z(8)) {
                    Image(systemName: p != nil ? "checkmark.square.fill" : "square").font(.system(size: z(12)))
                        .foregroundStyle(p != nil ? T.blue : T.text3)
                    Image(systemName: s.icon).font(.system(size: z(11))).foregroundStyle(T.text2).frame(width: z(14))
                    Text(s.title).font(ui(12.5, .medium)).foregroundStyle(T.text)
                    Text(s.about).font(ui(11.5)).foregroundStyle(T.text3).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, z(4))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerOnly()
            .pointerStyle(.link)
            if let p {
                VStack(alignment: .leading, spacing: z(4)) {
                    FlowLayout(spacing: z(4)) {
                        if s.choosesButton {
                            ToggleChip(title: "Also a button", icon: p.button ? "checkmark" : nil, on: p.button) {
                                editPlacement(a.id, s) { $0.button.toggle() }
                            }
                        }
                        ForEach(s.conditions, id: \.self) { c in
                            ToggleChip(title: c.title, icon: p.when.contains(c) ? "checkmark" : nil, on: p.when.contains(c)) {
                                toggleCondition(a.id, s, c)
                            }
                        }
                    }
                    Text(placementNote(p, s)).font(ui(11)).foregroundStyle(T.text3)
                }
                .padding(.leading, z(42)).padding(.bottom, z(6))
            }
        }
    }

    func placementNote(_ p: Placement, _ s: ActionSurface) -> String {
        let place: String
        switch s {
        case .pr, .stack, .agent: place = p.button ? "In the ⋯ menu and as a button" : "In the ⋯ menu"
        case .worktree: place = "In the ⋯ menu"
        case .check: place = "In the right-click menu"
        case .selection, .thread, .comment: place = "As a button"
        }
        let when = p.when.isEmpty ? ", always." : ", only when: " + p.when.map(\.title).joined(separator: " · ") + "."
        let narrows = p.when.contains(where: \.filtersPRs) ? " It covers only the PRs that match." : ""
        return place + when + narrows
    }

    func group<Content: View>(_ title: String, _ note: String?, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: z(8)) {
            HStack(spacing: z(8)) {
                Text(title).font(ui(12.5, .semibold)).foregroundStyle(T.text)
                if let note { Text(note).font(ui(11.5)).foregroundStyle(T.orange) }
            }
            content()
        }
    }

    func pane<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: z(6)) {
            Text(title).font(ui(11.5, .medium)).foregroundStyle(T.text3).frame(height: z(22), alignment: .leading)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(T.raised, in: RoundedRectangle(cornerRadius: T.rowRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: T.rowRadius, style: .continuous).strokeBorder(T.border))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func origin(_ a: QuickAction) -> String {
        if a.builtIn != nil { return "Built in" }
        return a.source.map { "From " + ($0 as NSString).abbreviatingWithTildeInPath } ?? "Your own"
    }

    // MARK: Library detail

    func itemDetail(_ item: LibraryItem) -> some View {
        let existing = board.quickActions.first { $0.source == item.path }
        return VStack(alignment: .leading, spacing: z(12)) {
            HStack(spacing: z(10)) {
                Image(systemName: item.kind.icon).font(.system(size: z(14), weight: .medium)).foregroundStyle(T.text)
                    .frame(width: z(32), height: z(32))
                    .background(RoundedRectangle(cornerRadius: z(8), style: .continuous).fill(T.text.opacity(0.06)))
                VStack(alignment: .leading, spacing: z(2)) {
                    Text(item.name).font(ui(16, .semibold)).foregroundStyle(T.text)
                    Text("\(item.source) · \(item.kind.rawValue)").font(ui(11.5)).foregroundStyle(T.text3)
                }
                Spacer(minLength: z(8))
                if let existing {
                    QuietButton(title: "Already a quick action: \(existing.title)", icon: "arrow.right") { pick = .action(existing.id) }
                } else {
                    Button { add(item) } label: {
                        HStack(spacing: z(5)) {
                            Image(systemName: "plus").font(.system(size: z(10), weight: .semibold))
                            Text("Add as a quick action").font(ui(12, .medium))
                        }
                        .foregroundStyle(T.text)
                    }
                    .buttonStyle(HoverButtonStyle.action).pointerOnly()
                }
            }
            if !item.about.isEmpty {
                Text(item.about).font(ui(12.5)).foregroundStyle(T.text2).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: z(6)) {
                Text(item.shortPath).font(mono(11)).foregroundStyle(T.text3).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: z(4))
                QuietButton(title: "Open in Cursor", icon: "arrow.up.forward") { openSource(item.path) }
            }
            pane("File") {
                ScrollView {
                    Text(fileFor == item.path ? fileText : "")
                        .font(mono(11.5)).foregroundStyle(T.text2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(z(12))
                }
            }
        }
        .padding(z(18))
        .task(id: item.path) {
            let text = (try? String(contentsOfFile: item.path, encoding: .utf8)) ?? "Couldn't read the file."
            fileText = text.count > 20_000 ? String(text.prefix(20_000)) + "\n…" : text
            fileFor = item.path
        }
    }

    // MARK: Edits

    func field<V>(_ id: String, _ path: WritableKeyPath<QuickAction, V>, _ fallback: V) -> Binding<V> {
        Binding(get: { board.quickActions.first { $0.id == id }?[keyPath: path] ?? fallback },
                set: { value in update(id) { $0[keyPath: path] = value } })
    }

    func update(_ id: String, _ change: (inout QuickAction) -> Void) {
        board.editActions { list in
            guard let i = list.firstIndex(where: { $0.id == id }) else { return }
            change(&list[i])
        }
    }

    func editPlacement(_ id: String, _ s: ActionSurface, _ change: (inout Placement) -> Void) {
        update(id) { a in
            guard let i = a.placements.firstIndex(where: { $0.surface == s }) else { return }
            change(&a.placements[i])
        }
    }

    func togglePlacement(_ id: String, _ s: ActionSurface) {
        update(id) { a in
            if let i = a.placements.firstIndex(where: { $0.surface == s }) {
                a.placements.remove(at: i)
            } else {
                a.placements.append(Placement(s))
            }
        }
    }

    func toggleCondition(_ id: String, _ s: ActionSurface, _ c: ActionCondition) {
        editPlacement(id, s) { p in
            if let i = p.when.firstIndex(of: c) {
                p.when.remove(at: i)
            } else {
                if c == .mine { p.when.removeAll { $0 == .others } }
                if c == .others { p.when.removeAll { $0 == .mine } }
                p.when.append(c)
            }
        }
    }

    func move(_ id: String, by step: Int) {
        board.editActions { list in
            guard let i = list.firstIndex(where: { $0.id == id }), list.indices.contains(i + step) else { return }
            list.swapAt(i, i + step)
        }
    }

    func delete(_ id: String) {
        let title = board.quickActions.first { $0.id == id }?.title ?? "it"
        board.editActions { $0.removeAll { $0.id == id } }
        templateFor = ""
        pick = .action(board.quickActions.first?.id ?? "")
        board.show(.ok, "Deleted “\(title)”")
    }

    func addBlank() {
        let a = QuickAction(id: "custom-\(UUID().uuidString.prefix(8).lowercased())", title: "New action", icon: "sparkles",
                            template: "{{target}}", placements: [])
        board.editActions { $0.append(a) }
        query = ""
        pick = .action(a.id)
    }

    func add(_ item: LibraryItem) {
        let a = QuickAction(id: "custom-\(UUID().uuidString.prefix(8).lowercased())", title: item.actionTitle, icon: item.kind.icon,
                            template: item.actionTemplate, placements: [], source: item.path)
        board.editActions { $0.append(a) }
        pick = .action(a.id)
        board.show(.ok, "Added “\(a.title)”. Pick where it shows.")
    }

    func load() {
        guard case .action(let id) = pick, let a = board.quickActions.first(where: { $0.id == id }) else { return }
        template = a.template
        templateFor = id
    }

    func flush() {
        let id = templateFor, text = template
        guard !id.isEmpty, board.quickActions.first(where: { $0.id == id })?.template != text else { return }
        update(id) { $0.template = text }
    }

    func openSource(_ path: String) {
        Tools.primary.openFile(path)
    }
}
