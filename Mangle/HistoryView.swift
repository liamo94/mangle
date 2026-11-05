import SwiftUI
import AppKit
import Combine
import Highlightr


private let abbreviatedRelativeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter
}()

func formatRelativeDate(_ date: Date) -> String {
    abbreviatedRelativeFormatter.localizedString(for: date, relativeTo: Date())
}

/// Which entries History lists: everything, edited clipboard text, scratch pads, or pinned.
enum HistoryFilter: String, CaseIterable {
    case all, clipboard, scratch, pinned

    var label: String {
        switch self {
        case .all: "All"
        case .clipboard: "Clipboard"
        case .scratch: "Scratch"
        case .pinned: "Pinned"
        }
    }

    func includes(_ entry: HistoryEntry) -> Bool {
        switch self {
        case .all: true
        case .clipboard: !entry.isScratch
        case .scratch: entry.isScratch
        case .pinned: entry.isPinned
        }
    }

    /// What the empty list says when nothing matches.
    var emptyTitle: String {
        switch self {
        case .all: "No History"
        case .clipboard: "No Clipboard Edits"
        case .scratch: "No Scratch Pads"
        case .pinned: "Nothing Pinned"
        }
    }

    var emptySubtitle: String {
        switch self {
        case .all: "Saved edits will appear here"
        case .clipboard: "Saved edits of copied text will appear here"
        case .scratch: "Saved scratch pads will appear here"
        case .pinned: "Pin an entry with ⌘P to keep it here"
        }
    }
}

struct HistoryView: View {
    @ObservedObject var historyManager: HistoryManager
    var onSelectEntry: (HistoryEntry) -> Void
    var onPaste: (HistoryEntry) -> Void = { _ in }
    var onClose: () -> Void
    
    @State private var selectedEntry: HistoryEntry?
    @State private var searchText = ""
    @AppStorage("HistoryFilter") private var filter: HistoryFilter = .all
    @State private var hoverCopy = false
    @State private var hoverPaste = false
    @State private var hoverEdit = false
    @State private var hoverDelete = false
    /// The listed entries. Stored rather than computed: searching thousands of entries on
    /// every redraw (each hover, each arrow key) made large histories stutter.
    @State private var filteredEntries: [HistoryEntry] = []
    @ObservedObject private var settings = SettingsManager.shared
    @State private var lastTapEntry: HistoryEntry.ID? = nil
    @State private var lastTapTime: Date = .distantPast
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    
    /// Filters and orders entries; only rerun when the search, tab or entries change.
    private func computeEntries(from all: [HistoryEntry]) -> [HistoryEntry] {
        let filter = filter
        let searchText = searchText
        let base = all.filter { entry in
            filter.includes(entry) && (searchText.isEmpty || entry.text.localizedCaseInsensitiveContains(searchText))
        }
        // Pinned entries first, otherwise keeping recency order (stable, unlike sorted(by:))
        return base.filter(\.isPinned) + base.filter { !$0.isPinned }
    }
    
    var body: some View {
        let entries = filteredEntries
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar(entries: entries)
                Divider()
                detailPane
            }
            
