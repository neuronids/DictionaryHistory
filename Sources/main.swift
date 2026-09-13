import Cocoa
import SwiftUI
import Combine
import SQLite3

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Dictionary engine
// DCSCopyTextDefinition is public SDK API, API_AVAILABLE(macos(10.5)).

@_silgen_name("DCSCopyTextDefinition")
func DCSCopyTextDefinition(_ dictionary: AnyObject?, _ text: CFString, _ range: CFRange) -> Unmanaged<CFString>?

func definition(for word: String) -> String? {
    let cf = word as CFString
    let len = CFStringGetLength(cf)
    guard len > 0, let d = DCSCopyTextDefinition(nil, cf, CFRangeMake(0, len)) else { return nil }
    return d.takeRetainedValue() as String
}

/// The headword Apple actually resolved to. This lemmatises for free:
/// "ran" -> "run", "mice" -> "mouse". Homographs come back suffixed
/// ("better1"), so the trailing sense number is stripped.
func resolvedHeadword(from def: String) -> String? {
    guard let firstLine = def.split(separator: "\n", maxSplits: 1).first else { return nil }
    let head = firstLine.split(separator: "|", maxSplits: 1).first ?? firstLine
    var t = head.trimmingCharacters(in: .whitespaces)
    if let r = t.range(of: "[A-Za-z]\\d+$", options: .regularExpression) {
        t = String(t[..<t.index(before: r.upperBound)])
        while let last = t.last, last.isNumber { t.removeLast() }
    }
    // Dictionaries without a "| pronunciation |" block (Catalan, bilingual, Apple's own)
    // run the headword straight into the definition, so a long "head" is not a headword.
    guard !t.isEmpty, t.count <= 48, t.split(separator: " ").count <= 3 else { return nil }
    return t
}

/// A one-line sense of the word, so a history row explains itself.
///
/// Apple returns "fluke | fluːk | noun an unlikely chance occurrence: ...".
/// The headword, pronunciation, part-of-speech and sense number are all stripped:
/// at one line, "noun" costs space and teaches nothing. Domain labels
/// ("Grammar", "Music") are kept, because those do carry meaning.
func shortGloss(from def: String, headword: String) -> String? {
    var t = def.replacingOccurrences(of: "\n", with: " ")

    if let r = t.range(of: "^\\s*\\Q\(headword)\\E\\s*", options: [.regularExpression, .caseInsensitive]) {
        t = String(t[r.upperBound...])
    }
    while let open = t.firstIndex(of: "|"),
          let close = t[t.index(after: open)...].firstIndex(of: "|") {
        t = String(t[..<open]) + " " + String(t[t.index(after: close)...])
    }
    func squeeze() {
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
             .trimmingCharacters(in: .whitespaces)
    }
    squeeze()

    let partsOfSpeech = ["plural noun", "mass noun", "proper noun", "auxiliary verb",
                         "modal verb", "phrasal verb", "noun", "verb", "adjective", "adverb",
                         "pronoun", "preposition", "conjunction", "interjection",
                         "exclamation", "determiner", "abbreviation", "prefix", "suffix",
                         "symbol", "contraction", "article", "particle"]
    // Loop: entries stack labels, e.g. "noun [mass noun] 1 the occurrence of ...".
    var changed = true
    while changed {
        changed = false
        for p in partsOfSpeech {
            if let r = t.range(of: "^\(p)\\b", options: [.regularExpression, .caseInsensitive]) {
                t.removeSubrange(r); squeeze(); changed = true; break
            }
        }
        if t.hasPrefix("[") , let close = t.firstIndex(of: "]") {
            t = String(t[t.index(after: close)...]); squeeze(); changed = true
        }
        if let r = t.range(of: "^\\d+\\b", options: .regularExpression) {
            t.removeSubrange(r); squeeze(); changed = true
        }
    }
    t = t.trimmingCharacters(in: CharacterSet(charactersIn: " :;,.-"))
    guard !t.isEmpty else { return nil }

    let limit = 150
    if t.count <= limit { return t }
    let cut = t.prefix(limit)
    let end = cut.lastIndex(of: " ") ?? cut.endIndex
    return String(cut[..<end]) + "…"
}

