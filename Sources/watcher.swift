import Cocoa
import ApplicationServices

// MARK: - Diagnostics
// The watcher runs inside a background app with no console, so every decision it
// makes is written to a log. Read it with `dh log`.

let watcherLogURL = Store.dir.appendingPathComponent("watcher.log")

/// The diagnostic log must not become a second, unmanaged copy of your vocabulary.
/// Words are withheld unless you explicitly opt in with `dh debug on`.
func redact(_ s: String) -> String {
    UserDefaults.standard.bool(forKey: "debugLogging") ? "\"\(s)\"" : "<\(s.count) chars>"
}

func wlog(_ msg: String) {
    let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"
    let line = "\(f.string(from: Date()))  \(msg)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let h = try? FileHandle(forWritingTo: watcherLogURL) {
        defer { try? h.close() }
        h.seekToEndOfFile()
        // Keep the file from growing without bound.
        if h.offsetInFile > 512_000 {
            try? Data().write(to: watcherLogURL)
            if let h2 = try? FileHandle(forWritingTo: watcherLogURL) {
                h2.seekToEndOfFile(); h2.write(data); try? h2.close(); return
            }
        }
        h.write(data)
    } else {
        try? line.data(using: .utf8)?.write(to: watcherLogURL)
    }
}

// Observes Dictionary.app itself, catching the two things the Service cannot see:
// words TYPED into its search field, and cross-references CLICKED inside an entry.
//
// Both ultimately load a new entry into Dictionary's web view, so AXLoadComplete on
// the AXWebArea is the single signal that covers both. The search field is watched
// only to tell the two apart, and is never the source of truth: typing "seren"
// fires a value-change per keystroke, whereas the web area settles on a real entry.

// MARK: - AX helpers

