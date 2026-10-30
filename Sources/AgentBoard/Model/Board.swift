import AppKit
import notify
import ApplicationServices
import SwiftUI

enum ToastKind { case ok, error }

struct Toast: Equatable { let kind: ToastKind; let text: String; let id = UUID() }

@Observable
final class Board {
    var state: BoardState? {
        didSet { if prsFetchedAt != state?.prsFetchedAt { prsFetchedAt = state?.prsFetchedAt } }
    }
    /// Kept apart from `state` so views that only compare against it don't redraw on every state update.
    private(set) var prsFetchedAt: Double?
    var generatedAt: Double?
    var toast: Toast?
    @ObservationIgnored var failingRefreshes: Set<String> = []
    /// A refresh re-lays out every row, which would stutter a scroll, so it waits in `heldState` until scrolls stop.
    @ObservationIgnored var scrolling: Set<UUID> = []
    @ObservationIgnored var heldState: BoardState?
    var busy: Set<String> = []
    var selected: [String] = []
    var pendingAction: PendingAction?
    var quickActions: [QuickAction] = isBench ? QuickAction.defaults : ActionStore.load()
    @ObservationIgnored var actionsSave: DispatchWorkItem?
    var library: [LibraryItem]?
    var libraryScanning = false
    var menu: RowMenu?
    /// Where each right-clickable row is, so one event monitor can open the right menu.
    @ObservationIgnored var menuOpenedAt = Date.distantPast
    @ObservationIgnored var menuTargets: [UUID: (surface: String, owner: String, frame: CGRect, viewport: String)] = [:]
    @ObservationIgnored var menuViewports: [String: (surface: String, frame: CGRect)] = [:]
    /// Shows or hides the popup window when the board or the diff viewer opens or closes.
    @ObservationIgnored var popupChanged: (() -> Void)?
    /// Raises system banners for the events that wait on you.
    @ObservationIgnored var alert: (([TickerEvent]) -> Void)?
    var windowVisible = false
    var boardOpen = false
    /// The popup's own fade and scale. It leads the window on the way in and trails it on the way out.
    var popupPresented = false
    /// The popup screen's menu bar and Dock, which the cards stay clear of.
    var popupSafe = EdgeInsets()
    var diffDraft = ""
    var reviews: [String: AgentReview] = [:]
    var reviewErrors: [String: String] = [:]
    @ObservationIgnored var reviewStamps: [String: Date] = [:]
    @ObservationIgnored var reviewsLoaded = false
    var showActions = false
    /// Pulses run while either the panel is in front or the full window is on screen.
    var animating: Bool { isFront || windowVisible }
    var succeeded: Set<String> = []
    var refreshing = false
    var trusted = Board.checkTrust()
    /// macOS shows the Accessibility prompt only once per binary, so later presses go straight to Settings.
    @ObservationIgnored var trustPrompted = false
    var confirmReturn: String?
    var isFront = false
    var now = Date()
    var tickerNote: TickerEvent?
    var tickerLast: TickerEvent? = loadActivity().last
    var activity: [TickerEvent] = loadActivity()
    var activitySeenAt = UserDefaults.standard.object(forKey: "activitySeenAt") as? Date ?? .distantPast
    var unreadActivity: Int { activity.filter { $0.at > activitySeenAt }.count }
    /// The PR whose comments are open, and on which surface.
    var discussion: (key: String, surface: String)?
    var discussions: [String: PRDiscussion] = [:]
    var discussionLoading: Set<String> = []
    var discussionErrors: [String: String] = [:]
    var diffOpen: DiffTarget?
    var diffs: [String: PRDiff] = [:]
    var diffLoading: Set<String> = []
    var diffErrors: [String: String] = [:]
    var overviews: [String: PROverview] = [:]
    var overviewLoading: Set<String> = []
    var overviewErrors: [String: String] = [:]
    var diffSelection: DiffSelection?
    /// A drag is picking lines, so the comment box waits until it ends.
    var diffDragging = false
    /// Bumps when a pick ends, which focuses the comment box.
    var diffComposerFocus = 0
    /// Notes opened past their glance, by file path and note id. Kept here so a chunk scrolled away and back keeps them open.
    var diffOpenNotes: Set<String> = []
    /// Files marked reviewed, by PR key and path, with the diff they were reviewed at.
    var reviewedFiles = UserDefaults.standard.dictionary(forKey: "diffReviewed") as? [String: [String: String]] ?? [:]
    @ObservationIgnored var discussionsFetchedAt: [String: Date] = [:]
    /// Each PR's unresolved count when its discussion was fetched, so a new thread refetches it.
    @ObservationIgnored var discussionsUnresolved: [String: Int] = [:]
    @ObservationIgnored var cacheSave: DispatchWorkItem?
    /// The PR whose checks are open, and on which surface.
    var checksOpen: (key: String, surface: String)?
    var checks: [String: [CICheck]] = [:]
    var checksLoading: Set<String> = []
    var checksErrors: [String: String] = [:]
    @ObservationIgnored var checksFetchedAt: [String: Date] = [:]
    /// The checks list shown while the pointer rests on a PR's CI fact, drawn like a row menu.
    var checksPeek: ChecksPeek?
    @ObservationIgnored var peekFact: ChecksPeek?
    @ObservationIgnored var peekOverList = false
    @ObservationIgnored var peekWork: DispatchWorkItem?
    /// A reply has text in it, so the panel stays out while the pointer wanders.
    @ObservationIgnored var composing = false
    /// The diff note just jumped to, lit for a moment so the eye finds it.
    var diffFlash: String?
    /// Keeps the popup up while an action types into Cursor behind it, and gives it the keyboard back after.
    @ObservationIgnored var holdPopup: ((Bool) -> Void)?
    @ObservationIgnored var menuSurface = "panel"
    var tickerNotchInset: CGFloat = 0
    @ObservationIgnored var needsClock = NeedsClock(
        waited: UserDefaults.standard.dictionary(forKey: "needsActiveSeconds") as? [String: Double] ?? [:])
    @ObservationIgnored var tickerQueue: [TickerEvent] = []
    @ObservationIgnored var lastModified: Date?
    @ObservationIgnored var lastDecoded: BoardState?
    @ObservationIgnored let decodeQueue = DispatchQueue(label: "agentboard.decode", qos: .userInitiated)
    @ObservationIgnored var collecting = false
    @ObservationIgnored var pendingCollect: Bool?
    @ObservationIgnored var lastCollect = Date.distantPast
    @ObservationIgnored var watchers: [DispatchSourceFileSystemObject] = []
    @ObservationIgnored var journalCollect: DispatchWorkItem?
    @ObservationIgnored let typist = DispatchQueue(label: "agentboard.typist")

