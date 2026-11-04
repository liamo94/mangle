import SwiftUI
import AppKit
import Combine

struct HistoryEntry: Identifiable, Codable, Hashable {
    let id: UUID
    var text: String
    var timestamp: Date
    var isPinned: Bool
    var language: String? // nil = auto-detect; set when user manually picks a language
    /// Saved from a scratch pad rather than copied.
    var isScratch: Bool

    init(id: UUID = UUID(), text: String, timestamp: Date = Date(), isPinned: Bool = false, language: String? = nil, isScratch: Bool = false) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.isPinned = isPinned
        self.language = language
        self.isScratch = isScratch
    }

    // Custom decoder for backwards compatibility – isPinned/language/isScratch may be absent in old data
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id        = try container.decode(UUID.self,   forKey: .id)
        text      = try container.decode(String.self, forKey: .text)
        timestamp = try container.decode(Date.self,   forKey: .timestamp)
        isPinned  = (try container.decodeIfPresent(Bool.self,   forKey: .isPinned)) ?? false
        language  =  try container.decodeIfPresent(String.self, forKey: .language)
        isScratch = (try container.decodeIfPresent(Bool.self,   forKey: .isScratch)) ?? false
    }

    // Hashable conformance
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: HistoryEntry, rhs: HistoryEntry) -> Bool {
        lhs.id == rhs.id
    }
}

/// Derived, display-only data for a history entry. `text` only changes via `addEntry`, which drops the cache, so this is
/// computed once per entry instead of re-splitting/re-hashing the full text on every render.
struct HistoryEntryMeta {
    let preview: String
    let secondLine: String?
    let detectedLanguage: String
    let lines: Int
    let words: Int
    let chars: Int
}

class HistoryManager: ObservableObject {
    @Published var entries: [HistoryEntry] = []
    private let legacySaveKey = "MangleHistory"
    private var metaCache: [UUID: HistoryEntryMeta] = [:]
    private let saveQueue = DispatchQueue(label: "co.liamo.mangle.history-save", qos: .utility)
    private var pendingSave: DispatchWorkItem?
    /// The last deleted entry and where it was, for ⌘Z in History.
    private var lastDeleted: (entry: HistoryEntry, index: Int)?