func axCopy(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
}
func axString(_ el: AXUIElement, _ attr: String) -> String? {
    guard let v = axCopy(el, attr) else { return nil }
    if let s = v as? String { return s }
    if let a = v as? NSAttributedString { return a.string }
    return nil
}
func axChildren(_ el: AXUIElement) -> [AXUIElement] {
    (axCopy(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}
func axRole(_ el: AXUIElement) -> String { axString(el, kAXRoleAttribute as String) ?? "" }
func axSubrole(_ el: AXUIElement) -> String { axString(el, kAXSubroleAttribute as String) ?? "" }

/// Breadth-first so shallow matches win; depth-capped because web areas nest deeply.
func axFindAll(_ root: AXUIElement, maxDepth: Int, _ match: (AXUIElement) -> Bool) -> [AXUIElement] {
    var out: [AXUIElement] = []
    var frontier = [(root, 0)]
    while !frontier.isEmpty {
        var next: [(AXUIElement, Int)] = []
        for (el, d) in frontier {
            if match(el) { out.append(el) }
            if d < maxDepth { for c in axChildren(el) { next.append((c, d + 1)) } }
        }
        frontier = next
    }
    return out
}
func axFind(_ root: AXUIElement, maxDepth: Int, _ match: (AXUIElement) -> Bool) -> AXUIElement? {
    axFindAll(root, maxDepth: maxDepth, match).first
}

private func isSearchField(_ el: AXUIElement) -> Bool {
    let r = axRole(el)
    return axSubrole(el) == (kAXSearchFieldSubrole as String)
        || r == (kAXTextFieldRole as String)
        || r == "AXSearchField"
}
private func isWebArea(_ el: AXUIElement) -> Bool { axRole(el) == "AXWebArea" }

// MARK: - Observer callback (C function pointer, so state travels via refcon)

private let axCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon = refcon else { return }
    let w = Unmanaged<DictionaryWatcher>.fromOpaque(refcon).takeUnretainedValue()
    w.handle(element: element, notification: notification as String)
}

// MARK: - Watcher

/// What the watcher is actually doing, as opposed to what the user asked for.
/// The two diverge whenever macOS revokes Accessibility - which it does silently
/// every time this app is rebuilt, because an ad-hoc signature's hash changes and
/// TCC keys the grant to that hash.
enum WatchStatus {
    case off                // user has not turned it on
    case watching           // enabled and observing
    case needsPermission    // enabled, but macOS is withholding Accessibility
}

final class DictionaryWatcher {
    static let shared = DictionaryWatcher()
    static let bundleID = "com.apple.Dictionary"

    private var observer: AXObserver?
    private var appEl: AXUIElement?
    private var pid: pid_t = 0
    private var registeredWebAreas = 0

    private var pending: DispatchWorkItem?
    private var lastSearchEdit: Date?
    private var lastLogged: (word: String, at: Date)?
    private var rescanTimer: Timer?
    private var permissionTimer: Timer?
    private(set) var status: WatchStatus = .off

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "watchDictionaryApp") }
        set { UserDefaults.standard.set(newValue, forKey: "watchDictionaryApp") }
    }

    static func hasPermission(prompt: Bool = false) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: lifecycle

    /// Idempotent: safe to call repeatedly, including from the permission poller.
    func start() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)

        wlog("start(): enabled=\(Self.isEnabled) trusted=\(Self.hasPermission())")

        guard Self.isEnabled else { status = .off; stopPermissionPolling(); detach(); return }

        guard Self.hasPermission() else {
            wlog("  -> NO ACCESSIBILITY PERMISSION. polling every 3s.")
            // Do not fail silently. Surface it, and watch for the grant appearing.
            status = .needsPermission
            detach()
            beginPermissionPolling()
            return
        }
        stopPermissionPolling()
        status = .watching
        wlog("  -> watching")

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(appLaunched(_:)),
                       name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(appTerminated(_:)),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        if let app = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == Self.bundleID }) {
            wlog("  Dictionary already running, attaching")
            attach(pid: app.processIdentifier)
        } else {
            wlog("  Dictionary not running; waiting for launch")
        }
        // Dictionary rebuilds its web view on some navigations; re-scan periodically
        // so a dropped registration heals itself instead of silently going deaf.
        rescanTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self, self.appEl != nil else { return }
            if self.registeredWebAreas == 0 { self.registerElements() }
        }
    }

    func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        rescanTimer?.invalidate(); rescanTimer = nil
        stopPermissionPolling()
        status = .off
        detach()
    }

    /// Once the user grants Accessibility there is no notification, so poll for it
    /// and attach the moment it appears - no second trip to the menu required.
    private func beginPermissionPolling() {
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard Self.isEnabled else { self.stopPermissionPolling(); return }
            if Self.hasPermission() {
                self.stopPermissionPolling()
                self.start()
            }
        }
    }

    private func stopPermissionPolling() {
        permissionTimer?.invalidate(); permissionTimer = nil
    }

    @objc private func appLaunched(_ n: Notification) {
        guard let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              a.bundleIdentifier == Self.bundleID else { return }
        // The window/web view is not up at launch; give AppKit a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.attach(pid: a.processIdentifier)
        }
    }

    @objc private func appTerminated(_ n: Notification) {
        guard let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              a.bundleIdentifier == Self.bundleID else { return }
        detach()
    }

    private func attach(pid: pid_t) {
        detach()
        self.pid = pid
        let el = AXUIElementCreateApplication(pid)
        appEl = el

        var obs: AXObserver?
        guard AXObserverCreate(pid, axCallback, &obs) == .success, let obs = obs else {
            wlog("attach(\(pid)): AXObserverCreate FAILED")
            appEl = nil; return
        }
        wlog("attach(\(pid)): observer created")
        observer = obs
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)

        let me = Unmanaged.passUnretained(self).toOpaque()
        for note in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification] {
            AXObserverAddNotification(obs, el, note as CFString, me)
        }
        registerElements()
    }

    private func detach() {
        if let obs = observer {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        observer = nil; appEl = nil; pid = 0; registeredWebAreas = 0
        pending?.cancel(); pending = nil
    }

    /// Register on the live search field and web area. Called on attach and whenever
    /// a window appears, since those elements are recreated with each window.
    private func registerElements() {
        guard let app = appEl, let obs = observer else { return }
        let me = Unmanaged.passUnretained(self).toOpaque()
        registeredWebAreas = 0
        var windows = 0, fields = 0
        for win in axChildren(app) where axRole(win) == (kAXWindowRole as String) {
            windows += 1
            if let f = axFind(win, maxDepth: 8, isSearchField) {
                AXObserverAddNotification(obs, f, kAXValueChangedNotification as CFString, me)
                fields += 1
            }
            for wa in axFindAll(win, maxDepth: 14, isWebArea) {
                AXObserverAddNotification(obs, wa, "AXLoadComplete" as CFString, me)
                AXObserverAddNotification(obs, wa, kAXValueChangedNotification as CFString, me)
                registeredWebAreas += 1
            }
        }
        wlog("registerElements: windows=\(windows) searchFields=\(fields) webAreas=\(registeredWebAreas)")
    }

    // MARK: events

    fileprivate func handle(element: AXUIElement, notification: String) {
        wlog("event: \(notification)")
        switch notification {
        case kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.registerElements() }
            return
        case kAXValueChangedNotification where isSearchField(element):
            lastSearchEdit = Date()
        default:
            break
        }
        scheduleRead()
    }

    /// Trailing debounce: typing produces a value-change per keystroke, and we only
    /// want the entry the user actually landed on.
    private func scheduleRead() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.readCurrentEntry() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func readCurrentEntry() {
        guard let app = appEl else { return }
        guard let win = axChildren(app).first(where: { axRole($0) == (kAXWindowRole as String) }) else { return }

        let field = axFind(win, maxDepth: 8, isSearchField)
            .flatMap { axString($0, kAXValueAttribute as String) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        wlog("read: searchField=\(field.map { redact($0) } ?? "nil")")
        guard let headword = pickHeadword(win: win, field: field) else {
            wlog("  -> no usable headword, skipping")
            return
        }

        // Collapse the burst of AX notifications that describes a single navigation.
        if let last = lastLogged, last.word.caseInsensitiveCompare(headword) == .orderedSame,
           Date().timeIntervalSince(last.at) < 5 { return }
        lastLogged = (headword, Date())

        let via = (lastSearchEdit.map { Date().timeIntervalSince($0) < 2.0 } ?? false) ? "typed" : "link"
        let def = definition(for: headword)
        Store.shared.record(word: headword,
                            resolved: def.flatMap(resolvedHeadword(from:)),
                            sourceApp: "Dictionary",
                            context: nil,
                            via: via,
                            gloss: def.flatMap { shortGloss(from: $0, headword: headword) })
        wlog("  -> RECORDED \(redact(headword)) via=\(via)")
        NotificationCenter.default.post(name: .dictionaryHistoryDidChange, object: nil)
    }

    /// Which string is the entry actually being displayed.
    ///
    /// The search field wins. Measured against real captures, it was right every
    /// time, while the web view's own AXTitle reports the DICTIONARY name
    /// ("English"), and a breadth-first text scan surfaces the part-of-speech
    /// label ("noun") before the headword because BFS reorders the DOM.
    private func pickHeadword(win: AXUIElement, field: String?) -> String? {
        if let f = validWord(field) { return f }
        for wa in axFindAll(win, maxDepth: 14, isWebArea) {
            if let t = firstTextInDocumentOrder(wa), let v = validWord(t) { return v }
        }
        return nil
    }

    private func validWord(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines),
              !t.isEmpty, t.count <= 64,
              !t.contains("\n"),
              definition(for: t) != nil else { return nil }
        return t
    }

    /// Depth-first, so the first text node returned is the first one on the page.
    /// A node budget keeps a deep entry from walking the whole document.
    private func firstTextInDocumentOrder(_ root: AXUIElement, budget: Int = 60) -> String? {
        var remaining = budget
        func walk(_ el: AXUIElement) -> String? {
            if remaining <= 0 { return nil }
            remaining -= 1
            if axRole(el) == (kAXStaticTextRole as String) {
                if let v = axString(el, kAXValueAttribute as String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
            }
            for c in axChildren(el) { if let f = walk(c) { return f } }
            return nil
        }
        return walk(root)
    }
}