            Divider()
            bottomBar
        }
        .frame(minWidth: 640, minHeight: 420)
        .onAppear {
            filteredEntries = computeEntries(from: historyManager.entries)
            selectedEntry = filteredEntries.first
            // The app delegate's key monitor hands this window's keys here. Registering a
            // handler (rather than a monitor per view) means a replaced window's view can't
            // keep handling keys for the new one.
            AppDelegate.shared?.historyKeyHandler = handleKey
        }
        .onChange(of: searchText) { refreshEntries(historyManager.entries) }
        .onChange(of: filter) { refreshEntries(historyManager.entries) }
        // Not onChange: entries compare by ID, so pinning or editing one wouldn't count as a change.
        .onReceive(historyManager.$entries.dropFirst()) { refreshEntries($0) }
    }
    
    /// Recomputes the list, keeping the selection on a listed entry so Return/⌘↩ act on
    /// what's shown. Unpinning in the Pinned tab, say, takes the entry out of the list.
    private func refreshEntries(_ all: [HistoryEntry]) {
        let entries = computeEntries(from: all)
        filteredEntries = entries
        if let selected = selectedEntry, let fresh = entries.first(where: { $0.id == selected.id }) {
            selectedEntry = fresh // pick up a changed pin or text
            return
        }
        selectedEntry = entries.first
    }

    /// Steps through the filter tabs, wrapping around.
    private func cycleFilter(by offset: Int) {
        let all = HistoryFilter.allCases
        let idx = all.firstIndex(of: filter) ?? 0
        filter = all[(idx + offset + all.count) % all.count]
    }

    /// Every key pressed while History is the key window. Returns nil when handled.
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        // Mid-composition with an input method (Japanese, Chinese…), Return and Esc belong
        // to the search field: they confirm or cancel the characters being composed.
        if let editor = event.window?.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        // Ask AppKit rather than trusting `searchFocused` alone: type-to-search focuses the
        // field directly, and SwiftUI's copy of that can lag a keystroke behind.
        let inSearch = searchFocused || (event.window?.firstResponder as? NSTextView)?.isFieldEditor == true
        switch event.keyCode {
        case 53: // Escape clears a search first, then closes
            if !searchText.isEmpty { searchText = ""; return nil }
            onClose()
            return nil
        case 125 where mods.isEmpty: leaveSearch(event); navigateSelection(by: +1); return nil  // ↓
        case 126 where mods.isEmpty: leaveSearch(event); navigateSelection(by: -1); return nil  // ↑
        case 36, 76: // Return edits, ⌘Return pastes — from the search field too
            if let entry = selectedEntry {
                mods == .command ? onPaste(entry) : onSelectEntry(entry)
            }
            return nil
        case 51 where mods.isEmpty && !inSearch: // Delete
            if let entry = selectedEntry { deleteEntry(entry) }
            return nil
        default: break
        }
        if mods == .command, let key {
            switch key {
            case "w": onClose(); return nil
            case "c": if let entry = selectedEntry { copyAndClose(entry) }; return nil
            case "f": searchFocused = true; return nil
            case "p": if let entry = selectedEntry { historyManager.togglePin(entry) }; return nil
            case "[": cycleFilter(by: -1); return nil
            case "]": cycleFilter(by: +1); return nil
            case "z" where !inSearch: undoDelete(); return nil
            case "1"..."9":
                let entries = filteredEntries
                if let n = Int(key), entries.indices.contains(n - 1) { onPaste(entries[n - 1]) }
                return nil
            default:
                // App-wide shortcuts and the search field's own (⌘A, ⌘V…) still work; anything
                // else would only beep at the list.
                return inSearch || "qhm,".contains(key) ? event : nil
            }
        }
        guard !inSearch else { return event }
        // Typing anywhere searches: focus the field now and let it take this key itself, so
        // no keystroke can land before the field is ready. A leading space is ignored — it
        // would match nearly everything.
        if mods.subtracting(.shift).isEmpty, let chars = event.characters, !chars.isEmpty,
           chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) }) {
            if searchText.isEmpty, chars.allSatisfy(\.isWhitespace) { return nil }
            guard let window = event.window, let field = Self.searchField(in: window.contentView) else { return nil }
            window.makeFirstResponder(field)
            // Becoming first responder selects the field's text; type after it instead.
            (field.currentEditor() as? NSTextView)?.moveToEndOfDocument(nil)
            return event
        }
        // List navigation keys reach the list; anything else would only beep.
        let listKeys: Set<UInt16> = [48, 115, 116, 119, 121, 123, 124] // Tab, Home, PgUp, End, PgDn, ←, →
        return listKeys.contains(event.keyCode) ? event : nil
    }

    /// Moves focus off the search field, back to the list.
    private func leaveSearch(_ event: NSEvent) {
        searchFocused = false
        if (event.window?.firstResponder as? NSTextView)?.isFieldEditor == true {
            event.window?.makeFirstResponder(nil)
        }
    }

    /// The search box's text field (the only editable one in the window).
    private static func searchField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let field = searchField(in: subview) { return field }
        }
        return nil
    }

    private func undoDelete() {
        guard let entry = historyManager.undoDelete() else { return }
        searchText = ""
        selectedEntry = entry
        AppDelegate.shared?.showToast("Restored")
    }

    private func navigateSelection(by offset: Int) {
        let entries = filteredEntries
        guard !entries.isEmpty else { return }
        if let current = selectedEntry, let idx = entries.firstIndex(where: { $0.id == current.id }) {
            let next = idx + offset
            if next >= 0 && next < entries.count { selectedEntry = entries[next] }
        } else {
            selectedEntry = offset > 0 ? entries.first : entries.last
        }
    }
    
    // MARK: - Bottom Bar
    
    /// Laid out like the editor's bottom bar, from the same parts.
    private var bottomBar: some View {
        HStack(spacing: 0) {
            if let entry = selectedEntry {
                let meta = historyManager.meta(for: entry)
                HStack(spacing: 12) {
                    Text(formatRelativeDate(entry.timestamp))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize()
                    HStack(spacing: 10) {
                        BarStat(value: meta.lines, label: "ln")
                        BarStat(value: meta.words, label: "wd")
                        BarStat(value: meta.chars, label: "ch")
                    }
                    .fixedSize()
                }
                .padding(.horizontal, 14)
            }
            
            Spacer(minLength: 0)
            
            if let entry = selectedEntry {
                Button { deleteEntry(entry) } label: {
                    BarActionLabel(title: "Delete", systemImage: "trash", hovered: hoverDelete)
                }
                .buttonStyle(.plain)
                .onHover { hoverDelete = $0 }
                .help("Delete (⌫) — ⌘Z brings it back")
                .padding(.horizontal, 8)
                
                BarDivider()
                
                HStack(spacing: 4) {
                    Button { copyAndClose(entry) } label: {
                        BarActionLabel(title: "Copy", shortcut: "⌘C", hovered: hoverCopy)
                    }
                    .buttonStyle(.plain)
                    .onHover { hoverCopy = $0 }
                    .help("Copy to the clipboard and close (⌘C)")
                    
                    Button { onPaste(entry) } label: {
                        BarActionLabel(title: "Paste", shortcut: "⌘↩", hovered: hoverPaste)
                    }
                    .buttonStyle(.plain)
                    .onHover { hoverPaste = $0 }
                    .help("Paste into the app you came from (⌘↩, or ⌘1–⌘9 for the first nine)")
                    
                    Button { onSelectEntry(entry) } label: {
                        BarPrimaryActionLabel(title: "Edit", shortcut: "↩", hovered: hoverEdit)
                    }
                    .buttonStyle(.plain)
                    .onHover { hoverEdit = $0 }
                    .help("Open in the editor (↩)")
                }
                .padding(.leading, 8)
                .padding(.trailing, 10)
            }
        }
        .frame(height: 36)
        .background(Color(nsColor: AppTheme.windowBG))
    }
    
    // MARK: - Sidebar
    
    private func sidebar(entries: [HistoryEntry]) -> some View {
        VStack(spacing: 0) {
            searchBar
            
            Divider()
            
            TealSegmentedPicker(selection: $filter, options: HistoryFilter.allCases.map { ($0, $0.label) })
                .font(.system(size: 11))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .help("Show all entries, edited clipboard text, scratch pads or pinned entries (⌘[ and ⌘] switch)")
            
            if entries.isEmpty {
                emptyState(
                    icon: searchText.isEmpty ? "doc.text" : "magnifyingglass",
                    title: searchText.isEmpty ? filter.emptyTitle : "No Results",
                    subtitle: searchText.isEmpty ? filter.emptySubtitle : "No entries match your search — Esc clears it"
                )
            } else {
                ScrollViewReader { proxy in
                    // No selection binding: the list's own highlight would paint over the
                    // row's, and keys and clicks already drive `selectedEntry`.
                    List {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            let isSelected = selectedEntry?.id == entry.id
                            HistoryEntryRow(entry: entry, meta: historyManager.meta(for: entry), isSelected: isSelected,
                                            pasteShortcut: index < 9 ? "⌘\(index + 1)" : nil,
                                            codeFont: settings.editorFont)
                                .onTapGesture {
                                    NSApp.keyWindow?.makeFirstResponder(nil)
                                    let now = Date()
                                    if lastTapEntry == entry.id && now.timeIntervalSince(lastTapTime) < 0.4 {
                                        onSelectEntry(entry)
                                    } else {
                                        selectedEntry = entry
                                        lastTapEntry = entry.id
                                        lastTapTime = now
                                    }
                                }
                                .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .contextMenu {
                                    Button("Paste") { onPaste(entry) }
                                    Button("Copy to Clipboard") { copyAndClose(entry) }
                                    Button("Edit") { onSelectEntry(entry) }
                                    Divider()
                                    Button(entry.isPinned ? "Unpin (⌘P)" : "Pin (⌘P)") {
                                        historyManager.togglePin(entry)
                                    }
                                    Divider()
                                    Button("Delete", role: .destructive) { deleteEntry(entry) }
                                }
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                deleteEntry(entries[index])
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .onChange(of: selectedEntry) { _, entry in
                        if let entry { proxy.scrollTo(entry.id) }
                    }
                    .onChange(of: historyManager.entries) {
                        if let entry = selectedEntry {
                            DispatchQueue.main.async { proxy.scrollTo(entry.id) }
                        }
                    }
                }
            }
        }
        .frame(width: 260)
        .background(Color(nsColor: AppTheme.windowBG))
    }
    
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(AppTheme.tealSUI)
                .imageScale(.small)
            TextField("Type to search…", text: $searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .imageScale(.small)
                }
                .buttonStyle(.borderless)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .frame(height: 36)
    }
    
    // MARK: - Detail Pane
    
    @ViewBuilder
    private var detailPane: some View {
        if let entry = selectedEntry {
            let lang = entry.language ?? historyManager.meta(for: entry).detectedLanguage
            // No .id(entry.id): recreating the view per selection built a fresh Highlightr
            // (a new JS context evaluating ~1 MB of highlight.js) on every arrow key.
            SyntaxPreviewView(entryID: entry.id, text: entry.text, language: lang, lineCount: historyManager.meta(for: entry).lines,
                              font: settings.editorFont.nsFont(size: settings.fontSize), isDark: colorScheme == .dark)
        } else {
            emptyState(
                icon: "sidebar.left",
                title: "Select an Entry",
                subtitle: "Choose a clipboard entry from the list"
            )
        }
    }
    
    // MARK: - Helpers
    
    @ViewBuilder
    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .thin))
                .foregroundColor(AppTheme.tealSUI.opacity(0.5))
            Text(title)
                .font(.headline)
                .foregroundColor(.secondary)
            Text(subtitle)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func copyAndClose(_ entry: HistoryEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
        onClose()
        AppDelegate.shared?.showToast("Copied to clipboard")
    }
    
    private func deleteEntry(_ entry: HistoryEntry) {
        if selectedEntry?.id == entry.id {
            if let index = filteredEntries.firstIndex(where: { $0.id == entry.id }) {
                if index > 0 {
                    selectedEntry = filteredEntries[index - 1]
                } else if index + 1 < filteredEntries.count {
                    selectedEntry = filteredEntries[index + 1]
                } else {
                    selectedEntry = nil
                }
            } else {
                selectedEntry = nil
            }
        }
        historyManager.deleteEntry(entry)
        AppDelegate.shared?.showToast("Deleted — ⌘Z to undo")
    }
}