    nonisolated private static var historyFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Mangle", isDirectory: true).appendingPathComponent("history.json")
    }

    init() {
        loadHistory()
    }

    func meta(for entry: HistoryEntry) -> HistoryEntryMeta {
        if let cached = metaCache[entry.id] { return cached }
        let text = entry.text
        let nonEmptyLines = text.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: true)
        let trimLeading: (Substring) -> String = { String($0.drop(while: { $0 == " " || $0 == "\t" }).prefix(60)) }
        let preview = nonEmptyLines.first.map(trimLeading)
            ?? text.prefix(60).trimmingCharacters(in: .whitespacesAndNewlines)
        let secondLine = nonEmptyLines.count > 1 ? trimLeading(nonEmptyLines[1]) : nil
        let stats = TextStats.compute(text)
        let meta = HistoryEntryMeta(
            preview: preview,
            secondLine: secondLine,
            detectedLanguage: CustomTextEditor.Coordinator.guessLanguage(text),
            lines: stats.lines, words: stats.words, chars: stats.chars
        )
        metaCache[entry.id] = meta
        return meta
    }

    /// Adds `text` at the top. With `replacing`, saving an edit of that entry updates it in
    /// place instead of leaving a near-duplicate beside it — unless it's pinned, which keeps
    /// the original as it was.
    func addEntry(_ text: String, isScratch: Bool = false, replacing sourceID: UUID? = nil) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        if let sourceID, let idx = entries.firstIndex(where: { $0.id == sourceID }),
           !entries[idx].isPinned, entries[idx].text != text,
           !entries.contains(where: { $0.text == text }) {
            var entry = entries.remove(at: idx)
            entry.text = text
            entry.timestamp = Date()
            metaCache[entry.id] = nil
            entries.insert(entry, at: 0)
            saveHistory()
            return
        }

        // Deduplicate against the whole list, not just the most recent entry — copying
        // A, then B, then A again used to leave two separate "A" entries in history.
        if let idx = entries.firstIndex(where: { $0.text == text }) {
            entries[idx].timestamp = Date()
            if idx != 0 {
                let existing = entries.remove(at: idx)
                entries.insert(existing, at: 0)
            }
            saveHistory()
            return
        }

        let entry = HistoryEntry(text: text, isScratch: isScratch)
        entries.insert(entry, at: 0)
        enforceLimit()
        saveHistory()
    }

    /// Trim unpinned entries to the configured limit; pinned entries are kept regardless.
    /// Order is preserved (pinned entries aren't hoisted — the UI sorts them for display).
    func enforceLimit(save: Bool = false) {
        let max = SettingsManager.shared.maxHistory
        guard max > 0 else { return } // unlimited
        var unpinnedSeen = 0
        let trimmed = entries.filter { entry in
            if entry.isPinned { return true }
            unpinnedSeen += 1
            return unpinnedSeen <= max
        }
        guard trimmed.count != entries.count else { return }
        let kept = Set(trimmed.map(\.id))
        for id in metaCache.keys where !kept.contains(id) { metaCache[id] = nil }
        entries = trimmed
        if save { saveHistory() }
    }

    func deleteEntry(_ entry: HistoryEntry) {
        guard let idx = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        lastDeleted = (entries.remove(at: idx), idx)
        metaCache[entry.id] = nil
        saveHistory()
    }

    /// Called when History closes, so ⌘Z next time can't bring back an old deletion.
    func forgetDeleted() {
        lastDeleted = nil
    }

    /// Puts the most recently deleted entry back where it was.
    @discardableResult
    func undoDelete() -> HistoryEntry? {
        guard let (entry, idx) = lastDeleted else { return nil }
        lastDeleted = nil
        entries.insert(entry, at: min(idx, entries.count))
        saveHistory()
        return entry
    }

    func clearHistory() {
        lastDeleted = nil
        entries.removeAll()
        metaCache.removeAll()
        saveHistory()
    }

    func togglePin(_ entry: HistoryEntry) {
        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx].isPinned.toggle()
            saveHistory()
        }
    }

    func updateLanguage(for id: UUID, language: String) {
        if let idx = entries.firstIndex(where: { $0.id == id }) {
            entries[idx].language = language
            saveHistory()
        }
    }

    /// Encodes and writes off the main thread, coalescing bursts of changes into one write.
    /// History used to live in UserDefaults, which rewrote the whole (potentially multi-MB)
    /// plist synchronously on every change.
    private func saveHistory() {
        let snapshot = entries
        pendingSave?.cancel()
        let work = DispatchWorkItem { Self.write(snapshot) }
        pendingSave = work
        saveQueue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Flush any pending write immediately (used at app termination).
    func flush() {
        guard let work = pendingSave else { return }
        work.cancel()
        pendingSave = nil
        let snapshot = entries
        saveQueue.sync { _ = Self.write(snapshot) }
    }
    
    @discardableResult
    nonisolated private static func write(_ entries: [HistoryEntry]) -> Bool {
        guard let data = try? JSONEncoder().encode(entries) else { return false }
        let url = historyFileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// Re-reads history from disk, e.g. after another copy of the app saved on quitting.
    func reload() {
        loadHistory()
    }

    private func loadHistory() {
        if let data = try? Data(contentsOf: Self.historyFileURL),
           let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = decoded
            return
        }
        // One-time migration from the old UserDefaults storage
        if let data = UserDefaults.standard.data(forKey: legacySaveKey),
           let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = decoded
            // Write synchronously and only drop the old copy once the file definitely exists.
            if Self.write(decoded) {
                UserDefaults.standard.removeObject(forKey: legacySaveKey)
            }
        }
    }
}

// MARK: - Text Stats