    init() {
        if !isBench { restoreFetchCache() }
        reload()
        try? FileManager.default.createDirectory(at: reviewsDir, withIntermediateDirectories: true)
        if !isBench { loadReviews() }
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.reload()
            if !isBench { self.loadReviews() }
            let t = Board.checkTrust()
            if self.trusted != t {
                withAnimation(.snappy) { self.trusted = t }
                // A running process keeps the old Accessibility answer, so a new grant only takes effect in a fresh process.
                if t { self.relaunch() }
            }
        }
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.collect() }
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.now = Date() }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.prefetch() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.prefetch() }
        watch(boardDir.path) { [weak self] in self?.reload() }
        if !isBench { watch(reviewsDir.path) { [weak self] in self?.loadReviews() } }
        watchJournal()
        collect()
        // `notifyutil -p <bundle id>.demo` plays a sample notification without logging it.
        var token: Int32 = 0
        notify_register_dispatch((Bundle.main.bundleIdentifier ?? "agentboard") + ".demo", &token, .main) { [weak self] _ in
            self?.pushTicker([TickerEvent(kind: .review, text: "Review requested: #000 Sample notification · @agentboard")], log: false)
        }
    }

    func pr(key: String) -> PR? {
        allPRs.first { $0.key == key } ?? (state?.allCards ?? []).flatMap(\.prs).first { $0.key == key }
    }

    func openBoard() {
        closeMenu()
        showActions = false
        windowVisible = true
        if popupPresented {
            withAnimation(Motion.content) { boardOpen = true }
        } else {
            boardOpen = true
            presentPopup()
        }
        reload()
        collectIfStale()
    }

    /// Closes the diff viewer and the board together.
    func closePopup() {
        closeMenu(surface: "window")
        diffSelection = nil
        dismissPopupWindow()
    }

    /// The window is up before the state changes, so the change animates in a window that is drawing.
    func presentPopup() {
        popupChanged?()
        withAnimation(Motion.window) { popupPresented = true }
    }

    /// Fades the popup out, then takes the window down. Opening it again during the fade keeps it up.
    func dismissPopupWindow() {
        withAnimation(Motion.window) { popupPresented = false } completion: { [weak self] in
            guard let self, !self.popupPresented else { return }
            diffOpen = nil
            boardOpen = false
            windowVisible = false
            popupChanged?()
        }
    }

    /// A click outside the top card closes that card.
    func dismissPopup() {
        if diffOpen != nil { closeDiff() } else { closePopup() }
    }

    /// Escape clears a picked range, then closes the diff viewer, then the board.
    func escapePopup() -> Bool {
        if escapeDiff() { return true }
        guard boardOpen else { return false }
        closePopup()
        return true
    }

    // MARK: Agent reviews

    /// Into the PR's own agent chat when it has one, so the agent already has the branch.
    func newAgent() {
        let tool = Tools.primary
        guard ensureTrust(for: tool) else { return }
        let key = "new-agent"
        guard !busy.contains(key) else { return }
        setBusy(key, true)
        typist.async {
            let failure = tool.newChat()
            DispatchQueue.main.async {
                self.setBusy(key, false)
                if let failure { self.show(.error, failure) }
            }
        }
    }

    func show(_ kind: ToastKind, _ text: String) {
        let t = Toast(kind: kind, text: text)
        if let current = toast, current.kind == kind, current.text == text {
            toast = t
        } else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { toast = t }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (kind == .error ? 7 : 3.5)) { [weak self] in
            if self?.toast == t { withAnimation(.easeOut(duration: 0.25)) { self?.toast = nil } }
        }
    }

    func flagSuccess(_ key: String) {
        withAnimation(.snappy) { _ = succeeded.insert(key) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            withAnimation(.snappy) { _ = self?.succeeded.remove(key) }
        }
    }

    func setBusy(_ key: String, _ on: Bool) {
        withAnimation(.snappy) { if on { busy.insert(key) } else { busy.remove(key) } }
    }

    func open(_ card: Card) { open(id: card.id) }

    func open(_ agent: AgentRef) { open(id: agent.id, tool: agent.tool) }

    /// `tool` covers a chat the board no longer lists; without either, the chat opens in the default tool.
    func open(id: String, tool: String? = nil) {
        let key = "open-\(id)"
        let card = ((state?.allCards ?? []) + (state?.hiddenCards ?? [])).first { $0.id == id }
        setBusy(key, true)
        Tools.tool(card?.tool ?? tool).open(card?.chat ?? ChatRef(id: id, title: "")) { failure in
            self.setBusy(key, false)
            if let failure { self.show(.error, failure) } else { self.flagSuccess(key) }
            self.collect()
        }
    }

    /// ⌘ held: open the tab without bringing the browser forward.
    func openLink(_ url: String) {
        let background = NSEvent.modifierFlags.contains(.command)
        openInChrome(url, background: background) { [weak self] reused, message in
            if let message { self?.show(.error, message) } else if reused && background { self?.show(.ok, "Already open in Chrome") }
        }
    }

    /// True when no enabled tool types into a window, since only typing needs the grant.
    static func checkTrust() -> Bool { !Tools.needsAccessibility || Tools.isTrusted(prompt: false) }

    func ensureTrust(for tool: AgentTool) -> Bool {
        guard tool.needsAccessibility, !Tools.isTrusted(prompt: false) else { return true }
        requestTrust()
        show(.error, "Turn on Agent Board in Accessibility — the board restarts itself, then press again.")
        return false
    }

    /// The launch agent keeps the app alive only after an unsuccessful exit, so exiting this way
    /// brings up one fresh process — with the Accessibility grant — instead of a second copy.
    func relaunch() {
        guard !isBench else { return }
        exit(EXIT_FAILURE)
    }

    func requestTrust() {
        if trustPrompted {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        } else {
            trustPrompted = true
            // Only this prompt: its "Open System Settings" button opens the pane and dismisses it.
            // Opening the pane here as well would leave the dialog sitting on top of Settings.
            _ = Tools.isTrusted(prompt: true)
        }
    }

    // MARK: Quick actions

    var allPRs: [PR] { (state?.prs?.review ?? []) + (state?.prs?.mine ?? []) + (state?.prs?.hidden ?? []) }

    /// Selected PRs that are still open, in the order they were picked.
    var selectedPRs: [PR] {
        let byKey = Dictionary(allPRs.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        return selected.compactMap { byKey[$0] }
    }

}