// MARK: - Row

struct HistoryEntryRow: View {
    let entry: HistoryEntry
    let meta: HistoryEntryMeta
    var isSelected: Bool = false
    /// The row's own state, so hovering redraws just this row rather than all of History.
    @State private var isHovered = false
    /// "⌘1"…"⌘9" for the first nine rows, which those keys paste.
    var pasteShortcut: String? = nil
    /// The editor's font, so a snippet reads here as it will there.
    var codeFont: EditorFont = .system
    
    private var language: String { entry.language ?? meta.detectedLanguage }
    private var secondLine: String? {
        guard let line = meta.secondLine, !line.allSatisfy(\.isWhitespace) else { return nil }
        return line
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(meta.preview)
                .font(Font(codeFont.nsFont(size: 12)))
                .foregroundColor(.primary.opacity(isSelected ? 1 : 0.85))
                .lineLimit(1)
            
            if let secondLine {
                Text(secondLine)
                    .font(Font(codeFont.nsFont(size: 11)))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            HStack(spacing: 5) {
                if entry.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundColor(AppTheme.tealSUI)
                }
                if entry.isScratch {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .help("Saved from a scratch pad")
                }
                Text(formatRelativeDate(entry.timestamp))
                    .foregroundColor(.secondary)
                if language != "plaintext" {
                    Circle()
                        .fill(EditorView.languageColor(language))
                        .frame(width: 6, height: 6)
                        .padding(.leading, 3)
                    Text(EditorView.languageLabel(language))
                        .foregroundColor(.secondary)
                }
                if let pasteShortcut {
                    Spacer(minLength: 4)
                    Text(pasteShortcut)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary.opacity(isSelected || isHovered ? 0.8 : 0.5))
                }
            }
            .font(.system(size: 10))
            .padding(.top, 1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? AppTheme.tealSUI.opacity(0.16)
                      : isHovered ? Color.secondary.opacity(0.08) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

// MARK: - Syntax Preview

struct SyntaxPreviewView: NSViewRepresentable {
    let entryID: UUID
    let text: String
    let language: String
    let lineCount: Int
    let font: NSFont
    let isDark: Bool
    
    /// One highlighter shared by every preview — creating a Highlightr evaluates ~1 MB of
    /// highlight.js in a fresh JSContext (~20ms), far too slow to do per selection.
    private static let sharedHighlightr: Highlightr? = Highlightr()
    
    class Coordinator {
        let codeStorage: NSTextStorage
        var shownEntryID: UUID?
        var shownLanguage: String?
        var appliedTheme: String?
        var appliedFont: NSFont?
        var rulerView: LineNumberRulerView?
        
        init() {
            if let h = SyntaxPreviewView.sharedHighlightr {
                codeStorage = CodeAttributedString(highlightr: h)
            } else {
                codeStorage = NSTextStorage()
            }
        }
    }
    
    func makeCoordinator() -> Coordinator { Coordinator() }
    
    /// Built like the editor's text view (same text view class, inset and gutter), only read-only.
    func makeNSView(context: Context) -> NSScrollView {
        let textStorage = context.coordinator.codeStorage
        
        let layoutManager = NSLayoutManager()
        layoutManager.allowsNonContiguousLayout = true
        textStorage.addLayoutManager(layoutManager)
        
        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)
        
        let textView = MangleTextView(frame: .zero, textContainer: textContainer)
        layoutManager.delegate = textView   // hides folded text
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.showsCurrentLine = false
        textView.textContainerInset = CustomTextEditor.Coordinator.textInset(presenting: false)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.wantsLayer = true
        
        let rulerView = LineNumberRulerView(scrollView: scrollView, orientation: .verticalRuler)
        rulerView.clientView = textView
        scrollView.verticalRulerView = rulerView
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        context.coordinator.rulerView = rulerView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let textView = scrollView.documentView as? NSTextView else { return }
        
        let theme = SettingsManager.shared.themeName(isDark: isDark)
        let themeChanged = coordinator.appliedTheme != theme
        // A zoom in the editor (this window can be open behind it) only needs the font
        // swapped in, not a fresh highlight.
        if !themeChanged, coordinator.appliedFont != font, let h = Self.sharedHighlightr,
           let storage = coordinator.codeStorage as? CodeAttributedString {
            coordinator.appliedFont = font
            CustomTextEditor.Coordinator.swapFonts(in: storage, theme: h.theme, to: font)
            textView.needsDisplay = true
            coordinator.rulerView?.fontSize = font.pointSize
            coordinator.rulerView?.needsDisplay = true
        }
        if themeChanged, let h = Self.sharedHighlightr {
            coordinator.appliedTheme = theme
            coordinator.appliedFont = font
            h.setTheme(to: theme)
            h.theme.setCodeFont(font)
            let bg = h.theme.themeBackgroundColor ?? (isDark ? AppTheme.editorDarkBG : .textBackgroundColor)
            textView.backgroundColor = bg
            scrollView.backgroundColor = bg
            coordinator.rulerView?.fontSize = font.pointSize
            coordinator.rulerView?.needsDisplay = true
        }
        coordinator.rulerView?.setLineCount(lineCount)
        
        guard let storage = coordinator.codeStorage as? CodeAttributedString else {
            if coordinator.shownEntryID != entryID {
                coordinator.shownEntryID = entryID
                textView.string = text
            }
            return
        }
        // Huge entries: plain text, for the same reason as the editor.
        let lang = text.utf16.count > 1_000_000 ? "plaintext" : language
        if coordinator.shownEntryID != entryID {
            coordinator.shownEntryID = entryID
            coordinator.shownLanguage = lang
            // Swap text with highlighting off, then highlight once with the right language.
            storage.language = nil
            let oldLength = storage.length
            (textView as? MangleTextView)?.folds = []
            storage.replaceCharacters(in: NSRange(location: 0, length: oldLength), with: text)
            (textView as? MangleTextView)?.noteCharactersEdited(in: NSRange(location: 0, length: storage.length),
                                                                 changeInLength: storage.length - oldLength)
            storage.language = lang
            textView.scroll(.zero)
            coordinator.rulerView?.needsDisplay = true
        } else if coordinator.shownLanguage != lang || themeChanged {
            coordinator.shownLanguage = lang
            storage.language = nil
            storage.language = lang
        }
    }
}