nonisolated enum TextStats {
    /// Lines / words / characters in one pass over UTF-16 (words) plus a grapheme count.
    static func compute(_ text: String) -> (lines: Int, words: Int, chars: Int) {
        guard !text.isEmpty else { return (1, 0, 0) }
        var lines = 1
        var words = 0
        var inWord = false
        var afterCR = false
        for unit in text.utf16 {
            let isSpace = unit == 32 || unit == 9 || unit == 10 || unit == 13 || unit == 0xA0 || unit == 0x2028 || unit == 0x2029
            // LF, CR and CRLF each end one line.
            if unit == 13 || (unit == 10 && !afterCR) { lines += 1 }
            afterCR = unit == 13
            if isSpace {
                inWord = false
            } else if !inWord {
                inWord = true
                words += 1
            }
        }
        return (lines, words, text.count)
    }
}

/// Live status-bar values. Kept out of `EditorViewModel`'s published state so that cursor
/// moves and stat updates only re-render the small views that display them, not the whole editor.
final class EditorStatus: ObservableObject {
    @Published var cursorLine = 1
    @Published var cursorColumn = 1
    @Published var lines = 1
    @Published var words = 0
    @Published var chars = 0
    @Published var indentation: Indentation = .spaces(4)
    @Published var lineEnding: LineEnding = .lf
}

/// One of the editor's two documents: the edit of copied text, or the scratch pad.
struct EditorBuffer {
    var text = ""
    var baseText = ""
    var language = "plaintext"
    var languageIsManual = false
    var sourceEntryID: UUID?
    var selection = NSRange(location: 0, length: 0)

    var isDirty: Bool { text != baseText }
}

/// Where the edit document's text came from, shown in the window title so it's clear
/// whether the hotkey picked up a selection, the clipboard or an earlier unsaved edit.
enum EditorOrigin: Equatable {
    case selection(app: String?)
    case clipboard
    case restored
    case history

    var title: String {
        switch self {
        case .selection(let app): return app.map { "Selection from \($0)" } ?? "Selection"
        case .clipboard:          return "Clipboard"
        case .restored:           return "Unsaved Edit"
        case .history:            return "Recent Snippet"
        }
    }
}

// ViewModel for editor state
class EditorViewModel: ObservableObject {
    /// The text view is the source of truth while editing — typing doesn't round-trip
    /// through SwiftUI. `loadedText` is only what was last pushed *into* the editor.
    private(set) var loadedText: String = ""
    private(set) var loadedSelection = NSRange(location: 0, length: 0)
    /// Bumped whenever new text is pushed into the editor; `CustomTextEditor` applies it then.
    @Published private(set) var loadGeneration = 0
    /// The generation the text view has applied. Until it catches up, the text view still
    /// holds the previous document, so `text` answers from `loadedText` instead.
    var appliedGeneration = -1
    @Published var currentLanguage: String = "plaintext"
    var baseText: String = ""
    var languageIsManual: Bool = false  // true when user explicitly picked a language
    var sourceEntryID: UUID? = nil      // set when editing an existing history entry
    /// Showing the scratch pad rather than the edit of copied text. They're separate
    /// documents: switching parks the one on screen and brings back the other, so opening
    /// the editor on copied text never pushes the scratch pad out.
    @Published private(set) var isScratch = false
    /// The document that isn't on screen.
    private var parked = EditorBuffer()
    /// Where the edit document came from (the scratch pad is always just "Scratch Pad").
    @Published var origin: EditorOrigin = .clipboard
    /// Large text, minimal chrome, and the window stays up when the app loses focus.
    @Published var isPresenting = false
    let status = EditorStatus()
    weak var textView: NSTextView?
    /// Set by the editor view: closes the editor the way Esc does (Find bar included).
    var requestClose: (() -> Void)?

    private var textViewIsCurrent: Bool { textView != nil && appliedGeneration == loadGeneration }

    /// The current editor contents.
    var text: String { textViewIsCurrent ? textView!.string : loadedText }

    var isDirty: Bool { text != baseText }

    /// The on-screen document as it stands now.
    var current: EditorBuffer {
        EditorBuffer(
            text: text, baseText: baseText, language: currentLanguage, languageIsManual: languageIsManual,
            sourceEntryID: sourceEntryID, selection: textViewIsCurrent ? textView!.selectedRange() : loadedSelection
        )
    }

    /// The edit or scratch document, whether or not it's on screen.
    func buffer(scratch: Bool) -> EditorBuffer {
        scratch == isScratch ? current : parked
    }