extension Notification.Name {
    static let dictionaryHistoryDidChange = Notification.Name("DictionaryHistoryDidChange")
}

// MARK: - Discovery aid
// `dh dump-ax` prints Dictionary.app's live hierarchy so the selectors above can be
// checked (and corrected) on a macOS version this was not developed against.

func dumpDictionaryAX() -> Int32 {
    guard DictionaryWatcher.hasPermission() else {
        let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        print("""
        Accessibility permission not granted.

        Run from a terminal, the grant belongs to the TERMINAL app, not to this binary.

          macOS 13+ : System Settings > Privacy & Security > Accessibility
          macOS 12  : System Preferences > Security & Privacy > Privacy > Accessibility
                      (click the lock to unlock first)

        Open that pane with:
          open "\(pane)"

        Add and tick your terminal, restart it, then run this again with
        Dictionary.app open on a word.
        """)
        return 1
    }
    guard let app = NSWorkspace.shared.runningApplications
        .first(where: { $0.bundleIdentifier == DictionaryWatcher.bundleID }) else {
        print("Dictionary.app is not running. Open it, search for a word, then re-run.")
        return 1
    }
    let el = AXUIElementCreateApplication(app.processIdentifier)
    func walk(_ e: AXUIElement, _ d: Int) {
        guard d < 16 else { return }
        let role = axRole(e), sub = axSubrole(e)
        let val = (axString(e, kAXValueAttribute as String) ?? "").prefix(60)
        let title = (axString(e, kAXTitleAttribute as String) ?? "").prefix(60)
        var line = String(repeating: "  ", count: d) + role
        if !sub.isEmpty { line += " (\(sub))" }
        if !title.isEmpty { line += "  title=\"\(title)\"" }
        if !val.isEmpty { line += "  value=\"\(val)\"" }
        print(line)
        for c in axChildren(e) { walk(c, d + 1) }
    }
    walk(el, 0)
    return 0
}