// MARK: - Model

struct Lookup: Identifiable {
    let id: Int64
    let word: String
    let resolved: String?
    let ts: Date
    let sourceApp: String?
    let context: String?
    let via: String?      // "service" | "typed" | "link" | "cli"
    let gloss: String?    // one-line sense, so a row explains itself
}

// MARK: - Store

final class Store {
    static let shared = Store()
    private var db: OpaquePointer?
    private let lock = NSLock()

    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("DictionaryHistory", isDirectory: true)
    }
    static var dbURL: URL { dir.appendingPathComponent("history.db") }

    private init() {
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        guard sqlite3_open(Self.dbURL.path, &db) == SQLITE_OK else {
            FileHandle.standardError.write("DictionaryHistory: cannot open \(Self.dbURL.path)\n".data(using: .utf8)!)
            return
        }
        exec("PRAGMA journal_mode=WAL;")
        exec("""
        CREATE TABLE IF NOT EXISTS lookups(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            word TEXT NOT NULL,
            resolved TEXT,
            ts REAL NOT NULL,
            source_app TEXT,
            context TEXT,
            via TEXT,
            gloss TEXT);
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_lookups_word ON lookups(word);")
        exec("CREATE INDEX IF NOT EXISTS idx_lookups_ts ON lookups(ts);")
        // Migration for databases created before `via` existed. Fails harmlessly
        // when the column is already present.
        exec("ALTER TABLE lookups ADD COLUMN via TEXT;")
        exec("ALTER TABLE lookups ADD COLUMN gloss TEXT;")
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    @discardableResult
    func record(word: String, resolved: String?, sourceApp: String?, context: String?,
                via: String, gloss: String?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let sql = "INSERT INTO lookups(word, resolved, ts, source_app, context, via, gloss) VALUES(?,?,?,?,?,?,?);"
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, word, -1, SQLITE_TRANSIENT)
        if let r = resolved { sqlite3_bind_text(st, 2, r, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(st, 2) }
        sqlite3_bind_double(st, 3, Date().timeIntervalSince1970)
        if let a = sourceApp { sqlite3_bind_text(st, 4, a, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(st, 4) }
        if let c = context { sqlite3_bind_text(st, 5, c, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(st, 5) }
        sqlite3_bind_text(st, 6, via, -1, SQLITE_TRANSIENT)
        if let g = gloss { sqlite3_bind_text(st, 7, g, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(st, 7) }
        return sqlite3_step(st) == SQLITE_DONE
    }

    private func rows(_ sql: String, bind: ((OpaquePointer?) -> Void)? = nil) -> [Lookup] {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(st) }
        bind?(st)
        var out: [Lookup] = []
        while sqlite3_step(st) == SQLITE_ROW {
            func str(_ i: Int32) -> String? {
                guard let c = sqlite3_column_text(st, i) else { return nil }
                return String(cString: c)
            }
            out.append(Lookup(id: sqlite3_column_int64(st, 0),
                              word: str(1) ?? "",
                              resolved: str(2),
                              ts: Date(timeIntervalSince1970: sqlite3_column_double(st, 3)),
                              sourceApp: str(4),
                              context: str(5),
                              via: str(6),
                              gloss: str(7)))
        }
        return out
    }

    func recent(limit: Int = 200) -> [Lookup] {
        rows("SELECT id,word,resolved,ts,source_app,context,via,gloss FROM lookups ORDER BY ts DESC LIMIT \(limit);")
    }

    func search(_ q: String, limit: Int = 500) -> [Lookup] {
        rows("SELECT id,word,resolved,ts,source_app,context,via,gloss FROM lookups WHERE word LIKE ? OR resolved LIKE ? ORDER BY ts DESC LIMIT \(limit);") { st in
            let pat = "%\(q)%"
            sqlite3_bind_text(st, 1, pat, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(st, 2, pat, -1, SQLITE_TRANSIENT)
        }
    }

    /// (word, count) most frequently looked up.
    func top(limit: Int = 50) -> [(String, Int)] {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        let sql = """
        SELECT COALESCE(NULLIF(resolved,''), word) k, COUNT(*) c
        FROM lookups GROUP BY k ORDER BY c DESC, k ASC LIMIT \(limit);
        """
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(st) }
        var out: [(String, Int)] = []
        while sqlite3_step(st) == SQLITE_ROW {
            guard let c = sqlite3_column_text(st, 0) else { continue }
            out.append((String(cString: c), Int(sqlite3_column_int(st, 1))))
        }
        return out
    }

    /// Recompute `resolved` and `gloss` for every row from the live dictionary.
    /// Used after a repair, or to backfill rows written by an older version.
    func reindex() -> Int {
        var updated = 0
        for r in recent(limit: 1_000_000) {
            guard let def = definition(for: r.word) else { continue }
            let res = resolvedHeadword(from: def)
            let gl = shortGloss(from: def, headword: r.word)
            lock.lock()
            var st: OpaquePointer?
            if sqlite3_prepare_v2(db, "UPDATE lookups SET resolved=?, gloss=? WHERE id=?;", -1, &st, nil) == SQLITE_OK {
                if let x = res { sqlite3_bind_text(st, 1, x, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(st, 1) }
                if let x = gl  { sqlite3_bind_text(st, 2, x, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(st, 2) }
                sqlite3_bind_int64(st, 3, r.id)
                if sqlite3_step(st) == SQLITE_DONE { updated += 1 }
            }
            sqlite3_finalize(st)
            lock.unlock()
        }
        return updated
    }

    /// Times each lemma has been looked up, keyed lowercased. Inflections collapse,
    /// so meeting "ran" and then "run" counts as meeting the same word twice.
    func lemmaCounts() -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        let sql = "SELECT LOWER(COALESCE(NULLIF(resolved,''), word)) k, COUNT(*) c FROM lookups GROUP BY k;"
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(st) }
        var out: [String: Int] = [:]
        while sqlite3_step(st) == SQLITE_ROW {
            guard let c = sqlite3_column_text(st, 0) else { continue }
            out[String(cString: c)] = Int(sqlite3_column_int(st, 1))
        }
        return out
    }

    /// Remove every trace of a word, matching either what you typed or its lemma.
    func forget(_ word: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        let sql = "DELETE FROM lookups WHERE LOWER(word)=LOWER(?) OR LOWER(COALESCE(resolved,''))=LOWER(?);"
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, word, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(st, 2, word, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(st) == SQLITE_DONE else { return 0 }
        return Int(sqlite3_changes(db))
    }

    func purgeAll() -> Int {
        lock.lock(); defer { lock.unlock() }
        sqlite3_exec(db, "DELETE FROM lookups;", nil, nil, nil)
        let n = Int(sqlite3_changes(db))
        sqlite3_exec(db, "VACUUM;", nil, nil, nil)
        return n
    }

    func countAll() -> Int {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM lookups;", -1, &st, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(st) }
        return sqlite3_step(st) == SQLITE_ROW ? Int(sqlite3_column_int(st, 0)) : 0
    }

    func countToday() -> Int {
        lock.lock(); defer { lock.unlock() }
        let start = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM lookups WHERE ts >= ?;", -1, &st, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_double(st, 1, start)
        return sqlite3_step(st) == SQLITE_ROW ? Int(sqlite3_column_int(st, 0)) : 0
    }

    /// Whether any word has arrived by one of these routes: proof a route works,
    /// not merely that it is configured.
    func hasCaptured(via routes: [String]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let marks = routes.map { _ in "?" }.joined(separator: ",")
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM lookups WHERE via IN (\(marks)) LIMIT 1;", -1, &st, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(st) }
        for (i, r) in routes.enumerated() { sqlite3_bind_text(st, Int32(i + 1), r, -1, SQLITE_TRANSIENT) }
        return sqlite3_step(st) == SQLITE_ROW
    }
}

// MARK: - Capture

enum Capture {
    static var isPaused: Bool {
        get { UserDefaults.standard.bool(forKey: "paused") }
        set { UserDefaults.standard.set(newValue, forKey: "paused") }
    }

    /// Log the word, then hand off to Apple's Dictionary exactly as before.
    static func lookUp(_ raw: String, sourceApp: String?, context: String?,
                       via: String = "service", openUI: Bool = true) {
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, word.count <= 128 else { return }

        if !isPaused {
            let def = definition(for: word)
            Store.shared.record(word: word,
                                resolved: def.flatMap(resolvedHeadword(from:)),
                                sourceApp: sourceApp,
                                context: context,
                                via: via,
                                gloss: def.flatMap { shortGloss(from: $0, headword: word) })
        }
        NotificationCenter.default.post(name: .dictionaryHistoryDidChange, object: nil)

        guard openUI else { return }
        let enc = word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? word
        if let url = URL(string: "dict://\(enc)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - History window

/// One visible row: either a lone lookup, or a trail of cross-references
/// followed out of a single seed word.
private enum DisplayRow: Identifiable {
    case single(Lookup)
    case trail([Lookup])
    var id: Int64 {
        switch self {
        case .single(let l): return l.id
        case .trail(let ls): return ls.first?.id ?? 0
        }
    }
}

struct HistoryView: View {
    @State private var query = ""
    @State private var items: [Lookup] = Store.shared.recent()
    @State private var counts: [String: Int] = Store.shared.lemmaCounts()

    /// How long a gap can be before a clicked cross-reference counts as a new
    /// start rather than a continuation of the same wander.
    private static let trailGap: TimeInterval = 600

    private static let thisYear: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("d MMM HH:mm"); return f
    }()
    private static let otherYear: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("d MMM y HH:mm"); return f
    }()
    static func dateLabel(_ d: Date) -> String {
        let cal = Calendar.current
        return cal.component(.year, from: d) == cal.component(.year, from: Date())
            ? thisYear.string(from: d) : otherYear.string(from: d)
    }

    /// A word met once is a word you read. Met again, it is a word that did not stick.
    private func repeatCount(_ item: Lookup) -> Int {
        let key = (item.resolved?.isEmpty == false ? item.resolved! : item.word).lowercased()
        return counts[key] ?? 1
    }

    /// Collapse `via == "link"` runs into trails. Only when browsing: inside a
    /// search, every match should stand on its own.
    private var rows: [DisplayRow] {
        guard query.isEmpty else { return items.map { .single($0) } }
        var chains: [[Lookup]] = []
        for l in items.reversed() {                 // items arrive newest-first
            if l.via == "link", let prev = chains.last?.last,
               l.ts.timeIntervalSince(prev.ts) <= Self.trailGap {
                chains[chains.count - 1].append(l)
            } else {
                chains.append([l])
            }
        }
        return chains.reversed().map { $0.count > 1 ? .trail($0) : .single($0[0]) }
    }

    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search your words", text: $query)
                    .textFieldStyle(.plain)
                    .onChange(of: query) { _ in reload() }
                Spacer()
                Text("\(items.count)").foregroundColor(.secondary).font(.caption)
            }
            .padding(10)
            Divider()
            List(rows) { row in
                switch row {
                case .single(let item): singleRow(item)
                case .trail(let chain): trailRow(chain)
                }
            }
        }
        .frame(minWidth: 460, minHeight: 380)
        .onAppear { reload() }
        .onReceive(tick) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .dictionaryHistoryDidChange)) { _ in reload() }
    }

    @ViewBuilder
    private func singleRow(_ item: Lookup) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.word).font(.system(.body, design: .serif)).bold()
                    badge(repeatCount(item))
                    if let r = item.resolved, r.lowercased() != item.word.lowercased() {
                        Text(r).font(.caption).foregroundColor(.secondary)
                    }
                }
                if let g = item.gloss, !g.isEmpty {
                    Text(g).font(.caption).foregroundColor(.secondary).lineLimit(2)
                } else if let c = item.context, !c.isEmpty {
                    Text(c).font(.caption).foregroundColor(.secondary).lineLimit(2)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Self.dateLabel(item.ts)).font(.caption).foregroundColor(.secondary)
                if let a = item.sourceApp {
                    Text(a).font(.caption2).foregroundColor(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { Capture.lookUp(item.word, sourceApp: nil, context: nil) }
    }

    @ViewBuilder
    private func trailRow(_ chain: [Lookup]) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                // Wraps, because a long wander should not push the date off the row.
                FlowText(words: chain.map { $0.word })
                Text("a trail you followed").font(.caption2).foregroundColor(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Self.dateLabel(chain.last?.ts ?? Date())).font(.caption).foregroundColor(.secondary)
                Text("\(chain.count) words").font(.caption2).foregroundColor(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if let seed = chain.first { Capture.lookUp(seed.word, sourceApp: nil, context: nil) }
        }
    }

    @ViewBuilder
    private func badge(_ c: Int) -> some View {
        if c > 1 {
            Text("\(c)×")
                .font(.caption2)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.orange.opacity(c >= 3 ? 0.28 : 0.15)))
                .foregroundColor(Color.orange)
        }
    }

    private func reload() {
        let fresh = query.isEmpty ? Store.shared.recent() : Store.shared.search(query)
        if fresh.count != items.count || fresh.first?.id != items.first?.id {
            items = fresh
            counts = Store.shared.lemmaCounts()
        }
    }
}

/// The seed word, then each word it led to, separated by arrows and wrapping
/// onto further lines when the trail is long.
private struct FlowText: View {
    let words: [String]
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                if i > 0 {
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Text(w)
                    .font(.system(i == 0 ? .body : .callout, design: .serif))
                    .fontWeight(i == 0 ? .bold : .regular)
                    .foregroundColor(i == 0 ? .primary : .secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var historyWindow: NSWindow?

    func applicationDidFinishLaunching(_ n: Notification) {
        // Two copies means two menu-bar icons and two writers. Keep the incumbent.
        let meID = Bundle.main.bundleIdentifier ?? "com.edm.dictionaryhistory"
        let mine = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: meID)
            .filter { $0.processIdentifier != mine }
        if !others.isEmpty {
            wlog("another instance is already running (pid \(others.map { $0.processIdentifier })); exiting")
            NSApp.terminate(nil)
            return
        }
        wlog("launched pid=\(mine)")

        // Dictionary.app itself is the capture route, so watching is on unless turned off.
        UserDefaults.standard.register(defaults: ["watchDictionaryApp": true])

        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "character.book.closed", accessibilityDescription: "Dictionary History")
            b.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        DictionaryWatcher.shared.start()
    }

    // Rebuilt each time so counts and recents are always fresh.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Setup status: ✗ off · ✓ enabled · ✓✓ a word has actually arrived that way.
        func mark(_ on: Bool, _ used: Bool) -> String { used ? "✓✓" : on ? "✓" : "✗" }
        let axMark = mark(DictionaryWatcher.hasPermission(), Store.shared.hasCaptured(via: ["typed", "link"]))
        let setup = NSMenuItem(title: "Accessibility \(axMark)", action: nil, keyEquivalent: "")
        setup.isEnabled = false
        menu.addItem(setup)

        let today = Store.shared.countToday()
        let header = NSMenuItem(title: "Today: \(today) lookup\(today == 1 ? "" : "s")", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let recents = Store.shared.recent(limit: 10)
        if recents.isEmpty {
            let empty = NSMenuItem(title: "No lookups yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for r in recents {
                let mi = NSMenuItem(title: r.word, action: #selector(reopen(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = r.word
                mi.toolTip = r.resolved
                menu.addItem(mi)
            }
        }

        menu.addItem(.separator())
        let show = NSMenuItem(title: "Show All History…", action: #selector(showHistory), keyEquivalent: "h")
        show.keyEquivalentModifierMask = [.command, .shift]
        show.target = self
        menu.addItem(show)

        let exp = NSMenuItem(title: "Export as CSV…", action: #selector(exportCSV), keyEquivalent: "")
        exp.target = self
        menu.addItem(exp)

        menu.addItem(.separator())
        let pause = NSMenuItem(title: Capture.isPaused ? "Resume Logging" : "Pause Logging",
                               action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)

        let status = DictionaryWatcher.shared.status
        let watch = NSMenuItem(title: "Watch Dictionary.app", action: #selector(toggleWatch), keyEquivalent: "")
        watch.state = (status == .watching) ? .on : .off
        watch.toolTip = "Also record words typed into Dictionary.app and cross-references clicked inside it. Requires Accessibility permission."
        watch.target = self
        menu.addItem(watch)

        // macOS revokes Accessibility whenever this app is rebuilt. Say so out loud
        // rather than leaving a checkmark that claims to be working.
        if status == .needsPermission {
            let warn = NSMenuItem(title: "Accessibility permission lost — click to restore",
                                  action: #selector(openAccessibilityPane), keyEquivalent: "")
            warn.target = self
            let img = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            img?.isTemplate = true
            warn.image = img
            warn.toolTip = "Dictionary.app is not being watched. Re-enable DictionaryHistory under Accessibility."
            menu.addItem(warn)
        }

        let reveal = NSMenuItem(title: "Reveal Data Folder", action: #selector(revealData), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit DictionaryHistory", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc func reopen(_ sender: NSMenuItem) {
        guard let w = sender.representedObject as? String else { return }
        Capture.lookUp(w, sourceApp: "DictionaryHistory", context: nil)
    }

    @objc func showHistory() {
        if historyWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "Dictionary History"
            w.contentView = NSHostingView(rootView: HistoryView())
            w.center()
            w.isReleasedWhenClosed = false
            historyWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        historyWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func togglePause() { Capture.isPaused.toggle() }

    @objc func openAccessibilityPane() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(u)
        }
    }

    @objc func toggleWatch() {
        if DictionaryWatcher.isEnabled {
            DictionaryWatcher.isEnabled = false
            DictionaryWatcher.shared.stop()
            return
        }
        DictionaryWatcher.isEnabled = true
        guard DictionaryWatcher.hasPermission(prompt: true) else {
            DictionaryWatcher.shared.start()   // records .needsPermission and begins polling
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "Accessibility permission needed"
            a.informativeText = """
            To record words typed into Dictionary.app - and cross-references you click \
            inside an entry - this app has to observe Dictionary.app's window.

            Enable DictionaryHistory under Privacy & Security > Accessibility, then \
            turn on \"Watch Dictionary.app\" again.
            """
            a.addButton(withTitle: "Open Settings")
            a.addButton(withTitle: "Cancel")
            if a.runModal() == .alertFirstButtonReturn { self.openAccessibilityPane() }
            return
        }
        DictionaryWatcher.shared.start()
    }

    @objc func revealData() {
        NSWorkspace.shared.activateFileViewerSelecting([Store.dbURL])
    }

    @objc func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "dictionary-history.csv"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let f = ISO8601DateFormatter()
        var csv = "timestamp,word,resolved,source_app,context,via\n"
        for r in Store.shared.recent(limit: 1_000_000) {
            func q(_ s: String?) -> String { "\"" + (s ?? "").replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            csv += "\(f.string(from: r.ts)),\(q(r.word)),\(q(r.resolved)),\(q(r.sourceApp)),\(q(r.context)),\(q(r.via))\n"
        }
        try? csv.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Service entry point (declared in Info.plist as NSMessage "lookUpAndLog")
    // macOS hands us the selection directly - no Accessibility permission required.
    @objc func lookUpAndLog(_ pboard: NSPasteboard,
                            userData: String?,
                            error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pboard.string(forType: .string) else {
            error.pointee = "No text selected." as NSString
            return
        }
        let src = NSWorkspace.shared.frontmostApplication?.localizedName
        // A single selected word is the common case; a longer selection is kept as context.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: { $0.isWhitespace })
        if words.count > 1 {
            Capture.lookUp(String(words[0]), sourceApp: src, context: trimmed)
        } else {
            Capture.lookUp(trimmed, sourceApp: src, context: nil)
        }
    }
}

// MARK: - CLI mode
// The same binary answers `dh recent|search|top|path` so the history is
// queryable from a terminal (and by an agent) without opening the UI.

func runCLI(_ args: [String]) -> Int32 {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
    switch args[0] {
    case "recent":
        let n = args.count > 1 ? Int(args[1]) ?? 25 : 25
        for r in Store.shared.recent(limit: n) {
            print("\(f.string(from: r.ts))  \(r.word.padding(toLength: max(r.word.count, 18), withPad: " ", startingAt: 0))  \(r.via ?? "-")")
        }
    case "search":
        guard args.count > 1 else { print("usage: dh search <query>"); return 1 }
        for r in Store.shared.search(args[1]) {
            print("\(f.string(from: r.ts))  \(r.word)")
        }
    case "top":
        for (w, c) in Store.shared.top(limit: args.count > 1 ? Int(args[1]) ?? 25 : 25) {
            print(String(format: "%5d  %@", c, w))
        }
    case "add":
        guard args.count > 1 else { print("usage: dh add <word>"); return 1 }
        Capture.lookUp(args[1], sourceApp: "cli", context: nil, via: "cli", openUI: false)
        print("logged: \(args[1])")
    case "reindex":
        print("reindexed \(Store.shared.reindex()) rows")
    case "path":
        print(Store.dbURL.path)
    case "dump-ax":
        return dumpDictionaryAX()
    case "forget":
        guard args.count > 1 else { print("usage: dh forget <word>"); return 1 }
        let n = Store.shared.forget(args[1])
        print(n > 0 ? "forgot \(args[1]) (\(n) row\(n == 1 ? "" : "s"))" : "no record of \(args[1])")
    case "purge":
        let total = Store.shared.countAll()
        guard args.contains("--yes") else {
            print("This deletes all \(total) lookups and cannot be undone.")
            print("Re-run as:  dh purge --yes")
            return 1
        }
        print("deleted \(Store.shared.purgeAll()) rows")
    case "debug":
        let on = args.count > 1 && args[1] == "on"
        UserDefaults.standard.set(on, forKey: "debugLogging")
        print(on ? "debug logging ON - the log will now contain your words"
                 : "debug logging OFF - words are withheld from the log")
    case "log":
        let n = args.count > 1 ? Int(args[1]) ?? 40 : 40
        guard let text = try? String(contentsOf: watcherLogURL, encoding: .utf8) else {
            print("no log yet at \(watcherLogURL.path)"); return 1
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for l in lines.suffix(n) where !l.isEmpty { print(l) }
    default:
        print("""
        dh - Dictionary History
          dh recent [n]      most recent lookups
          dh search <query>  search lookups
          dh top [n]         most frequent words
          dh add <word>      log without opening the UI
          dh reindex         recompute lemma + gloss for every row
          dh path            path to history.db
          dh dump-ax         print Dictionary.app's accessibility tree
          dh log [n]         last n lines of the watcher diagnostic log
          dh forget <word>   delete every record of a word
          dh purge --yes     delete the entire history
          dh debug on|off    include words in the diagnostic log (default off)
        """)
        return args[0] == "help" ? 0 : 1
    }
    return 0
}

// MARK: - Entry

let cliArgs = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-NS") }
if !cliArgs.isEmpty {
    exit(runCLI(cliArgs))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
app.run()