    /// Puts the scratch pad (or the edit) on screen, parking the other where it was.
    func show(scratch: Bool) {
        guard scratch != isScratch else { return }
        let other = parked
        parked = current
        apply(other, scratch: scratch)
    }

    /// Highlighting multi-MB documents costs seconds of CPU and a main-thread hitch applying
    /// the attributes; those default to plain text (users can still pick a language).
    static func detectLanguage(_ text: String) -> String {
        text.utf16.count > 1_000_000 ? "plaintext" : CustomTextEditor.Coordinator.guessLanguage(text)
    }

    /// Load new text into the edit document and mark it as the saved baseline. Passing a
    /// language marks it as a manual choice; otherwise it's detected here, up front, so the
    /// editor highlights once with the right grammar instead of flashing the previous
    /// document's language first.
    func load(_ newText: String, language: String? = nil) {
        show(scratch: false)
        let detected = language ?? Self.detectLanguage(newText)
        apply(EditorBuffer(text: newText, baseText: newText, language: detected, languageIsManual: language != nil), scratch: false)
    }

    /// Empties the scratch pad and shows it.
    func loadScratch() {
        show(scratch: true)
        apply(EditorBuffer(), scratch: true)
    }

    /// Replaces a document, on screen or parked — e.g. with a draft from the previous run.
    func set(_ buffer: EditorBuffer, scratch: Bool) {
        if scratch == isScratch {
            apply(buffer, scratch: scratch)
        } else {
            parked = buffer
        }
    }

    /// Mark the current text as saved.
    func markSaved() {
        baseText = text
    }

    /// Throws away the on-screen document so nothing can bring it back.
    func discard() {
        apply(EditorBuffer(), scratch: isScratch)
    }

    private func apply(_ buffer: EditorBuffer, scratch: Bool) {
        loadedText = buffer.text
        loadedSelection = buffer.selection
        baseText = buffer.baseText
        currentLanguage = buffer.language
        languageIsManual = buffer.languageIsManual
        sourceEntryID = buffer.sourceEntryID
        isScratch = scratch
        loadGeneration += 1
    }
}

/// An editor document persisted across app launches: the unsaved edit in draft.json, the
/// scratch pad in scratch.json.
struct EditorDraft: Codable, Equatable {
    let text: String
    let baseText: String
    let language: String
    let languageIsManual: Bool
    let sourceEntryID: UUID?
    let clipboardChangeCount: Int
    /// Older versions kept a single draft, which could be the scratch pad.
    let isScratch: Bool?

    init(_ buffer: EditorBuffer, clipboardChangeCount: Int, isScratch: Bool) {
        text = buffer.text
        baseText = buffer.baseText
        language = buffer.language
        languageIsManual = buffer.languageIsManual
        sourceEntryID = buffer.sourceEntryID
        self.clipboardChangeCount = clipboardChangeCount
        self.isScratch = isScratch
    }

    var buffer: EditorBuffer {
        EditorBuffer(
            text: text, baseText: baseText,
            language: languageIsManual ? language : EditorViewModel.detectLanguage(text),
            languageIsManual: languageIsManual, sourceEntryID: sourceEntryID
        )
    }

    private static func url(scratch: Bool) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mangle", isDirectory: true)
            .appendingPathComponent(scratch ? "scratch.json" : "draft.json")
    }

    private static func read(scratch: Bool) -> EditorDraft? {
        guard let data = try? Data(contentsOf: url(scratch: scratch)) else { return nil }
        return try? JSONDecoder().decode(EditorDraft.self, from: data)
    }

    /// The edit and scratch drafts from the previous run.
    static func load() -> (edit: EditorDraft?, scratch: EditorDraft?) {
        var edit = read(scratch: false)
        var scratch = read(scratch: true)
        if edit?.isScratch == true {
            if scratch == nil { scratch = edit }
            edit = nil
        }
        return (edit, scratch)
    }

    func save() {
        let url = Self.url(scratch: isScratch == true)
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func clear(scratch: Bool) {
        try? FileManager.default.removeItem(at: url(scratch: scratch))
    }
}

extension Notification.Name {
    static let clearHistory = Notification.Name("ClearHistory")
}
