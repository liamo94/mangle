import SwiftUI
import AppKit
import Combine
import Highlightr

// MARK: - Theme

enum AppTheme {
    static let teal    = NSColor(red: 0.20, green: 0.78, blue: 0.60, alpha: 1.0)
    static let tealSUI = Color(red: 0.20, green: 0.78, blue: 0.60)
    /// Text on a teal fill — white only reaches ~2:1 contrast there.
    static let onTeal    = NSColor(red: 0.04, green: 0.10, blue: 0.08, alpha: 0.88)
    static let onTealSUI = Color(red: 0.04, green: 0.10, blue: 0.08)
    static let editorDarkBG = NSColor(srgbRed: 0.075, green: 0.087, blue: 0.087, alpha: 1.0)

    /// Window and bar backgrounds: darker than the system's in dark mode, unchanged in light.
    static let windowBG = dynamic(dark: NSColor(srgbRed: 0.080, green: 0.088, blue: 0.088, alpha: 1), light: .windowBackgroundColor)
    /// Cards, find bar and key caps: a step lighter than `windowBG` in dark mode, so they stand off it.
    static let controlBG = dynamic(dark: NSColor(srgbRed: 0.125, green: 0.135, blue: 0.135, alpha: 1), light: .controlBackgroundColor)

    /// The editor's bars and title bar: the syntax theme's background a shade darker, so the
    /// window reads as one surface with the text area still set apart.
    static func editorChrome(themeBackground: NSColor) -> NSColor {
        let rgb = themeBackground.usingColorSpace(.sRGB) ?? themeBackground
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return rgb.blended(withFraction: luminance < 0.5 ? 0.22 : 0.05, of: .black) ?? rgb
    }

    private static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}

/// Sets the hosting window's background colour (which a transparent title bar shows).
struct WindowBackground: NSViewRepresentable {
    var color: NSColor

    func makeNSView(context: Context) -> NSView { WindowBackgroundView() }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? WindowBackgroundView)?.color = color
    }

    private final class WindowBackgroundView: NSView {
        var color: NSColor? { didSet { apply() } }
        override func viewDidMoveToWindow() { apply() }
        private func apply() {
            guard let window, let color, window.backgroundColor != color else { return }
            window.backgroundColor = color
        }
    }
}

// MARK: - Editor Font

/// The editor's font: the system's monospaced font (SF Mono), or any installed fixed-pitch
/// family, saved by family name.
struct EditorFont: RawRepresentable, Identifiable, Hashable {
    let rawValue: String

    static let system = EditorFont(rawValue: "System")

    init(rawValue: String) {
        // "SF Mono" was its own choice, but it's the system font and can't be loaded by name.
        self.rawValue = rawValue == "SF Mono" ? "System" : rawValue
    }

    var id: String { rawValue }
    var label: String { self == .system ? "System (SF Mono)" : rawValue }

    /// The system font, then every installed fixed-pitch family by name. Looked up once:
    /// fonts installed while the app is running show up after a relaunch.
    static let allCases: [EditorFont] = {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        let families = Set(names.compactMap { NSFont(name: $0, size: 12)?.familyName }.filter { !$0.hasPrefix(".") })
        return [.system] + families.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map(EditorFont.init)
    }()

    func nsFont(size: CGFloat) -> NSFont {
        guard self != .system,
              let font = NSFontManager.shared.font(withFamily: rawValue, traits: [], weight: 5, size: size) else {
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        }
        return font
    }
}

// MARK: - Line Number Gutter

class LineNumberRulerView: NSRulerView {
    var fontSize: CGFloat = NSFont.systemFontSize { didSet { if fontSize != oldValue { updateThickness() } } }
    /// Off while presenting: the gutter then only holds fold chevrons.
    var showsLineNumbers = true { didSet { if showsLineNumbers != oldValue { updateThickness() } } }
    var activeLine: Int = 0
    private var digitCount = 1
    private var thickness: CGFloat = 52
    /// Fold chevrons for unfolded blocks only show while the pointer is over the gutter.
    private var isHovering = false { didSet { if isHovering != oldValue { needsDisplay = true } } }
    private static let foldColumnWidth: CGFloat = 16
    /// Just under the text size, so the numbers read clearly without competing with it.
    private var numberFontSize: CGFloat { (fontSize * 0.95).rounded() }
    
    override var isFlipped: Bool { true }
    override var requiredThickness: CGFloat { thickness }
    /// Views stopped clipping by default in macOS 14; with `draw(_:)` overridden, the ruler's
    /// background otherwise paints over the whole editor and hides the text.
    override var clipsToBounds: Bool { get { true } set {} }
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    
    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }
    
    /// Clicking the fold column (or anywhere, when line numbers are hidden) toggles the
    /// block that opens on that line.
    override func mouseDown(with event: NSEvent) {
        guard let textView = clientView as? MangleTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard !showsLineNumbers || point.x >= bounds.width - Self.foldColumnWidth - 4 else { return }
        let y = point.y + textView.visibleRect.origin.y - textView.textContainerInset.height
        let length = (textView.string as NSString).length
        guard length > 0, y >= 0 else { return }
        let glyph = layoutManager.glyphIndex(for: NSPoint(x: 1, y: y), in: container)
        let char = min(layoutManager.characterIndexForGlyph(at: glyph), length - 1)
        let lineStart = (textView.string as NSString).lineRange(for: NSRange(location: char, length: 0)).location
        textView.toggleFold(onLine: textView.lineNumber(at: lineStart))
    }
    
    /// Widen the gutter once line numbers need more digits than the default width fits.
    func setLineCount(_ count: Int) {
        let digits = String(max(count, 1)).count
        guard digits != digitCount else { return }
        digitCount = digits
        updateThickness()
    }
    
    private func updateThickness() {
        let font = NSFont.monospacedSystemFont(ofSize: numberFontSize, weight: .semibold)
        let digitWidth = ("8" as NSString).size(withAttributes: [.font: font]).width
        let newThickness = showsLineNumbers
            ? max(52, ceil(CGFloat(digitCount) * digitWidth + 12 + Self.foldColumnWidth))
            : Self.foldColumnWidth + 8
        guard newThickness != thickness else { return }
        thickness = newThickness
        scrollView?.tile()
        needsDisplay = true
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Dim the gutter beside the lines a spotlight leaves out, as the editor does.
        guard let textView = clientView as? MangleTextView else { return }
        textView.drawSpotlightDimming(in: bounds, scrolledBy: textView.visibleRect.origin.y, dirtyRect: dirtyRect)
    }
    
    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? MangleTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        // The editor's own background, so the gutter suits whichever syntax theme is active.
        textView.backgroundColor.setFill()
        bounds.fill()
        
        // Chevrons only show on hover, for folded lines, or while presenting — don't rescan
        // the document on every keystroke's redraw otherwise.
        let showsChevrons = isHovering || !showsLineNumbers || !textView.folds.isEmpty
        let (foldRegions, foldByLine) = showsChevrons ? textView.foldRegions(allowingStale: true) : ([], [:])
        let chevronColor = AppTheme.teal.withAlphaComponent(isDark ? 0.7 : 0.8)
        
        // Neutral numbers so the current one, in teal, stands out.
        let numberFont = NSFont.monospacedSystemFont(ofSize: numberFontSize, weight: .regular)
        let inactiveAttrs: [NSAttributedString.Key: Any] = [
            .font: numberFont,
            .foregroundColor: isDark ? NSColor.white.withAlphaComponent(0.26) : NSColor.black.withAlphaComponent(0.3)
        ]
        let activeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: numberFontSize, weight: .semibold),
            .foregroundColor: AppTheme.teal
        ]
        // The numbers are smaller than the text, so drop them onto its baseline.
        let textFont = textView.typingAttributes[.font] as? NSFont ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let baselineShift = max(0, textFont.ascender - numberFont.ascender)
        
        let text  = textView.string as NSString
        let len   = text.length
        let inset = textView.textContainerInset.height
        let width = bounds.width
        let h     = bounds.height
        // Read scroll position directly from the text view — always current at draw time.
        let scrollOffset = textView.visibleRect.origin.y
        
        // Carry the editor's current-line band across, using its exact rect so it lands on the
        // caret's wrapped row and hides whenever the editor's does (selection, multiple carets).
        if showsLineNumbers, let band = textView.currentLineRect() {
            (isDark ? NSColor.white.withAlphaComponent(0.045) : NSColor.black.withAlphaComponent(0.045)).setFill()
            NSRect(x: 0, y: band.minY - scrollOffset, width: width, height: band.height).fill(using: .sourceOver)
        }

        func drawNum(_ n: Int, _ docY: CGFloat, lineHeight: CGFloat = 0) {
            // docY is layout-manager space. Add inset → text-view/document space.
            // Subtract scrollOffset → position relative to the ruler's visible top.
            let y = docY + inset - scrollOffset
            guard y > -20 && y < h + 20 else { return }
            let attrs = n == activeLine ? activeAttrs : inactiveAttrs
            if showsLineNumbers {
                let s  = "\(n)" as NSString
                let sz = s.size(withAttributes: attrs)
                s.draw(at: NSPoint(x: width - sz.width - Self.foldColumnWidth - 2, y: y + baselineShift), withAttributes: attrs)
            }
            if let index = foldByLine[n] {
                let folded = textView.isFolded(foldRegions[index])
                if folded || isHovering || !showsLineNumbers {
                    let height = lineHeight > 0 ? lineHeight : fontSize * 1.2
                    drawChevron(folded: folded, centerX: width - Self.foldColumnWidth / 2 - 2, centerY: y + height / 2,
                                color: folded ? AppTheme.teal : chevronColor)
                }
            }
        }

        if len == 0 { drawNum(1, 0); return }

        // Walk only the visible (+ padding) glyph range. glyphRange(forBoundingRect:) lays out
        // just that region (non-contiguous layout is on), so we never force a whole-document
        // layout here — that used to make every keystroke O(document) on long files.
        var visibleRect = textView.visibleRect
        visibleRect.origin.y -= 200 + inset
        visibleRect.size.height += 400
        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        var visibleCharRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)
        visibleCharRange.length = min(visibleCharRange.length, len - visibleCharRange.location)

        var lineStart = 0
        text.getLineStart(&lineStart, end: nil, contentsEnd: nil, for: NSRange(location: visibleCharRange.location, length: 0))

        var lineNum = textView.lineNumber(at: lineStart)

        let visibleEnd = min(visibleCharRange.location + visibleCharRange.length, len)
        var charIdx = lineStart
        while charIdx < len {
            // Lines merged into a folded line above get no number; skip to after the fold.
            if let fold = textView.fold(hidingLineStart: charIdx) {
                let closerLine = text.lineRange(for: NSRange(location: NSMaxRange(fold), length: 0))
                lineNum += 1 + text.countNewlines(in: NSRange(location: charIdx, length: max(closerLine.location - charIdx, 0)))
                charIdx = NSMaxRange(closerLine)
                if charIdx > visibleEnd { break }
                continue
            }
            let lineRange = text.lineRange(for: NSRange(location: charIdx, length: 0))
            let glyphIdx  = layoutManager.glyphIndexForCharacter(at: charIdx)
            if glyphIdx < layoutManager.numberOfGlyphs {
                let fragRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: nil)
                if fragRect != .zero { drawNum(lineNum, fragRect.origin.y, lineHeight: fragRect.height) }
            }
            lineNum += 1
            charIdx = NSMaxRange(lineRange)
            if charIdx > visibleEnd { break }
        }

        if charIdx >= len && text.character(at: len - 1) == 10 {
            let extra = layoutManager.extraLineFragmentRect
            if extra != .zero { drawNum(lineNum, extra.origin.y, lineHeight: extra.height) }
        }
    }
    
    private func drawChevron(folded: Bool, centerX: CGFloat, centerY: CGFloat, color: NSColor) {
        let r = max(2.5, fontSize * 0.22)
        let path = NSBezierPath()
        if folded {   // ›
            path.move(to: NSPoint(x: centerX - r / 2, y: centerY - r))
            path.line(to: NSPoint(x: centerX + r / 2, y: centerY))
            path.line(to: NSPoint(x: centerX - r / 2, y: centerY + r))
        } else {      // ⌄ (flipped view: +y is down)
            path.move(to: NSPoint(x: centerX - r, y: centerY - r / 2))
            path.line(to: NSPoint(x: centerX, y: centerY + r / 2))
            path.line(to: NSPoint(x: centerX + r, y: centerY - r / 2))
        }
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }
}

nonisolated extension NSString {
    /// Counts line breaks in `range` using a fixed-size buffer (no per-call allocation proportional
    /// to the document, no substring/array churn).
    func countNewlines(in range: NSRange) -> Int {
        let chunk = 4096
        var count = 0
        var loc = range.location
        let end = NSMaxRange(range)
        // LF, CR and CRLF each end a line, as they do for NSTextView and lineRange(for:).
        var afterCR = false
        withUnsafeTemporaryAllocation(of: unichar.self, capacity: chunk) { buf in
            guard let base = buf.baseAddress else { return }
            while loc < end {
                let n = min(chunk, end - loc)
                getCharacters(base, range: NSRange(location: loc, length: n))
                for i in 0..<n {
                    let c = base[i]
                    if c == 13 || (c == 10 && !afterCR) { count += 1 }
                    afterCR = c == 13
                }
                loc += n
            }
        }
        return count
    }
    
    /// Non-overlapping occurrences of `needle` within `range`.
    func occurrences(of needle: String, in range: NSRange) -> Int {
        var count = 0
        var search = range
        while search.length > 0 {
            let found = self.range(of: needle, options: .literal, range: search)
            if found.location == NSNotFound { break }
            count += 1
            let next = NSMaxRange(found)
            search = NSRange(location: next, length: NSMaxRange(range) - next)
        }
        return count
    }
}

// MARK: - Editor View

struct EditorView: View {
    @ObservedObject var viewModel: EditorViewModel
    @ObservedObject private var settings = SettingsManager.shared
    var onSave: () -> Void
    var onSaveAndPaste: () -> Void = {}
    var onClose: () -> Void
    var onDiscard: () -> Void = {}
    var onNewScratch: () -> Void = {}
    var onTogglePresentation: () -> Void = {}
    var onTogglePresentationFullScreen: () -> Void = {}
    var onResizeWindow: (_ direction: CGFloat, _ held: Bool) -> Void = { _, _ in }
    var onShowHistory: () -> Void = {}
    var onShowSettings: () -> Void = {}
    @Environment(\.colorScheme) private var colorScheme
    @State private var keyMonitor: Any?
    @State private var textView: NSTextView?
    @State private var showFindBar = false
    // Restored from the last search so reopening Find doesn't start from scratch.
    @State private var findText = UserDefaults.standard.string(forKey: EditorView.lastFindTextKey) ?? ""
    @State private var replaceText = ""
    @State private var matchCount = 0
    @State private var isInvalidRegex = false
    @FocusState private var isFindFieldFocused: Bool
    @FocusState private var isReplaceFieldFocused: Bool
    @State private var showShortcuts = false
    @State private var hoverCancel = false
    @State private var hoverKeyboard = false
    @State private var hoverSave = false
    @State private var hoverWordWrap = false
    @State private var hoverTransform = false
    /// Where the Transform chip sits (SwiftUI global, top-left origin), to pop its menu above it.
    @State private var transformChipFrame: CGRect?
    @State private var hoverLanguage = false
    @State private var languageChipFrame: CGRect?
    
    // Find options (restored from the last search)
    @State private var useRegex = UserDefaults.standard.bool(forKey: EditorView.lastFindRegexKey)
    @State private var caseSensitive = UserDefaults.standard.bool(forKey: EditorView.lastFindCaseKey)
    @State private var wholeWord = UserDefaults.standard.bool(forKey: EditorView.lastFindWordKey)
    @State private var matchRanges: [NSRange] = []
    @State private var currentMatchIndex: Int?

    private static let lastFindTextKey = "MangleLastFindText"
    private static let lastFindRegexKey = "MangleLastFindRegex"
    private static let lastFindCaseKey = "MangleLastFindCase"
    private static let lastFindWordKey = "MangleLastFindWholeWord"
    
    // Command palette (⌘K) — also hosts Go to Line (⌃G opens it with ":")
    @State private var showPalette = false
    @State private var paletteQuery = ""
    @State private var paletteIndex = 0
    @State private var hoverPaste = false
    
    // Smart-select / expand selection (⌥⇧↑ expand, ⌥⇧↓ shrink)
    @State private var selectionHistory: [NSRange] = []
    @State private var lastExpandResult: NSRange? = nil


    @State private var needsAccessibility = !AXIsProcessTrusted()
    /// The "Presenting" hint, shown briefly on entering presentation mode.
    @State private var showPresentingHint = false
    
    static let languages: [(label: String, id: String)] = [
        ("Auto-detect", "auto"),
        ("Plain Text", "plaintext"),
        ("Bash", "bash"),
        ("C", "c"),
        ("C++", "cpp"),
        ("CSS", "css"),
        ("Diff", "diff"),
        ("GraphQL", "graphql"),
        ("Go", "go"),
        ("HTML", "xml"),
        ("Java", "java"),
        ("JavaScript", "javascript"),
        ("JSON", "json"),
        ("Kotlin", "kotlin"),
        ("LESS", "less"),
        ("Markdown", "markdown"),
        ("Perl", "perl"),
        ("PHP", "php"),
        ("Python", "python"),
        ("Ruby", "ruby"),
        ("Rust", "rust"),
        ("SCSS", "scss"),
        ("SQL", "sql"),
        ("Swift", "swift"),
        ("TypeScript", "typescript"),
        ("YAML", "yaml"),
    ]
    
    /// The bars' colour, from the theme in use (see `AppTheme.editorChrome`).
    private var chromeColor: NSColor {
        let theme = settings.themeName(isDark: colorScheme == .dark, presenting: viewModel.isPresenting)
        guard let background = ThemeCatalog.background(theme) else { return AppTheme.windowBG }
        return AppTheme.editorChrome(themeBackground: background)
    }

    var body: some View {
        let chrome = chromeColor
        return VStack(spacing: 0) {
            if needsAccessibility && !viewModel.isPresenting && !viewModel.isScratch {
                accessibilityBanner
            }
            if showFindBar {
                findBar
                    .background(Color(nsColor: chrome))
                Divider()
            }
            
            CustomTextEditor(
                text: viewModel.loadedText,
                selection: viewModel.loadedSelection,
                loadGeneration: viewModel.loadGeneration,
                language: viewModel.currentLanguage,
                fontSize: viewModel.isPresenting ? settings.presentationFontSize : settings.fontSize,
                editorFont: settings.editorFont,
                wordWrap: settings.wordWrap,
                isDark: colorScheme == .dark,
                themeName: settings.themeName(isDark: colorScheme == .dark, presenting: viewModel.isPresenting),
                status: viewModel.status,
                isPresenting: viewModel.isPresenting,
                showsLineNumbers: !viewModel.isPresenting || settings.presentationLineNumbers,
                onTextViewReady: { tv in
                    textView = tv
                    viewModel.textView = tv
                },
                onLoadApplied: { viewModel.appliedGeneration = $0 },
                onTextChange: {
                    // Keep find highlights/count in sync with edits (debounced by the editor).
                    if showFindBar { highlightMatches() }
                },
                onPasteReplacedDocument: redetectLanguageAfterPaste
            )
            
            if !viewModel.isPresenting {
                Divider()
                bottomBar
                    .background(Color(nsColor: chrome))
            }
        }
        // The title bar shows the window's background, so it matches the bars too.
        .background(WindowBackground(color: chrome))
        .overlay(alignment: .bottomTrailing) {
            if showPresentingHint {
                Text("Presenting · Select lines to spotlight, ← → to step · Esc to exit")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .padding(14)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: viewModel.isPresenting) {
            withAnimation(.easeOut(duration: 0.2)) { showPresentingHint = viewModel.isPresenting }
            guard viewModel.isPresenting else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                withAnimation(.easeOut(duration: 0.4)) { showPresentingHint = false }
            }
        }
        .frame(minWidth: 400, minHeight: 320)
        .background {
            Group {
                Button("") {
                    showFindBar.toggle()
                    if showFindBar {
                        isFindFieldFocused = true
                        highlightMatches()
                    }
                }
                .keyboardShortcut("f", modifiers: .command)
                Button("") { onSaveAndPaste() }
                    .keyboardShortcut(.return, modifiers: .command)
                // The Transform menu is an AppKit pop-up shown on demand, so its items'
                // shortcuts (⇧⌘F, ⇧⌘T, ⇧⌘L…) are bound here instead.
                ForEach(transformSections.flatMap(\.commands).filter { $0.keyboardShortcut != nil }) { cmd in
                    Button("", action: cmd.run)
                        .keyboardShortcut(cmd.keyboardShortcut)
                        .disabled(!cmd.isEnabled)
                }
                // The bottom bar (and its ⌘S button) is hidden while presenting.
                if viewModel.isPresenting {
                    Button("") { onSave() }
                        .keyboardShortcut("s", modifiers: .command)
                }
            }
            .hidden()
        }
        .overlay(alignment: .top) {
            if showPalette {
                ZStack(alignment: .top) {
                    // Clicking anywhere outside the palette dismisses it.
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { closePalette() }
                    CommandPaletteView(
                        query: $paletteQuery,
                        results: paletteResults,
                        selectedIndex: paletteIndex,
                        onSelect: { paletteIndex = $0 },
                        onRun: runPaletteCommand
                    )
                    .padding(.top, 36)
                }
            }
        }
        .onChange(of: paletteQuery) { paletteIndex = 0 }
        // The palette is a quick, in-the-moment action: switching away (or hiding the editor)
        // dismisses it, so coming back lands in the document rather than a stale search.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            if showPalette, let window = textView?.window, note.object as? NSWindow === window {
                closePalette()
            }
        }
        .onAppear {
            viewModel.requestClose = cancelEditor
            if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
                // Local monitors see keys for every window in the app. The editor window is
                // only hidden (never closed), so without this check its shortcuts fired in
                // History/Settings and edited the hidden document.
                guard let editorWindow = textView?.window, event.window === editorWindow else { return event }
                // Wakes the caret for every key, including shortcuts handled here (⌘Z, ⌘/…)
                // that never reach the text view's keyDown.
                if editorWindow.firstResponder === textView { (textView as? MangleTextView)?.noteInteraction() }
                let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
                
                // If focus went somewhere else (the document after a click, or the find bar),
                // the palette is done — keys must reach that field, not run palette commands.
                if showPalette, textView?.window?.firstResponder === textView || isFindFieldFocused || isReplaceFieldFocused {
                    closePalette()
                    return event
                }
                // The palette keeps focus in its search field; drive its list from here.
                if showPalette {
                    let key = event.charactersIgnoringModifiers?.lowercased()
                    // The shortcuts that open the palette close it again.
                    if (mods == .command && key == "k") || (mods == [.command, .shift] && key == "p") {
                        closePalette()
                        return nil
                    }
                    if mods == .control, key == "g" { paletteQuery = ":"; return nil }
                    let results = paletteResults
                    func move(by step: Int, wrapping: Bool) {
                        guard !results.isEmpty else { return }
                        let target = paletteIndex + step
                        if wrapping {
                            paletteIndex = (target % results.count + results.count) % results.count
                        } else {
                            paletteIndex = min(max(target, 0), results.count - 1)
                        }
                    }
                    if mods == .control, key == "n" { move(by: 1, wrapping: true); return nil }
                    if mods == .control, key == "p" { move(by: -1, wrapping: true); return nil }
                    switch event.keyCode {
                    case 53: // Escape
                        closePalette()
                        return nil
                    case 125: // Down
                        move(by: 1, wrapping: true)
                        return nil
                    case 126: // Up
                        move(by: -1, wrapping: true)
                        return nil
                    case 121: // Page Down
                        move(by: 8, wrapping: false)
                        return nil
                    case 116: // Page Up
                        move(by: -8, wrapping: false)
                        return nil
                    case 36, 76: // Return / Enter
                        if results.indices.contains(paletteIndex) { runPaletteCommand(results[paletteIndex].command) }
                        return nil
                    default:
                        // Editing keys reach the search field (including ⌘←/⌘→/⌘⌫) and app-level
                        // keys (quit, hide…) still work; editor shortcuts (⌘F, ⌘S, ⌘T…) would
                        // otherwise fire behind the palette and act on the document.
                        let fieldEditingKeys: Set<UInt16> = [51, 117, 123, 124] // ⌫, ⌦, ←, →
                        if mods.contains(.command), !fieldEditingKeys.contains(event.keyCode),
                           let key, !"acvxzqhm,".contains(key) { return nil }
                        return event
                    }
                }
                
                // Escape collapses multiple selections before anything else.
                if event.keyCode == 53, let mtv = textView as? MangleTextView, mtv.hasMultipleSelections {
                    mtv.collapseMultipleSelections()
                    return nil
                }

                // Escape dismisses Find first (matching Xcode/VS Code/Safari) — only a
                // second Escape, with Find already closed, should close the editor.
                if event.keyCode == 53, showFindBar { // Escape
                    closeFindBar()
                    return nil
                }
                // Then it drops a spotlight, then leaves presentation mode, like leaving full screen.
                if event.keyCode == 53, let mtv = textView as? MangleTextView, mtv.spotlightRange != nil {
                    mtv.clearSpotlight()
                    return nil
                }
                if event.keyCode == 53, viewModel.isPresenting {
                    onTogglePresentation()
                    return nil
                }

                // These shortcuts mutate the main document; while Find/Replace has focus,
                // let the key fall through to the field instead (e.g. don't duplicate a
                // line behind the search bar because the user held ⌘ while searching).
                let editingFieldFocused = isFindFieldFocused || isReplaceFieldFocused

                let key = event.charactersIgnoringModifiers?.lowercased()
                let mtv = textView as? MangleTextView
                
                // Find navigation works from the find field too.
                if mods == .command, key == "g" { findNext(); return nil }
                if mods == [.command, .shift], key == "g" { findPrevious(); return nil }
                if mods == .command, key == "k" { openPalette(); return nil }
                if mods == [.command, .shift], key == "p" { openPalette(); return nil }
                if mods == .control, key == "g" { openPalette(query: ":"); return nil }
                if mods == .command, key == "n" { onNewScratch(); return nil }
                if mods == .command, key == "w" { cancelEditor(); return nil }
                if mods == [.command, .option], key == "w" { discardDocument(); return nil }
                if mods == .command, key == "t" { showTransformMenu(); return nil }
                if mods == [.command, .option], key == "p" { onTogglePresentation(); return nil }
                if mods == [.command, .control], key == "f", viewModel.isPresenting { onTogglePresentationFullScreen(); return nil }
                // ⌥⌘= / ⌥⌘− resize the window, by key code since ⌥ changes the typed character.
                if mods == [.command, .option], event.keyCode == 24 || event.keyCode == 27 {
                    onResizeWindow(event.keyCode == 24 ? 1 : -1, event.isARepeat)
                    return nil
                }
                
                if !editingFieldFocused {
                    if mods == .command, key == "e" { useSelectionForFind(); return nil }
                    if mods == .command, key == "/" { toggleComment(); return nil }
                    if mods == .command, key == "]" { indentLines(outdent: false); return nil }
                    if mods == .command, key == "[" { indentLines(outdent: true); return nil }
                    if mods == [.command, .shift], key == "d" { if let tv = textView { duplicateLine(in: tv) }; return nil }
                    if mods == [.control, .command], key == "g" { mtv?.selectAllOccurrences(); return nil }
                    if mods == .option, event.keyCode == 6 { settings.wordWrap.toggle(); return nil } // ⌥Z
                    if mods == [.command, .option, .shift], key == "c" { copyJSONPath(); return nil }
                    // Folding: ⌥⌘← / ⌥⌘→ at the caret, with ⇧ for everything.
                    if event.keyCode == 123 || event.keyCode == 124 {
                        let fold = event.keyCode == 123
                        if mods == [.command, .option] { fold ? mtv?.foldAtCaret() : mtv?.unfoldAtCaret(); return nil }
                        if mods == [.command, .option, .shift] { fold ? mtv?.foldAll() : mtv?.unfoldAll(); return nil }
                    }
                }

                if mods == .command {
                    switch event.charactersIgnoringModifiers {
                    case "=", "+":
                        zoom(by: 1, held: event.isARepeat)
                        return nil
                    case "-":
                        zoom(by: -1, held: event.isARepeat)
                        return nil
                    case "0":
                        resetZoom()
                        return nil
                    case "d":
                        guard !editingFieldFocused else { break }
                        mtv?.selectNextOccurrence()
                        return nil
                    case "l":
                        guard !editingFieldFocused else { break }
                        if let tv = textView { selectLine(in: tv) }
                        return nil
                    default: break
                    }
                }

                if mods == [.command, .shift],
                   event.charactersIgnoringModifiers?.lowercased() == "k",
                   !editingFieldFocused {
                    if let tv = textView { deleteLine(in: tv) }
                    return nil
                }

                if mods == [.option, .shift], !editingFieldFocused {
                    if event.keyCode == 126 { // Up — expand selection
                        if let tv = textView { expandSelection(in: tv) }
                        return nil
                    }
                    if event.keyCode == 125 { // Down — shrink selection
                        if let tv = textView { shrinkSelection(in: tv) }
                        return nil
                    }
                }

                let optionOnly = mods.contains(.option)
                && !mods.contains(.command)
                && !mods.contains(.shift)
                && !mods.contains(.control)
                if optionOnly, !editingFieldFocused {
                    if event.keyCode == 126 {
                        if let tv = textView { moveLine(in: tv, up: true) }
                        return nil
                    }
                    if event.keyCode == 125 {
                        if let tv = textView { moveLine(in: tv, up: false) }
                        return nil
                    }
                }

                return event
            }
        }
        .onDisappear {
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
        }
    }
    
    // MARK: - Accessibility Banner
    
    private var accessibilityBanner: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.yellow)
                Text("Accessibility access needed to read selected text.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Button("Enable in Settings") {
                    if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "editor" }) {
                        window.level = .normal
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            if !AXIsProcessTrusted() { window.level = .floating }
                        }
                    }
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                .font(.system(size: 11))
                Button {
                    needsAccessibility = !AXIsProcessTrusted()
                } label: {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 14))
                }
                .help("I've enabled it")
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.yellow.opacity(0.08))
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
                if AXIsProcessTrusted() { needsAccessibility = false }
            }
            Divider()
        }
    }
    
    // MARK: - Find Bar
    
    private var findBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(AppTheme.tealSUI)
                    .frame(width: 16)
                TextField("Find", text: $findText)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFindFieldFocused)
                    .onChange(of: findText) {
                        highlightMatches()
                        UserDefaults.standard.set(findText, forKey: Self.lastFindTextKey)
                    }
                    .onSubmit { findNext() }
                findToggle("Aa", isOn: caseSensitive, help: "Match Case", action: toggleMatchCase)
                findToggle("ab", isOn: wholeWord, help: "Whole Word", underline: true, action: toggleWholeWord)
                findToggle(".*", isOn: useRegex, help: "Use Regular Expression", action: toggleRegex)
                
                if isInvalidRegex {
                    findBadge("Invalid", color: Color.red.opacity(0.7))
                } else if matchCount > 0 {
                    findBadge(currentMatchIndex.map { "\($0 + 1) of \(matchCount)" } ?? "\(matchCount)", color: AppTheme.tealSUI)
                } else if !findText.isEmpty {
                    findBadge("0", color: Color.secondary.opacity(0.5))
                }
                Button(action: findPrevious) { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless)
                    .help("Previous Match (⇧⌘G)")
                Button(action: findNext) { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless)
                    .help("Next Match (⌘G)")
                Button(action: closeFindBar) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 8) {
                Image(systemName: "arrow.2.squarepath")
                    .foregroundColor(.secondary)
                    .frame(width: 16)
                TextField("Replace", text: $replaceText)
                    .textFieldStyle(.roundedBorder)
                    .focused($isReplaceFieldFocused)
                    .onSubmit { replaceCurrent() }
                Button("Replace") { replaceCurrent() }
                    .tint(AppTheme.tealSUI)
                Button("All") { replaceAll() }
                    .tint(AppTheme.tealSUI)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
    
    private func findToggle(_ label: String, isOn: Bool, help: String, underline: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            action()
            highlightMatches()
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .underline(underline)
                .foregroundColor(isOn ? AppTheme.onTealSUI : .secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(isOn ? AppTheme.tealSUI : Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.borderless)
        .help(help)
    }
    
    private func findBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.monospacedDigit())
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color, in: Capsule())
            .fixedSize()
    }
    
    // MARK: - Language Picker
    
    private var currentLanguageLabel: String { Self.languageLabel(viewModel.currentLanguage) }

    static func languageLabel(_ id: String) -> String {
        languages.first { $0.id == id }?.label ?? id
    }
    
    /// The dot beside the language in the bottom bar — roughly each language's usual brand colour,
    /// lightened where needed to read on a dark bar.
    static func languageColor(_ id: String) -> Color {
        guard let hex = languageHex(id) else { return .secondary }
        return Color(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    private static func languageHex(_ id: String) -> Int? {
        let hex: Int
        switch id {
        case "json":                  hex = 0xE8B04A
        case "javascript":            hex = 0xF1E05A
        case "typescript":            hex = 0x3178C6
        case "swift":                 hex = 0xF05138
        case "python":                hex = 0x4B8BBE
        case "rust":                  hex = 0xDEA584
        case "go":                    hex = 0x00ADD8
        case "xml":                   hex = 0xE34C26
        case "css", "scss", "less":   hex = 0x8E6FD8
        case "markdown":              hex = 0x6A9FD8
        case "ruby":                  hex = 0xCC342D
        case "java", "kotlin":        hex = 0xB07219
        case "php":                   hex = 0x7A86B8
        case "sql":                   hex = 0xE38C00
        case "bash":                  hex = 0x89E051
        case "c", "cpp":              hex = 0x659AD2
        case "graphql":               hex = 0xE10098
        case "diff":                  hex = 0x88C057
        case "yaml":                  hex = 0xE0565B
        case "perl":                  hex = 0x6E7FC0
        default:                      return nil
        }
        return hex
    }

    /// The bottom bar's language dot as a menu item image; languages without a colour get a hollow ring.
    private static func languageDotImage(_ id: String) -> NSImage {
        let color = languageHex(id).map {
            NSColor(srgbRed: CGFloat($0 >> 16 & 0xFF) / 255, green: CGFloat($0 >> 8 & 0xFF) / 255, blue: CGFloat($0 & 0xFF) / 255, alpha: 1)
        }
        return NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let dot = NSBezierPath(ovalIn: rect.insetBy(dx: 2.5, dy: 2.5))
            if let color {
                color.setFill()
                dot.fill()
            } else {
                NSColor.secondaryLabelColor.setStroke()
                dot.lineWidth = 1
                dot.stroke()
            }
            return true
        }
    }

    // MARK: - Bottom Bar
    
    private var bottomBar: some View {
        // Cursor position and stats live in their own small views observing `EditorStatus`,
        // so typing and caret moves re-render just those labels — not this whole bar
        // (and its Transform menu) or the editor view around it.
        // Each step drops the least useful items until the bar fits; shortcuts stay in tooltips.
        ViewThatFits(in: .horizontal) {
            bottomBarHStack(showStats: true,  showKeyboard: true,  showBadges: true,  showCursor: true)
            bottomBarHStack(showStats: false, showKeyboard: true,  showBadges: true,  showCursor: true)
            bottomBarHStack(showStats: false, showKeyboard: false, showBadges: true,  showCursor: true)
            bottomBarHStack(showStats: false, showKeyboard: false, showBadges: false, showCursor: true)
            bottomBarHStack(showStats: false, showKeyboard: false, showBadges: false, showCursor: false)
        }
        .frame(height: 36)
    }

    @ViewBuilder
    private func bottomBarHStack(showStats: Bool, showKeyboard: Bool, showBadges: Bool, showCursor: Bool) -> some View {
        HStack(spacing: 0) {
            // Left: read-only status, then the document menus.
            if showCursor {
                HStack(spacing: 10) {
                    CursorPositionLabel(status: viewModel.status)
                    if showStats {
                        TextStatsLabel(status: viewModel.status)
                    }
                }
                .padding(.horizontal, 12)

                BarDivider()
            }

            HStack(spacing: 6) {
                if showKeyboard {
                    DocumentFormatMenu(
                        status: viewModel.status,
                        onIndentation: setIndentation,
                        onConvertIndentation: convertIndentation,
                        onLineEnding: convertLineEndings
                    )
                }

                // Plain text that nobody chose isn't worth the space; any real language is.
                if viewModel.currentLanguage != "plaintext" || viewModel.languageIsManual {
                    Button(action: showLanguageMenu) {
                        BarChipLabel(title: currentLanguageLabel, dot: Self.languageColor(viewModel.currentLanguage), hovered: hoverLanguage)
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .onHover { hoverLanguage = $0 }
                    .background(GeometryReader { geo in
                        Color.clear
                            .onAppear { languageChipFrame = geo.frame(in: .global) }
                            .onChange(of: geo.frame(in: .global)) { _, frame in languageChipFrame = frame }
                    })
                    .help(viewModel.languageIsManual ? "Language" : "Language (detected)")
                }

                // An AppKit menu rather than a SwiftUI Menu: SwiftUI can't open a Menu from code,
                // and ⌘T has to.
                Button(action: showTransformMenu) {
                    BarChipLabel(title: "Transform", systemImage: "wand.and.stars", tint: AppTheme.tealSUI, hovered: hoverTransform)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .onHover { hoverTransform = $0 }
                .background(GeometryReader { geo in
                    Color.clear
                        .onAppear { transformChipFrame = geo.frame(in: .global) }
                        .onChange(of: geo.frame(in: .global)) { _, frame in transformChipFrame = frame }
                })
                .help("Transform text (⌘T)")
            }
            .padding(.horizontal, 6)

            Spacer(minLength: 0)

            // Right: view toggles, then the close actions.
            HStack(spacing: 2) {
                Button {
                    settings.wordWrap.toggle()
                } label: {
                    barIcon("arrow.down.and.line.horizontal.and.arrow.up", active: settings.wordWrap, hovered: hoverWordWrap)
                }
                .buttonStyle(.plain)
                .onHover { hoverWordWrap = $0 }
                .help(settings.wordWrap ? "Word Wrap: On" : "Word Wrap: Off")

                if showKeyboard {
                    Button {
                        showShortcuts.toggle()
                    } label: {
                        barIcon("keyboard", active: showShortcuts, hovered: hoverKeyboard)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showShortcuts, arrowEdge: .top) {
                        ShortcutsPopover()
                    }
                    .onHover { hoverKeyboard = $0 }
                    .help("Keyboard shortcuts")
                }
            }
            .padding(.horizontal, 8)

            BarDivider()

            HStack(spacing: 4) {
                // Hiding never loses anything: the hotkey brings the text back, and it goes to
                // history if something replaces it.
                Button(action: cancelEditor) {
                    BarActionLabel(title: "Hide", shortcut: showBadges ? "Esc" : nil, hovered: hoverCancel)
                }
                .help(viewModel.isScratch
                      ? "Hide the scratch pad — it comes back where you left it (Esc)"
                      : "Hide — the hotkey brings this back, and it's kept in history if replaced (Esc)")
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
                .onHover { hoverCancel = $0 }

                Button {
                    onSaveAndPaste()
                } label: {
                    BarActionLabel(title: "Paste", shortcut: showBadges ? "⌘↩" : nil, hovered: hoverPaste)
                }
                .buttonStyle(.plain)
                .onHover { hoverPaste = $0 }
                .help("Copy, close, and paste into the app you came from (⌘↩)")

                // Save is the primary action, so it gets the accent fill.
                Button {
                    onSave()
                } label: {
                    BarPrimaryActionLabel(title: "Save", shortcut: showBadges ? "⌘S" : nil, hovered: hoverSave)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("s", modifiers: .command)
                .onHover { hoverSave = $0 }
                .help("Copy to clipboard and close (⌘S)")
            }
            .padding(.leading, 8)
            .padding(.trailing, 10)
        }
    }

    private func barIcon(_ systemName: String, active: Bool, hovered: Bool) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 11))
            .foregroundColor(active ? AppTheme.tealSUI : .secondary)
            .frame(width: 24, height: 20)
            .background(hovered ? Color.secondary.opacity(0.12) : Color.clear)
            .cornerRadius(5)
    }
    
    // MARK: - Find Logic
    
    /// One regex drives every find mode: literal text is escaped, whole-word wraps it in
    /// word-boundary lookarounds, and case sensitivity is a regex option.
    private func buildSearchRegex() -> NSRegularExpression? {
        guard !findText.isEmpty else { return nil }
        var pattern = useRegex ? findText : NSRegularExpression.escapedPattern(for: findText)
        if wholeWord { pattern = "(?<![\\p{L}\\p{N}_])(?:" + pattern + ")(?![\\p{L}\\p{N}_])" }
        return try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive])
    }
    
    private var replacementTemplate: String {
        useRegex ? replaceText : NSRegularExpression.escapedTemplate(for: replaceText)
    }

    /// Highlights every match. Uses layout-manager temporary attributes (via MangleTextView)
    /// rather than text-storage attributes: they don't invalidate layout and aren't wiped
    /// when the syntax highlighter re-colors an edited line.
    private func highlightMatches() {
        guard let tv = textView as? MangleTextView else { return }
        let regex = buildSearchRegex()
        isInvalidRegex = !findText.isEmpty && regex == nil
        guard let regex else {
            matchCount = 0
            matchRanges = []
            currentMatchIndex = nil
            tv.findRanges = []
            tv.currentFindRange = nil
            return
        }
        let string = tv.string
        let ranges = regex.matches(in: string, range: NSRange(location: 0, length: (string as NSString).length))
            .map(\.range)
            .filter { $0.length > 0 }
        matchRanges = ranges
        matchCount = ranges.count
        // Cap what we paint: a pattern like "." would otherwise add an attribute per character.
        tv.findRanges = Array(ranges.prefix(10_000))
        updateCurrentMatch(for: tv.selectedRange())
    }
    
    private func updateCurrentMatch(for selection: NSRange) {
        // matchRanges is sorted by location — binary search for the selection.
        var lo = 0, hi = matchRanges.count - 1
        var found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            let r = matchRanges[mid]
            if r.location == selection.location { found = r == selection ? mid : nil; break }
            if r.location < selection.location { lo = mid + 1 } else { hi = mid - 1 }
        }
        currentMatchIndex = found
        (textView as? MangleTextView)?.currentFindRange = found.map { matchRanges[$0] }
    }
    
    private func selectMatch(_ range: NSRange, in tv: NSTextView, wrappedMessage: String?) {
        (tv as? MangleTextView)?.collapseMultipleSelections()
        tv.setSelectedRange(range)
        tv.scrollRangeToVisible(range)
        tv.showFindIndicator(for: range)
        if let wrappedMessage { AppDelegate.shared?.showToast(wrappedMessage) }
        // With the bar closed (⌘G), just move the selection — painting highlights there would
        // leave them on screen with no bar to dismiss them.
        guard showFindBar else { return }
        if matchRanges.isEmpty { highlightMatches() } else { updateCurrentMatch(for: range) }
    }
    
    private func findNext() {
        guard let tv = textView else { return }
        guard let regex = buildSearchRegex() else {
            if !showFindBar { showFindBar = true; isFindFieldFocused = true }
            return
        }
        let string = tv.string
        let length = (string as NSString).length
        let start = NSMaxRange(tv.selectedRange())
        func firstMatch(from: Int, to: Int) -> NSRange? {
            var result: NSRange?
            regex.enumerateMatches(in: string, options: [.withoutAnchoringBounds, .withTransparentBounds], range: NSRange(location: from, length: to - from)) { m, _, stop in
                if let r = m?.range, r.length > 0 { result = r; stop.pointee = true }
            }
            return result
        }
        if let r = firstMatch(from: min(start, length), to: length) {
            selectMatch(r, in: tv, wrappedMessage: nil)
        } else if let r = firstMatch(from: 0, to: length) {
            selectMatch(r, in: tv, wrappedMessage: "Search wrapped to top")
        }
    }

    private func findPrevious() {
        guard let tv = textView else { return }
        guard let regex = buildSearchRegex() else {
            if !showFindBar { showFindBar = true; isFindFieldFocused = true }
            return
        }
        let string = tv.string
        let all = regex.matches(in: string, range: NSRange(location: 0, length: (string as NSString).length))
            .map(\.range).filter { $0.length > 0 }
        let current = tv.selectedRange().location
        if let r = all.last(where: { $0.location < current }) {
            selectMatch(r, in: tv, wrappedMessage: nil)
        } else if let r = all.last {
            selectMatch(r, in: tv, wrappedMessage: "Search wrapped to bottom")
        }
    }
    
    private func replaceCurrent() {
        guard let tv = textView, let regex = buildSearchRegex() else { return }
        let string = tv.string
        let selectedRange = tv.selectedRange()
        // Replace via shouldChangeText/replaceCharacters rather than insertText: MangleTextView's
        // insertText applies auto-close, so a one-character replacement like "(" or a quote
        // used to wrap the match ("(foo)") instead of replacing it.
        if selectedRange.length > 0,
           let match = regex.firstMatch(in: string, options: [.withoutAnchoringBounds, .withTransparentBounds], range: selectedRange),
           match.range == selectedRange {
            let replacement = regex.replacementString(for: match, in: string, offset: 0, template: replacementTemplate)
            if tv.shouldChangeText(in: selectedRange, replacementString: replacement) {
                tv.replaceCharacters(in: selectedRange, with: replacement)
                tv.didChangeText()
                tv.undoManager?.setActionName("Replace")
                let end = selectedRange.location + (replacement as NSString).length
                tv.setSelectedRange(NSRange(location: end, length: 0))
                highlightMatches()
            }
        }
        findNext()
    }
    
    private func replaceAll() {
        guard let regex = buildSearchRegex(), let tv = textView else { return }
        // Counted here, not from matchCount: from the palette, Find (and its count) may be closed.
        let count = regex.numberOfMatches(in: tv.string, range: NSRange(location: 0, length: (tv.string as NSString).length))
        let template = replacementTemplate
        transform("Replace All", scope: .document) { text in
            regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
        }
        // From the palette, Find may be closed; highlighting then would leave marks nothing clears.
        if showFindBar { highlightMatches() }
        if count > 0 { AppDelegate.shared?.showToast("Replaced \(count) match\(count == 1 ? "" : "es")") }
    }
    
    /// ⌘E: search for the selection (or the word at the caret).
    private func useSelectionForFind() {
        guard let tv = textView else { return }
        let ns = tv.string as NSString
        var sel = tv.selectedRange()
        if sel.length == 0, let mtv = tv as? MangleTextView { sel = mtv.wordRange(at: sel.location) }
        guard sel.length > 0 else { return }
        let text = ns.substring(with: sel)
        findText = useRegex ? NSRegularExpression.escapedPattern(for: text) : text
        UserDefaults.standard.set(findText, forKey: Self.lastFindTextKey)
        highlightMatches()
    }
    
    // MARK: - Smart Select (⌥⇧↑ expand, ⌥⇧↓ shrink)

    private func nearestUnmatchedOpener(before pos: Int, in text: NSString) -> (index: Int, char: Character)? {
        var depth: [Character: Int] = ["(": 0, "[": 0, "{": 0]
        let openerFor: [Character: Character] = [")": "(", "]": "[", "}": "{"]
        var i = pos - 1
        while i >= 0 {
            if let scalar = Unicode.Scalar(text.character(at: i)) {
                let ch = Character(scalar)
                if let opener = openerFor[ch] {
                    depth[opener, default: 0] += 1
                } else if depth[ch] != nil {
                    if depth[ch]! == 0 { return (i, ch) }
                    depth[ch]! -= 1
                }
            }
            i -= 1
        }
        return nil
    }

    private func nearestUnmatchedCloser(after pos: Int, matching opener: Character, in text: NSString) -> Int? {
        let closerFor: [Character: Character] = ["(": ")", "[": "]", "{": "}"]
        guard let closer = closerFor[opener] else { return nil }
        var depth = 0
        var i = pos
        let len = text.length
        while i < len {
            if let scalar = Unicode.Scalar(text.character(at: i)) {
                let ch = Character(scalar)
                if ch == opener { depth += 1 }
                else if ch == closer {
                    if depth == 0 { return i }
                    depth -= 1
                }
            }
            i += 1
        }
        return nil
    }

    /// Innermost bracket pair strictly enclosing `range`, searching outward from its edges.
    private func enclosingBracketRange(for range: NSRange, in text: NSString, includeBrackets: Bool) -> NSRange? {
        guard let (openIdx, openCh) = nearestUnmatchedOpener(before: range.location, in: text) else { return nil }
        guard let closeIdx = nearestUnmatchedCloser(after: NSMaxRange(range), matching: openCh, in: text) else { return nil }
        return includeBrackets
            ? NSRange(location: openIdx, length: closeIdx - openIdx + 1)
            : NSRange(location: openIdx + 1, length: closeIdx - openIdx - 1)
    }

    private func expandSelection(in tv: NSTextView) {
        let sel = tv.selectedRange()
        let text = tv.string as NSString
        var candidate: NSRange? = nil

        if sel.length == 0, let mtv = tv as? MangleTextView {
            let word = mtv.currentWordRange(at: sel.location)
            if word.length > 0 { candidate = word }
        }

        if candidate == nil {
            if let inner = enclosingBracketRange(for: sel, in: text, includeBrackets: false), inner != sel {
                candidate = inner
            } else if let withBrackets = enclosingBracketRange(for: sel, in: text, includeBrackets: true), withBrackets != sel {
                candidate = withBrackets
            }
        }

        if candidate == nil {
            var ls = 0, ce = 0
            text.getLineStart(&ls, end: nil, contentsEnd: &ce, for: sel)
            let lineRange = NSRange(location: ls, length: ce - ls)
            if lineRange != sel, lineRange.location <= sel.location, NSMaxRange(lineRange) >= NSMaxRange(sel) {
                candidate = lineRange
            }
        }

        if candidate == nil {
            let full = NSRange(location: 0, length: text.length)
            if full != sel { candidate = full }
        }

        guard let result = candidate else { return }
        // A manual selection change since the last expand starts a fresh chain.
        if sel != lastExpandResult { selectionHistory.removeAll() }
        selectionHistory.append(sel)
        lastExpandResult = result
        tv.setSelectedRange(result)
        tv.scrollRangeToVisible(result)
    }

    private func shrinkSelection(in tv: NSTextView) {
        guard var previous = selectionHistory.popLast() else { return }
        let len = (tv.string as NSString).length
        previous.location = min(previous.location, len)
        previous.length = min(previous.length, len - previous.location)
        lastExpandResult = previous
        tv.setSelectedRange(previous)
        tv.scrollRangeToVisible(previous)
    }

    // MARK: - Line Operations

    private func lineExtents(in tv: NSTextView) -> (lineStart: Int, lineEnd: Int, contentsEnd: Int, colOffset: Int) {
        let text = tv.string as NSString
        let sel = tv.selectedRange()
        var ls = 0, le = 0, ce = 0
        text.getLineStart(&ls, end: &le, contentsEnd: &ce, for: sel)
        return (ls, le, ce, sel.location - ls)
    }
    
    private func duplicateLine(in tv: NSTextView) {
        let text = tv.string as NSString
        let (ls, le, ce, col) = lineExtents(in: tv)
        let lineText = text.substring(with: NSRange(location: ls, length: ce - ls))
        // Reuse the line's own ending (CRLF stays CRLF). The last line may have none, so the
        // break goes before the copy instead of after it.
        let ending = text.substring(with: NSRange(location: ce, length: le - ce))
        let insertion = ending.isEmpty ? "\n" + lineText : lineText + ending
        let insertRange = NSRange(location: le, length: 0)
        if tv.shouldChangeText(in: insertRange, replacementString: insertion) {
            tv.replaceCharacters(in: insertRange, with: insertion)
            tv.didChangeText()
            let copyStart = ending.isEmpty ? le + 1 : le
            let newPos = min(copyStart + col, (tv.string as NSString).length)
            tv.setSelectedRange(NSRange(location: newPos, length: 0))
        }
    }
    
    private func deleteLine(in tv: NSTextView) {
        let (ls, le, _, _) = lineExtents(in: tv)
        let deleteRange = NSRange(location: ls, length: le - ls)
        if tv.shouldChangeText(in: deleteRange, replacementString: "") {
            tv.replaceCharacters(in: deleteRange, with: "")
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: min(ls, (tv.string as NSString).length), length: 0))
        }
    }
    
    private func selectLine(in tv: NSTextView) {
        let (ls, _, ce, _) = lineExtents(in: tv)
        tv.setSelectedRange(NSRange(location: ls, length: ce - ls))
    }
    
    private func moveLine(in tv: NSTextView, up: Bool) {
        let text = tv.string as NSString
        let (ls, le, ce, col) = lineExtents(in: tv)
        let currentLine = text.substring(with: NSRange(location: ls, length: ce - ls))
        let currentHasNewline = le > ce
        
        if up {
            guard ls > 0 else { return }
            var pls = 0, ple = 0, pce = 0
            text.getLineStart(&pls, end: &ple, contentsEnd: &pce, for: NSRange(location: ls - 1, length: 0))
            let prevLine = text.substring(with: NSRange(location: pls, length: pce - pls))
            let replacement = currentLine + "\n" + prevLine + (currentHasNewline ? "\n" : "")
            let swapRange = NSRange(location: pls, length: le - pls)
            if tv.shouldChangeText(in: swapRange, replacementString: replacement) {
                tv.replaceCharacters(in: swapRange, with: replacement)
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: min(pls + col, (tv.string as NSString).length), length: 0))
            }
        } else {
            guard le < text.length else { return }
            var nls = 0, nle = 0, nce = 0
            text.getLineStart(&nls, end: &nle, contentsEnd: &nce, for: NSRange(location: le, length: 0))
            let nextLine = text.substring(with: NSRange(location: nls, length: nce - nls))
            let nextHasNewline = nle > nce
            let replacement = nextLine + "\n" + currentLine + (nextHasNewline ? "\n" : "")
            let swapRange = NSRange(location: ls, length: nle - ls)
            if tv.shouldChangeText(in: swapRange, replacementString: replacement) {
                tv.replaceCharacters(in: swapRange, with: replacement)
                tv.didChangeText()
                let newLineStart = ls + (nextLine as NSString).length + 1
                tv.setSelectedRange(NSRange(location: min(newLineStart + col, (tv.string as NSString).length), length: 0))
            }
        }
    }
    
    private func toggleMatchCase() {
        caseSensitive.toggle()
        UserDefaults.standard.set(caseSensitive, forKey: Self.lastFindCaseKey)
    }

    private func toggleWholeWord() {
        wholeWord.toggle()
        UserDefaults.standard.set(wholeWord, forKey: Self.lastFindWordKey)
    }

    private func toggleRegex() {
        useRegex.toggle()
        UserDefaults.standard.set(useRegex, forKey: Self.lastFindRegexKey)
    }

    /// Esc / ⌘W: hides the editor. Unsaved text stays — the hotkey brings it back, and it's
    /// kept in history if something replaces it — so there's nothing to confirm.
    private func cancelEditor() {
        closeFindBar()
        onClose()
    }

    /// ⌥⌘W: throws the document on screen away (keeping unsaved text in history) and hides
    /// the editor.
    private func discardDocument() {
        closeFindBar()
        onDiscard()
    }

    private func closeFindBar() {
        showFindBar = false
        // findText and the find options are intentionally kept — they're restored next time Find opens.
        replaceText = ""
        matchCount = 0
        matchRanges = []
        currentMatchIndex = nil
        if let mtv = textView as? MangleTextView {
            mtv.findRanges = []
            mtv.currentFindRange = nil
        }
    }
    
    // MARK: - Transform Menu

    /// Pops the Transform menu up above its chip (⌘T or a click).
    private func showTransformMenu() {
        guard !viewModel.isPresenting, let window = textView?.window, let contentView = window.contentView,
              let chip = transformChipFrame else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false

        let languageItem = NSMenuItem(title: "Language: \(currentLanguageLabel)", action: nil, keyEquivalent: "")
        languageItem.image = Self.languageDotImage(viewModel.currentLanguage)
        languageItem.submenu = languageMenu(fittingAbove: chip)
        menu.addItem(languageItem)
        menu.addItem(.separator())

        // Sections are submenus so the menu stays short enough to open within the window;
        // a lone command (Format Code) sits at the top level.
        for section in transformSections {
            let target: NSMenu
            if section.commands.count == 1 {
                target = menu
            } else {
                target = NSMenu()
                target.autoenablesItems = false
                let sectionItem = NSMenuItem(title: section.title, action: nil, keyEquivalent: "")
                sectionItem.submenu = target
                menu.addItem(sectionItem)
            }
            for cmd in section.commands {
                let item = ClosureMenuItem(title: cmd.title, action: cmd.run)
                item.isEnabled = cmd.isEnabled
                if let shortcut = cmd.keyboardShortcut, let character = shortcut.key.character.lowercased().first {
                    // Display only — the shortcuts themselves are bound by hidden buttons.
                    item.keyEquivalent = String(character)
                    var mask: NSEvent.ModifierFlags = []
                    if shortcut.modifiers.contains(.command) { mask.insert(.command) }
                    if shortcut.modifiers.contains(.shift) { mask.insert(.shift) }
                    if shortcut.modifiers.contains(.option) { mask.insert(.option) }
                    if shortcut.modifiers.contains(.control) { mask.insert(.control) }
                    item.keyEquivalentModifierMask = mask
                }
                target.addItem(item)
            }
            if target === menu { menu.addItem(.separator()) }
        }

        popUp(menu, above: chip, in: contentView)
    }

    /// Pops the language menu up above its chip.
    private func showLanguageMenu() {
        guard let contentView = textView?.window?.contentView, let chip = languageChipFrame else { return }
        popUp(languageMenu(fittingAbove: chip), above: chip, in: contentView)
    }

    /// In a short window the list would run far past the top, so it goes in two columns.
    private func languageMenu(fittingAbove chip: CGRect) -> NSMenu {
        let menu = languageMenu(columns: 1)
        return menu.size.height > chip.minY ? languageMenu(columns: 2) : menu
    }

    /// Auto-detect (naming what it found), Plain Text, then every language with its bar colour,
    /// in `columns` columns.
    private func languageMenu(columns: Int) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let auto = ClosureMenuItem(title: "Auto-detect") { setLanguage("auto") }
        auto.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        auto.state = viewModel.languageIsManual ? .off : .on
        if !viewModel.languageIsManual {
            let title = NSMutableAttributedString(string: "Auto-detect", attributes: [.font: NSFont.menuFont(ofSize: 0)])
            title.append(NSAttributedString(string: "  \(currentLanguageLabel)", attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            auto.attributedTitle = title
        }
        menu.addItem(auto)
        menu.addItem(.separator())
        let isChosen = { (id: String) in viewModel.languageIsManual && viewModel.currentLanguage == id }
        for lang in Self.languages where lang.id != "auto" && (columns == 1 || lang.id == "plaintext") {
            let item = ClosureMenuItem(title: lang.label) { setLanguage(lang.id) }
            item.image = Self.languageDotImage(lang.id)
            item.state = isChosen(lang.id) ? .on : .off
            menu.addItem(item)
            if lang.id == "plaintext" { menu.addItem(.separator()) }
        }
        if columns > 1 {
            let cells = Self.languages.filter { $0.id != "auto" && $0.id != "plaintext" }.map { lang in
                MenuGridView.Cell(title: lang.label, image: Self.languageDotImage(lang.id),
                                  isChecked: isChosen(lang.id)) { setLanguage(lang.id) }
            }
            let grid = NSMenuItem()
            grid.view = MenuGridView(cells: cells, columns: columns)
            menu.addItem(grid)
        }
        return menu
    }

    /// Opens `menu` upwards from just above a bottom-bar chip. The chip's frame is SwiftUI global
    /// (top-left based).
    private func popUp(_ menu: NSMenu, above chip: CGRect, in contentView: NSView) {
        let chipTop = contentView.isFlipped ? chip.minY : contentView.bounds.height - chip.minY
        let point = NSPoint(x: chip.minX, y: contentView.isFlipped ? chipTop - menu.size.height - 4 : chipTop + menu.size.height + 4)
        menu.popUp(positioning: nil, at: point, in: contentView)
    }

    // MARK: - Command Palette
    
    private var paletteResults: [CommandPaletteResult] {
        CommandPaletteResults.filter(allCommands, query: paletteQuery,
                                     document: (textView?.string ?? viewModel.text) as NSString,
                                     goToLine: goToLine)
    }
    
    private func openPalette(query: String = "") {
        paletteQuery = query
        paletteIndex = 0
        showPalette = true
    }
    
    private func closePalette() {
        showPalette = false
        paletteQuery = ""
        paletteIndex = 0
        if let tv = textView { tv.window?.makeFirstResponder(tv) }
    }
    
    private func runPaletteCommand(_ command: EditorCommand) {
        guard command.isEnabled else { return }
        // Only real commands are remembered, not one-off rows like "Go to Line 42".
        if allCommands.contains(where: { $0.id == command.id }) {
            CommandPaletteResults.recordRecent(command.id)
        }
        closePalette()
        // Run after focus is back in the text view, so commands act on the editor.
        DispatchQueue.main.async { command.run() }
    }
    
    // MARK: - Commands
    
    private var documentIndentWidth: Int {
        (textView as? MangleTextView)?.indentWidth ?? max(SettingsManager.shared.tabSize, 1)
    }
    
    private var documentIndentation: Indentation {
        (textView as? MangleTextView)?.indentation ?? .defaultForSettings
    }
    
    /// Every command available in the palette: editor actions plus all transforms.
    private var allCommands: [EditorCommand] {
        let mtv = textView as? MangleTextView
        let undoManager = textView?.undoManager
        let status = viewModel.status
        var commands: [EditorCommand] = [
            EditorCommand(title: "Save to Clipboard", section: "File", shortcut: "⌘S", run: onSave),
            EditorCommand(title: "Save and Paste", section: "File", shortcut: "⌘↩", run: onSaveAndPaste),
            EditorCommand(title: "Copy to Clipboard", section: "File", run: copyDocument),
            EditorCommand(title: "Revert to Original", section: "File", isEnabled: viewModel.isDirty && !viewModel.isScratch,
                          detail: viewModel.isScratch ? "Not available for scratch pads" : (viewModel.isDirty ? nil : "No changes yet"),
                          run: revertToOriginal),
            EditorCommand(title: "New Scratch", section: "File", shortcut: "⌘N", run: onNewScratch),
            EditorCommand(title: viewModel.isScratch ? "Discard Scratch Pad" : "Discard Edit", section: "File", shortcut: "⌥⌘W",
                          key: "File/Discard", run: discardDocument),
            EditorCommand(title: "Clear Scratch Pad", section: "File", isEnabled: viewModel.isScratch && !viewModel.text.isEmpty,
                          detail: viewModel.isScratch ? (viewModel.text.isEmpty ? "Already empty" : nil) : "Scratch pads only") {
                transform("Clear Scratch Pad", scope: .document) { _ in "" }
            },
            EditorCommand(title: viewModel.isScratch ? "Hide Scratch Pad" : "Hide Editor", section: "File", shortcut: "Esc",
                          key: "File/Close", run: cancelEditor),
            EditorCommand(title: undoManager?.undoMenuItemTitle ?? "Undo", section: "Edit", shortcut: "⌘Z",
                          isEnabled: undoManager?.canUndo == true, detail: undoManager?.canUndo == true ? nil : "Nothing to undo",
                          key: "Edit/Undo") { undoManager?.undo() },
            EditorCommand(title: undoManager?.redoMenuItemTitle ?? "Redo", section: "Edit", shortcut: "⇧⌘Z",
                          isEnabled: undoManager?.canRedo == true, detail: undoManager?.canRedo == true ? nil : "Nothing to redo",
                          key: "Edit/Redo") { undoManager?.redo() },
            EditorCommand(title: "Select All", section: "Selection", shortcut: "⌘A") { textView?.selectAll(nil) },
            EditorCommand(title: viewModel.isPresenting ? "Stop Presenting" : "Start Presenting", section: "View", shortcut: "⌥⌘P",
                          key: "View/Presenting", run: onTogglePresentation),
            EditorCommand(title: "Open History", section: "App", run: onShowHistory),
            EditorCommand(title: "Open Settings…", section: "App", run: onShowSettings),
            EditorCommand(title: settings.pauseHistory ? "Resume History" : "Pause History", section: "App",
                          key: "App/Pause History") {
                settings.pauseHistory.toggle()
                AppDelegate.shared?.showToast(settings.pauseHistory ? "History paused" : "History resumed")
            },
            EditorCommand(title: "Show Keyboard Shortcuts", section: "Help", isEnabled: !viewModel.isPresenting,
                          detail: viewModel.isPresenting ? "Not while presenting" : nil) { showShortcuts = true },
            EditorCommand(title: "Fold", section: "Folding", shortcut: "⌥⌘←") { mtv?.foldAtCaret() },
            EditorCommand(title: "Unfold", section: "Folding", shortcut: "⌥⌘→") { mtv?.unfoldAtCaret() },
            EditorCommand(title: "Fold All", section: "Folding", shortcut: "⌥⇧⌘←") { mtv?.foldAll() },
            EditorCommand(title: "Unfold All", section: "Folding", shortcut: "⌥⇧⌘→") { mtv?.unfoldAll() },
            EditorCommand(title: "Collapse to Depth 1", section: "Folding") { mtv?.collapse(toDepth: 1) },
            EditorCommand(title: "Collapse to Depth 2", section: "Folding") { mtv?.collapse(toDepth: 2) },
            EditorCommand(title: "Collapse to Depth 3", section: "Folding") { mtv?.collapse(toDepth: 3) },
            EditorCommand(title: "Collapse to Depth 4", section: "Folding") { mtv?.collapse(toDepth: 4) },
            EditorCommand(title: "Copy JSON Path", section: "JSON", shortcut: "⌥⇧⌘C",
                          isEnabled: viewModel.currentLanguage == "json",
                          detail: viewModel.currentLanguage == "json" ? nil : "JSON documents only", run: copyJSONPath),
            EditorCommand(title: "Find", section: "Find", shortcut: "⌘F") {
                showFindBar = true
                isFindFieldFocused = true
                highlightMatches()
            },
            EditorCommand(title: "Replace", section: "Find") {
                showFindBar = true
                isReplaceFieldFocused = true
                highlightMatches()
            },
            EditorCommand(title: "Replace All", section: "Find", isEnabled: !findText.isEmpty,
                          detail: findText.isEmpty ? "Search for something first" : "“\(findText.prefix(30))” → “\(replaceText.prefix(30))”",
                          run: replaceAll),
            // Highlights only belong on screen while Find is open — with it closed nothing clears them.
            EditorCommand(title: "Match Case", section: "Find", isCurrent: caseSensitive) {
                toggleMatchCase()
                if showFindBar { highlightMatches() }
            },
            EditorCommand(title: "Whole Word", section: "Find", isCurrent: wholeWord) {
                toggleWholeWord()
                if showFindBar { highlightMatches() }
            },
            EditorCommand(title: "Use Regular Expression", section: "Find", isCurrent: useRegex) {
                toggleRegex()
                if showFindBar { highlightMatches() }
            },
            EditorCommand(title: "Find Next", section: "Find", shortcut: "⌘G", run: findNext),
            EditorCommand(title: "Find Previous", section: "Find", shortcut: "⇧⌘G", run: findPrevious),
            EditorCommand(title: "Use Selection for Find", section: "Find", shortcut: "⌘E", run: useSelectionForFind),
            EditorCommand(title: "Go to Line…", section: "Navigate", shortcut: "⌃G") { openPalette(query: ":") },
            EditorCommand(title: "Toggle Comment", section: "Edit", shortcut: "⌘/", run: toggleComment),
            EditorCommand(title: "Indent Lines", section: "Edit", shortcut: "⌘]") { indentLines(outdent: false) },
            EditorCommand(title: "Outdent Lines", section: "Edit", shortcut: "⌘[") { indentLines(outdent: true) },
            EditorCommand(title: "Select Next Occurrence", section: "Selection", shortcut: "⌘D") { mtv?.selectNextOccurrence() },
            EditorCommand(title: "Select All Occurrences", section: "Selection", shortcut: "⌃⌘G") { mtv?.selectAllOccurrences() },
            EditorCommand(title: "Select Line", section: "Selection", shortcut: "⌘L") { if let tv = textView { selectLine(in: tv) } },
            EditorCommand(title: "Expand Selection", section: "Selection", shortcut: "⌥⇧↑") { if let tv = textView { expandSelection(in: tv) } },
            EditorCommand(title: "Shrink Selection", section: "Selection", shortcut: "⌥⇧↓") { if let tv = textView { shrinkSelection(in: tv) } },
            EditorCommand(title: "Duplicate Line", section: "Edit", shortcut: "⇧⌘D") { if let tv = textView { duplicateLine(in: tv) } },
            EditorCommand(title: "Delete Line", section: "Edit", shortcut: "⇧⌘K") { if let tv = textView { deleteLine(in: tv) } },
            EditorCommand(title: "Move Line Up", section: "Edit", shortcut: "⌥↑") { if let tv = textView { moveLine(in: tv, up: true) } },
            EditorCommand(title: "Move Line Down", section: "Edit", shortcut: "⌥↓") { if let tv = textView { moveLine(in: tv, up: false) } },
            EditorCommand(title: settings.wordWrap ? "Turn Off Word Wrap" : "Turn On Word Wrap", section: "View", shortcut: "⌥Z",
                          key: "View/Word Wrap") { settings.wordWrap.toggle() },
            EditorCommand(title: "Zoom In", section: "View", shortcut: "⌘=") { zoom(by: 1) },
            EditorCommand(title: "Zoom Out", section: "View", shortcut: "⌘−") { zoom(by: -1) },
            EditorCommand(title: "Reset Zoom", section: "View", shortcut: "⌘0", run: resetZoom),
            EditorCommand(title: "Increase Window Size", section: "View", shortcut: "⌥⌘=") { onResizeWindow(1, false) },
            EditorCommand(title: "Decrease Window Size", section: "View", shortcut: "⌥⌘−") { onResizeWindow(-1, false) },
        ]
        commands += presentationCommands
        commands += OpenIn.installed.map { app, url in
            EditorCommand(title: "Open in: \(app.name)", section: "File") {
                OpenIn.open(viewModel.text, language: viewModel.currentLanguage, in: app, at: url)
            }
        }
        // "Indent Using" only changes what Tab inserts; "Convert" also re-indents the text.
        let indentations: [(label: String, value: Indentation)] = [("Spaces (2)", .spaces(2)), ("Spaces (4)", .spaces(4)), ("Tabs", .tabs)]
        commands += indentations.map { option in
            EditorCommand(title: "Indent Using \(option.label)", section: "Indentation",
                          isCurrent: status.indentation == option.value) { setIndentation(option.value) }
        }
        commands += indentations.map { option in
            EditorCommand(title: "Convert Indentation to \(option.label)", section: "Indentation") { convertIndentation(to: option.value) }
        }
        commands += AppAppearance.allCases.map { appearance in
            EditorCommand(title: "Set Appearance: \(appearance.rawValue)", section: "Appearance",
                          isCurrent: settings.appearance == appearance) { settings.appearance = appearance }
        }
        commands += EditorFont.allCases.map { font in
            EditorCommand(title: "Set Font: \(font.label)", section: "Appearance",
                          isCurrent: settings.editorFont == font) { settings.editorFont = font }
        }
        commands += Self.languages.map { lang in
            let isAuto = lang.id == "auto"
            return EditorCommand(title: "Set Language: \(lang.label)", section: "Language",
                                 isCurrent: isAuto ? !viewModel.languageIsManual : viewModel.currentLanguage == lang.id,
                                 detail: isAuto && !viewModel.languageIsManual ? "Detected \(currentLanguageLabel)" : nil) {
                setLanguage(lang.id)
            }
        }
        // Format Code only exists in the Transform menu for languages Prettier handles; the
        // palette still lists it (disabled) so searching for it explains why it's missing.
        if !PrettierFormatter.shared.canFormat(language: viewModel.currentLanguage) {
            commands.append(EditorCommand(title: "Format Code", section: "Format", shortcut: "⇧⌘F", isEnabled: false,
                                          detail: "Not available for \(currentLanguageLabel)", run: {}))
        }
        commands += transformSections.flatMap(\.commands).map { cmd in
            var cmd = cmd
            if cmd.section == "Line Endings" {
                cmd.isCurrent = cmd.title == "Convert to \(status.lineEnding.rawValue)"
            }
            return cmd
        }
        return commands
    }
    
    /// Transform menu contents — also exposed in the palette.
    private var transformSections: [(title: String, commands: [EditorCommand])] {
        let width = documentIndentWidth
        let indentation = documentIndentation
        func t(_ title: String, _ section: String, scope: TransformScope = .selectionOrDocument,
               shortcut: String? = nil, key: SwiftUI.KeyboardShortcut? = nil,
               _ operation: @escaping (String) throws -> String) -> EditorCommand {
            EditorCommand(title: title, section: section, shortcut: shortcut, keyboardShortcut: key) {
                transform(title, scope: scope, operation)
            }
        }
        var sections: [(title: String, commands: [EditorCommand])] = []
        if PrettierFormatter.shared.canFormat(language: viewModel.currentLanguage) {
            sections.append(("Format", [
                EditorCommand(title: "Format Code", section: "Format", shortcut: "⇧⌘F",
                              keyboardShortcut: .init("f", modifiers: [.command, .shift]), run: formatCode)
            ]))
        }
        sections.append(("Whitespace", [
            t("Trim Whitespace", "Whitespace", scope: .linesOrDocument, shortcut: "⇧⌘T", key: .init("t", modifiers: [.command, .shift]),
              TextTransforms.trimTrailingWhitespace),
            t("Normalize Indentation", "Whitespace", scope: .linesOrDocument, shortcut: "⇧⌘N", key: .init("n", modifiers: [.command, .shift])) {
                TextTransforms.normalizeIndentation($0, tabSize: width)
            },
            t("Remove All Indentation", "Whitespace", scope: .linesOrDocument, TextTransforms.removeAllIndentation),
            t("Remove Blank Lines", "Whitespace", scope: .linesOrDocument, TextTransforms.removeBlankLines),
            t("Tabs → Spaces", "Whitespace", scope: .linesOrDocument) { TextTransforms.tabsToSpaces($0, tabSize: width) },
            t("Spaces → Tabs", "Whitespace", scope: .linesOrDocument) { TextTransforms.spacesToTabs($0, tabSize: width) },
        ]))
        sections.append(("Cleanup", [
            t("Straighten Quotes", "Cleanup", TextTransforms.straightenQuotes),
            t("Remove Invisible Characters", "Cleanup", TextTransforms.removeInvisibleCharacters),
        ]))
        sections.append(("Case", [
            t("lowercase", "Case", shortcut: "⇧⌘L", key: .init("l", modifiers: [.command, .shift])) { $0.lowercased() },
            t("UPPERCASE", "Case", shortcut: "⇧⌘U", key: .init("u", modifiers: [.command, .shift])) { $0.uppercased() },
            t("Title Case", "Case", TextTransforms.titleCase),
            t("camelCase", "Case", TextTransforms.camelCase),
            t("snake_case", "Case", TextTransforms.snakeCase),
            t("kebab-case", "Case", TextTransforms.kebabCase),
            t("CONSTANT_CASE", "Case", TextTransforms.constantCase),
        ]))
        sections.append(("Lines", [
            t("Sort Lines", "Lines", scope: .linesOrDocument, TextTransforms.sortLines),
            t("Sort Lines (Natural)", "Lines", scope: .linesOrDocument, TextTransforms.sortLinesNatural),
            t("Remove Duplicate Lines", "Lines", scope: .linesOrDocument, TextTransforms.removeDuplicateLines),
            t("Reverse Lines", "Lines", scope: .linesOrDocument, TextTransforms.reverseLines),
            t("Join Lines", "Lines", scope: .currentLines, TextTransforms.joinLines),
            t("Bullet Lines", "Lines", scope: .currentLines, TextTransforms.bulletLines),
            t("Number Lines", "Lines", scope: .currentLines, TextTransforms.numberLines),
            t("Renumber Lists", "Lines", scope: .linesOrDocument, TextTransforms.renumberLists),
        ]))
        sections.append(("JSON", [
            t("Pretty Print JSON", "JSON") { try TextTransforms.prettyPrintJSON($0, indentation: indentation) },
            t("Minify JSON", "JSON", TextTransforms.minifyJSON),
            t("Sort JSON Keys", "JSON") { try TextTransforms.sortJSONKeys($0, indentation: indentation) },
            EditorCommand(title: "Validate JSON", section: "JSON", run: validateJSON),
            t("Escape as JSON String", "JSON", TextTransforms.escapeJSONString),
            t("Unescape JSON String", "JSON", TextTransforms.unescapeJSONString),
            t("Decode JWT", "JSON") { try TextTransforms.decodeJWT($0, indentation: indentation) },
        ]))
        sections.append(("Encode / Decode", [
            t("Base64 Encode", "Encode / Decode", TextTransforms.base64Encode),
            t("Base64 Decode", "Encode / Decode", TextTransforms.base64Decode),
            t("URL Encode", "Encode / Decode", TextTransforms.urlEncode),
            t("URL Decode", "Encode / Decode", TextTransforms.urlDecode),
            t("HTML Entity Encode", "Encode / Decode", TextTransforms.htmlEntityEncode),
            t("HTML Entity Decode", "Encode / Decode", TextTransforms.htmlEntityDecode),
            t("Convert Timestamp ↔ Date", "Encode / Decode", TextTransforms.convertTimestamp),
        ]))
        sections.append(("Line Endings", [
            t("Convert to LF", "Line Endings", scope: .document, TextTransforms.toLF),
            t("Convert to CRLF", "Line Endings", scope: .document, TextTransforms.toCRLF),
            t("Convert to CR", "Line Endings", scope: .document, TextTransforms.toCR),
        ]))
        return sections
    }
    
    /// Presentation mode's commands. The two preferences work any time; the rest need a
    /// presentation in progress.
    private var presentationCommands: [EditorCommand] {
        let presenting = viewModel.isPresenting
        let notPresenting = presenting ? nil : "Only while presenting"
        let mtv = textView as? MangleTextView
        let isFullScreen = textView?.window?.styleMask.contains(.fullScreen) == true
        return [
            EditorCommand(title: "Spotlight Next Line", section: "Presentation", shortcut: "→", isEnabled: presenting,
                          detail: notPresenting) { mtv?.spotlightStep(forward: true) },
            EditorCommand(title: "Spotlight Previous Line", section: "Presentation", shortcut: "←", isEnabled: presenting,
                          detail: notPresenting) { mtv?.spotlightStep(forward: false) },
            EditorCommand(title: "Fit Text to Window", section: "Presentation", isEnabled: presenting,
                          detail: notPresenting, run: fitToWindow),
            EditorCommand(title: isFullScreen ? "Exit Full Screen" : "Enter Full Screen", section: "Presentation", shortcut: "⌃⌘F",
                          isEnabled: presenting, detail: notPresenting, key: "Presentation/Full Screen",
                          run: onTogglePresentationFullScreen),
            EditorCommand(title: settings.presentationHighContrast ? "Turn Off High Contrast Presentation" : "Turn On High Contrast Presentation",
                          section: "Presentation", key: "View/High Contrast Presentation") { settings.presentationHighContrast.toggle() },
            EditorCommand(title: settings.presentationLineNumbers ? "Hide Line Numbers When Presenting" : "Show Line Numbers When Presenting",
                          section: "Presentation", key: "Presentation/Line Numbers") { settings.presentationLineNumbers.toggle() },
        ]
    }
    
    /// Sets the presentation size so the spotlighted lines (or the whole document) fill the
    /// window without scrolling or wrapping, then scrolls them into place.
    private func fitToWindow() {
        guard viewModel.isPresenting, let tv = textView, let scrollView = tv.enclosingScrollView else { return }
        let text = tv.string as NSString
        guard text.length > 0 else { return }
        let range = (tv as? MangleTextView)?.spotlightRange ?? NSRange(location: 0, length: text.length)
        var lines = text.substring(with: range).components(separatedBy: "\n")
        if lines.count > 1, lines.last?.isEmpty == true { lines.removeLast() }
        let tabWidth = (tv as? MangleTextView)?.indentWidth ?? 4
        
        // Text scales linearly with the font size, so measure once at a reference size.
        // Every line is measured: the most characters isn't the widest with wide glyphs (CJK,
        // emoji) in play.
        let reference: CGFloat = 100
        let font = settings.editorFont.nsFont(size: reference)
        let width = lines.map { (Self.expandingTabs($0, width: tabWidth) as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let height = NSLayoutManager().defaultLineHeight(for: font) * CGFloat(lines.count)
        let inset = tv.textContainerInset
        let padding = (tv.textContainer?.lineFragmentPadding ?? 0) * 2
        // The clip view spans the gutter too.
        let gutter = scrollView.verticalRulerView?.ruleThickness ?? 0
        let available = NSSize(width: scrollView.contentView.frame.width - gutter - inset.width * 2 - padding - 4,
                               height: scrollView.contentView.frame.height - inset.height * 2)
        guard width > 0, height > 0, available.width > 0, available.height > 0 else { return }
        let fitted = (min(available.width / width, available.height / height) * reference).rounded(.down)
        let bounds = SettingsManager.presentationFontSizeRange
        let size = min(max(fitted, bounds.lowerBound), bounds.upperBound)
        let scroll = { Self.scrollToTop(of: range, in: tv) }
        guard size != settings.presentationFontSize, let mtv = tv as? MangleTextView else { return scroll() }
        // The new size reaches the text on SwiftUI's next view update; scrolling before it
        // lands would measure the old layout.
        mtv.afterRestyle = scroll
        settings.presentationFontSize = size
    }
    
    /// `line` with each tab widened to the next tab stop, as the editor lays it out.
    private static func expandingTabs(_ line: String, width: Int) -> String {
        guard line.contains("\t") else { return line }
        var result = ""
        var column = 0
        for character in line {
            if character == "\t" {
                let spaces = width - column % width
                result += String(repeating: " ", count: spaces)
                column += spaces
            } else {
                result.append(character)
                column += 1
            }
        }
        return result
    }
    
    /// Puts the first line of `range` at the top of the window.
    private static func scrollToTop(of range: NSRange, in tv: NSTextView) {
        guard let storage = tv.textStorage, let lm = tv.layoutManager, range.location < storage.length else { return }
        let line = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: range.location), effectiveRange: nil)
        tv.scroll(NSPoint(x: 0, y: max(line.minY + tv.textContainerOrigin.y - tv.textContainerInset.height, 0)))
    }
    
    /// Zooms the editor, or the presentation size while presenting, one step in `direction`
    /// (+1 or -1). Steps are about a tenth of the size, and double while the key is held.
    private func zoom(by direction: CGFloat, held: Bool = false) {
        func stepped(_ size: CGFloat, in range: ClosedRange<CGFloat>) -> CGFloat {
            let step = max((size * 0.1).rounded(), 1) * (held ? 2 : 1)
            return min(max(size + direction * step, range.lowerBound), range.upperBound)
        }
        if viewModel.isPresenting {
            settings.presentationFontSize = stepped(settings.presentationFontSize, in: SettingsManager.presentationFontSizeRange)
        } else {
            settings.fontSize = stepped(settings.fontSize, in: 9...48)
        }
    }
    
    private func resetZoom() {
        if viewModel.isPresenting {
            settings.presentationFontSize = SettingsManager.defaultPresentationFontSize
        } else {
            settings.fontSize = NSFont.systemFontSize
        }
    }
    
    /// Copies the path to the JSON value under the caret, e.g. `data.users[0].email`.
    private func copyJSONPath() {
        guard let tv = textView else { return }
        guard viewModel.currentLanguage == "json" else {
            AppDelegate.shared?.showToast("Copy JSON Path needs a JSON document")
            return
        }
        let path = TextTransforms.jsonPath(in: tv.string as NSString, at: tv.selectedRange().location)
        guard !path.isEmpty else {
            AppDelegate.shared?.showToast("At the top level — no path to copy")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        AppDelegate.shared?.showToast("Copied \(path.count > 60 ? String(path.prefix(57)) + "…" : path)")
    }
    
    /// Unlike Save to Clipboard, leaves the editor open and the document unsaved.
    private func copyDocument() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(viewModel.text, forType: .string)
        AppDelegate.shared?.showToast("Copied to clipboard")
    }

    /// Pasting into an empty scratch pad (or over everything) re-detects the language and
    /// indentation, unless the user picked a language themselves.
    private func redetectLanguageAfterPaste() {
        guard !viewModel.languageIsManual else { return }
        let text = viewModel.text
        let language = text.utf16.count > 1_000_000 ? "plaintext" : CustomTextEditor.Coordinator.guessLanguage(text)
        if language != viewModel.currentLanguage { viewModel.currentLanguage = language }
        if let indentation = Indentation.detect(in: text) { setIndentation(indentation) }
    }
    
    private func setLanguage(_ id: String) {
        if id == "auto" {
            viewModel.currentLanguage = CustomTextEditor.Coordinator.guessLanguage(viewModel.text)
            viewModel.languageIsManual = false
        } else {
            viewModel.currentLanguage = id
            viewModel.languageIsManual = true
        }
    }
    
    private func goToLine(_ line: Int, column: Int? = nil) {
        guard let tv = textView else { return }
        let ns = tv.string as NSString
        var location = 0
        var current = 1
        while current < line && location < ns.length {
            location = NSMaxRange(ns.lineRange(for: NSRange(location: location, length: 0)))
            current += 1
        }
        location = min(location, ns.length)
        if let column {
            // Columns past the end of the line land at its end.
            var contentsEnd = 0
            ns.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            location = min(location + column - 1, contentsEnd)
        }
        let range = NSRange(location: location, length: 0)
        tv.window?.makeFirstResponder(tv)
        tv.setSelectedRange(range)
        tv.scrollRangeToVisible(range)
        tv.showFindIndicator(for: ns.lineRange(for: range))
    }
    
    private func toggleComment() {
        guard let syntax = CommentSyntax.forLanguage(viewModel.currentLanguage) else {
            AppDelegate.shared?.showToast("No comment syntax for \(currentLanguageLabel)")
            return
        }
        transform("Toggle Comment", scope: .currentLines) { TextTransforms.toggleComment($0, syntax: syntax) }
    }
    
    private func indentLines(outdent: Bool) {
        let unit = documentIndentation.unit
        let tabSize = documentIndentWidth
        transform(outdent ? "Outdent Lines" : "Indent Lines", scope: .currentLines) {
            outdent ? TextTransforms.outdentLines($0, tabSize: tabSize) : TextTransforms.indentLines($0, unit: unit)
        }
    }
    
    private func revertToOriginal() {
        let original = viewModel.baseText
        transform("Revert to Original", scope: .document) { _ in original }
    }
    
    private func validateJSON() {
        guard let tv = textView else { return }
        let sel = tv.selectedRange()
        let text = sel.length > 0 ? (tv.string as NSString).substring(with: sel) : tv.string
        AppDelegate.shared?.showToast(TextTransforms.validateJSON(text) ?? "Valid JSON")
    }
    
    private func setIndentation(_ indentation: Indentation) {
        (textView as? MangleTextView)?.indentation = indentation
        viewModel.status.indentation = indentation
    }
    
    /// Re-indents the document from its current indentation to `target`, then adopts it.
    private func convertIndentation(to target: Indentation) {
        let from = documentIndentation
        let tabSize = documentIndentWidth
        transform("Convert Indentation", scope: .document) {
            TextTransforms.reindent($0, from: from, to: target, tabSize: tabSize)
        }
        setIndentation(target)
    }
    
    private func convertLineEndings(to ending: LineEnding) {
        switch ending {
        case .lf: transform("Convert to LF", scope: .document, TextTransforms.toLF)
        case .crlf: transform("Convert to CRLF", scope: .document, TextTransforms.toCRLF)
        case .cr: transform("Convert to CR", scope: .document, TextTransforms.toCR)
        case .mixed: break
        }
    }

    // MARK: - Format Code

    private func formatCode() {
        let lang = viewModel.currentLanguage
        let code = viewModel.text
        let tabSize = documentIndentWidth
        
        Task {
            do {
                let formatted = try await PrettierFormatter.shared.format(
                    code: code, language: lang, tabSize: tabSize)
                await MainActor.run {
                    // Formatting is async; if the user kept typing meanwhile, applying the result
                    // would silently discard those edits.
                    guard viewModel.text == code else {
                        AppDelegate.shared?.showToast("Text changed while formatting — try again")
                        return
                    }
                    transform("Format Code", scope: .document) { _ in formatted }
                    AppDelegate.shared?.showToast("Formatted")
                }
            } catch PrettierError.syntaxError {
                await MainActor.run {
                    AppDelegate.shared?.showToast("Format failed — check syntax")
                }
            } catch {
                await MainActor.run {
                    AppDelegate.shared?.showToast("Format failed")
                }
            }
        }
    }
    
    // MARK: - Transform
    
    enum TransformScope {
        /// Always the whole document.
        case document
        /// The selection if there is one, otherwise the whole document.
        case selectionOrDocument
        /// The full lines touched by the selection, otherwise the whole document.
        case linesOrDocument
        /// The full lines touched by the selection, or the caret's line.
        case currentLines
    }
    
    /// Applies `operation` to the scoped text as a single native, named undo step.
    private func transform(_ title: String, scope: TransformScope = .selectionOrDocument, _ operation: (String) throws -> String) {
        guard let tv = textView else { return }
        (tv as? MangleTextView)?.collapseMultipleSelections()
        let ns = tv.string as NSString
        let sel = tv.selectedRange()
        let hasSelection = sel.length > 0
        let full = NSRange(location: 0, length: ns.length)
        let range: NSRange
        switch scope {
        case .document: range = full
        case .selectionOrDocument: range = hasSelection ? sel : full
        case .linesOrDocument: range = hasSelection ? fullLines(of: sel, in: ns) : full
        case .currentLines: range = fullLines(of: sel, in: ns)
        }
        let original = ns.substring(with: range)
        let result: String
        do {
            result = try operation(original)
        } catch let error as TransformError {
            AppDelegate.shared?.showToast(error.message)
            return
        } catch {
            AppDelegate.shared?.showToast("\(title) failed")
            return
        }
        guard result != original, tv.shouldChangeText(in: range, replacementString: result) else { return }
        tv.replaceCharacters(in: range, with: result)
        tv.didChangeText()
        tv.undoManager?.setActionName(title)
        
        let newLength = (result as NSString).length
        // Keep the result selected when the user had selected it (including ⌘A); only
        // document-wide commands run with a partial selection (Format, Replace All) drop it.
        if hasSelection && (range != full || sel.length == ns.length) {
            tv.setSelectedRange(NSRange(location: range.location, length: newLength))
        } else if range == full {
            tv.setSelectedRange(NSRange(location: min(sel.location, newLength), length: 0))
        } else {
            // Caret-line transform: keep the caret where it was, shifted by the edit.
            let shifted = sel.location + newLength - range.length
            tv.setSelectedRange(NSRange(location: min(max(range.location, shifted), range.location + newLength), length: 0))
        }
    }
    
    /// The full lines covered by `sel` (without the final line break). A selection that
    /// ends at the very start of a line doesn't include that line.
    private func fullLines(of sel: NSRange, in ns: NSString) -> NSRange {
        var adjusted = sel
        if sel.length > 0, ns.character(at: NSMaxRange(sel) - 1) == 10 { adjusted.length -= 1 }
        var lineStart = 0, contentsEnd = 0
        ns.getLineStart(&lineStart, end: nil, contentsEnd: &contentsEnd, for: adjusted)
        return NSRange(location: lineStart, length: contentsEnd - lineStart)
    }
}

/// MARK: - NSTextView subclass with VS Code word movement

final class MangleTextView: NSTextView {
    
    // MARK: Transient highlights (find matches, matching bracket)
    //
    // Drawn as layout-manager temporary attributes: cheap to add/remove, no layout
    // invalidation, no undo/edit notifications, and they survive Highlightr re-coloring
    // a line (which replaces all text-storage attributes in that range).
    
    var findRanges: [NSRange] = [] { didSet { refreshTransientHighlights() } }
    /// The match Find last moved to — drawn stronger than the other matches.
    var currentFindRange: NSRange? { didSet { if currentFindRange != oldValue { refreshTransientHighlights() } } }
    var bracketRanges: [NSRange] = [] { didSet { refreshTransientHighlights() } }
    
    /// This document's indentation (detected on load, changeable from the status bar).
    var indentation: Indentation = .spaces(4) { didSet { if indentation != oldValue { needsDisplay = true } } }
    var indentWidth: Int {
        if case .spaces(let n) = indentation { return max(n, 1) }
        return max(SettingsManager.shared.tabSize, 1)
    }
    /// Quote pairing is off for prose (plain text / Markdown), where it mostly gets in the way.
    var autoCloseQuotes = true
    /// In prose, Return continues a list and Tab nests its item. Off for code, where "- " and
    /// "* " mean other things.
    var continuesLists = false
    
    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    
    private func refreshTransientHighlights() {
        guard let lm = layoutManager else { return }
        let len = (textStorage?.length ?? 0)
        lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: len))
        let isDark = self.isDark
        let findColor = AppTheme.teal.withAlphaComponent(0.28)
        for r in findRanges where NSMaxRange(r) <= len {
            lm.addTemporaryAttribute(.backgroundColor, value: findColor, forCharacterRange: r)
        }
        if let current = currentFindRange, NSMaxRange(current) <= len {
            lm.addTemporaryAttribute(.backgroundColor, value: AppTheme.teal.withAlphaComponent(isDark ? 0.7 : 0.55), forCharacterRange: current)
        }
        let bracketColor = isDark
            ? NSColor(red: 0.3, green: 0.6, blue: 0.6, alpha: 0.45)
            : NSColor(red: 0.2, green: 0.7, blue: 0.7, alpha: 0.3)
        for r in bracketRanges where NSMaxRange(r) <= len {
            lm.addTemporaryAttribute(.backgroundColor, value: bracketColor, forCharacterRange: r)
        }
    }
    
    // MARK: Line numbers
    //
    // Line number lookups (caret position, gutter's first visible line) count newlines
    // relative to the last lookup instead of from the top of the document each time.
    
    private var lineAnchor = (location: 0, line: 1)
    
    func lineNumber(at location: Int) -> Int {
        let text = string as NSString
        let target = min(max(location, 0), text.length)
        if lineAnchor.location > text.length { lineAnchor = (0, 1) }
        let line: Int
        if target >= lineAnchor.location {
            line = lineAnchor.line + text.countNewlines(in: NSRange(location: lineAnchor.location, length: target - lineAnchor.location))
        } else if target < lineAnchor.location - target {
            line = 1 + text.countNewlines(in: NSRange(location: 0, length: target))
        } else {
            line = lineAnchor.line - text.countNewlines(in: NSRange(location: target, length: lineAnchor.location - target))
        }
        lineAnchor = (target, line)
        return line
    }
    
    /// Called for every character edit (`editedRange` is post-edit). Edits at/after the
    /// anchor don't change the number of newlines before it, so the anchor stays valid.
    func noteCharactersEdited(in editedRange: NSRange, changeInLength delta: Int) {
        if editedRange.location < lineAnchor.location { lineAnchor = (0, 1) }
        textVersion += 1
        adjustFolds(forEditAt: editedRange, changeInLength: delta)
    }
    
    // MARK: Folding state (logic in Folding.swift)
    
    /// Folded ranges — each is the text between a bracket pair. Nested folds are allowed.
    var folds: [NSRange] = [] { didSet { visibleFolds = Self.outermostFolds(folds) } }
    /// Off for read-only previews, which have no caret to mark.
    var showsCurrentLine = true
    /// `folds` minus those inside another fold: sorted and disjoint.
    private(set) var visibleFolds: [NSRange] = []
    /// Skip brackets inside "strings" when finding foldable blocks (off for prose).
    var foldSkipsStrings = true { didSet { if foldSkipsStrings != oldValue { regionCache = nil } } }
    var textVersion = 0
    var regionCache: (version: Int, regions: [FoldRegion], byLine: [Int: Int])?
    var unfoldCheckPending = false
    var foldRescanWork: DispatchWorkItem?
    
    // MARK: Paste
    
    /// Paste into an empty document, or over all of it — the editor re-detects the language.
    var onPasteReplacedDocument: (() -> Void)?
    
    override func paste(_ sender: Any?) {
        let length = (string as NSString).length
        let replacesDocument = selectedRange() == NSRange(location: 0, length: length)
            || string.allSatisfy(\.isWhitespace)
        super.paste(sender)
        if replacesDocument { onPasteReplacedDocument?() }
    }
    
    // MARK: Key interception (most reliable — fires before interpretKeyEvents)
    
    override func keyDown(with event: NSEvent) {
        // (The editor's key monitor has already woken the caret for this key.)
        // While a spotlight is up, ← / → step it a line at a time instead of collapsing it.
        if spotlightRange != nil, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           event.keyCode == 123 || event.keyCode == 124 {
            spotlightStep(forward: event.keyCode == 124)
            return
        }
        let opt   = event.modifierFlags.contains(.option)
        let shift = event.modifierFlags.contains(.shift)
        let cmd   = event.modifierFlags.contains(.command)
        let ctrl  = event.modifierFlags.contains(.control)
        
        // Only handle plain Option+Arrow / Option+Shift+Arrow / Option+Delete
        if opt && !cmd && !ctrl {
            switch event.keyCode {
            case 124: // Right arrow
                shift ? moveWordForwardAndModifySelection(nil) : moveWordForward(nil)
                return
            case 123: // Left arrow
                shift ? moveWordBackwardAndModifySelection(nil) : moveWordBackward(nil)
                return
            case 51: // Delete (backspace)
                if !shift { deleteWordBackward(nil); return }
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    // MARK: Multiple selections & carets
    //
    // ⌘D adds the next occurrence as an extra selection (NSTextView supports multiple
    // non-empty selections natively). Typing over them leaves several insertion points,
    // which NSTextView can't represent, so we keep the extra carets ourselves: the primary
    // caret is NSTextView's own selection and the rest live in `extraCarets`. Typing,
    // Delete and Return apply at every caret; any other command or click collapses back
    // to the primary caret.
    
    private(set) var extraCarets: [Int] = []
    private var isUpdatingMultiSelection = false
    private var lastAddedOccurrence: NSRange?
    
    var hasMultipleSelections: Bool { !extraCarets.isEmpty || selectedRanges.count > 1 }
    
    private func multiEditRanges() -> [NSRange] {
        if !extraCarets.isEmpty {
            return (extraCarets + [selectedRange().location]).sorted().map { NSRange(location: $0, length: 0) }
        }
        return selectedRanges.map(\.rangeValue).sorted { $0.location < $1.location }
    }
    
    /// Applies non-overlapping edits (sorted by location) as one undoable change, then
    /// places a caret after each replacement.
    private func applyMultiEdit(_ edits: [(range: NSRange, text: String)]) {
        guard let storage = textStorage, !edits.isEmpty else { return }
        let ranges = edits.map { NSValue(range: $0.range) }
        guard shouldChangeText(inRanges: ranges, replacementStrings: edits.map(\.text)) else { return }
        storage.beginEditing()
        for edit in edits.reversed() { storage.replaceCharacters(in: edit.range, with: edit.text) }
        storage.endEditing()
        didChangeText()
        var offset = 0
        var carets: [Int] = []
        for edit in edits {
            let length = (edit.text as NSString).length
            carets.append(edit.range.location + offset + length)
            offset += length - edit.range.length
        }
        setCarets(carets)
    }
    
    private func setCarets(_ carets: [Int]) {
        let unique = Array(Set(carets)).sorted()
        guard let primary = unique.last else { return }
        isUpdatingMultiSelection = true
        setSelectedRange(NSRange(location: primary, length: 0))
        isUpdatingMultiSelection = false
        extraCarets = Array(unique.dropLast())
        needsDisplay = true
    }
    
    /// Drops extra selections/carets, keeping the primary one.
    func collapseMultipleSelections() {
        guard hasMultipleSelections else { return }
        let primary = selectedRanges.last?.rangeValue ?? selectedRange()
        extraCarets = []
        setSelectedRange(primary)
        needsDisplay = true
    }
    
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        let oldLineRect = currentLineRect()
        let oldSpotlight = spotlightRange
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if isPresenting, spotlightRange != oldSpotlight {
            updateSelectionStyle()
            needsDisplay = true
            enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }
        if !isUpdatingMultiSelection && !extraCarets.isEmpty {
            extraCarets = []
            needsDisplay = true
        }
        // Repaint just the old and new current-line bands.
        if let oldLineRect { setNeedsDisplay(oldLineRect) }
        let newLineRect = currentLineRect()
        if let newLineRect, newLineRect != oldLineRect { setNeedsDisplay(newLineRect) }
        // The gutter mirrors the band, including moves between a wrapped line's rows.
        if newLineRect != oldLineRect { enclosingScrollView?.verticalRulerView?.needsDisplay = true }
        scheduleUnfoldCheck()
    }
    
    override func doCommand(by selector: Selector) {
        let multiAware: Set<Selector> = [
            #selector(deleteBackward(_:)), #selector(insertNewline(_:)), #selector(insertNewlineIgnoringFieldEditor(_:))
        ]
        if !extraCarets.isEmpty && !multiAware.contains(selector) {
            collapseMultipleSelections()
        }
        super.doCommand(by: selector)
    }
    
    /// ⌘D: select the word at the caret, or add the next occurrence of the selection.
    func selectNextOccurrence() {
        let text = string as NSString
        var ranges = selectedRanges.map(\.rangeValue)
        extraCarets = []
        if ranges.count == 1, ranges[0].length == 0 {
            let word = currentWordRange(at: ranges[0].location)
            guard word.length > 0 else { return }
            setSelectedRange(word)
            lastAddedOccurrence = word
            return
        }
        let anchor = lastAddedOccurrence.flatMap { ranges.contains($0) ? $0 : nil } ?? ranges.last!
        let needle = text.substring(with: anchor)
        guard !needle.isEmpty else { return }
        let all = occurrences(of: needle, in: text)
        let isFree: (NSRange) -> Bool = { r in !ranges.contains { NSIntersectionRange($0, r).length > 0 } }
        guard let next = all.first(where: { $0.location >= NSMaxRange(anchor) && isFree($0) })
                ?? all.first(where: isFree) else {
            NSSound.beep()
            return
        }
        ranges.append(next)
        ranges.sort { $0.location < $1.location }
        isUpdatingMultiSelection = true
        setSelectedRanges(ranges.map { NSValue(range: $0) }, affinity: .downstream, stillSelecting: false)
        isUpdatingMultiSelection = false
        lastAddedOccurrence = next
        scrollRangeToVisible(next)
    }
    
    /// Selects every occurrence of the selection (or of the word at the caret).
    func selectAllOccurrences() {
        let text = string as NSString
        var sel = selectedRange()
        if sel.length == 0 { sel = currentWordRange(at: sel.location) }
        guard sel.length > 0 else { return }
        let all = occurrences(of: text.substring(with: sel), in: text)
        guard !all.isEmpty else { return }
        extraCarets = []
        isUpdatingMultiSelection = true
        setSelectedRanges(all.map { NSValue(range: $0) }, affinity: .downstream, stillSelecting: false)
        isUpdatingMultiSelection = false
        lastAddedOccurrence = nil
    }
    
    private func occurrences(of needle: String, in text: NSString) -> [NSRange] {
        var result: [NSRange] = []
        var search = NSRange(location: 0, length: text.length)
        while search.length > 0 {
            let found = text.range(of: needle, options: .literal, range: search)
            if found.location == NSNotFound { break }
            result.append(found)
            let next = NSMaxRange(found)
            search = NSRange(location: next, length: text.length - next)
        }
        return result
    }
    
    /// Rect of an insertion point at `location`, in view coordinates.
    private func caretRect(at location: Int) -> NSRect? {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage else { return nil }
        let len = storage.length
        let origin = textContainerOrigin
        let endsWithNewline = len > 0 && (storage.string as NSString).character(at: len - 1) == 10
        if location >= len && (len == 0 || endsWithNewline) {
            let extra = lm.extraLineFragmentRect
            guard extra != .zero else { return nil }
            return NSRect(x: extra.minX + origin.x + tc.lineFragmentPadding, y: extra.minY + origin.y, width: 2, height: extra.height)
        }
        let charIndex = min(location, len - 1)
        let glyph = lm.glyphIndexForCharacter(at: charIndex)
        guard glyph < lm.numberOfGlyphs else { return nil }
        let fragment = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        var x = lm.location(forGlyphAt: glyph).x
        if location >= len {
            x += lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc).width
        }
        return NSRect(x: fragment.minX + x + origin.x, y: fragment.minY + origin.y, width: 2, height: fragment.height)
    }
    
    // MARK: Current line highlight
    
    func currentLineRect() -> NSRect? {
        guard layoutManager != nil, showsCurrentLine, !hidesCaret, !hasMultipleSelections, selectedRange().length == 0,
              let caret = caretRect(at: selectedRange().location) else { return nil }
        return NSRect(x: 0, y: caret.minY, width: bounds.width, height: caret.height)
    }
    
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        if let line = currentLineRect(), line.intersects(rect) {
            (isDark ? NSColor.white.withAlphaComponent(0.045) : NSColor.black.withAlphaComponent(0.045)).setFill()
            line.intersection(rect).fill(using: .sourceOver)
        }
    }

    // MARK: Auto-indent

    override func insertNewline(_ sender: Any?) {
        if hasMultipleSelections {
            applyMultiEdit(multiEditRanges().map { ($0, "\n") })
            return
        }
        let text = string as NSString
        let sel = selectedRange()

        var lineStart = 0, contentsEnd = 0
        text.getLineStart(&lineStart, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: sel.location, length: 0))
        let currentLine = text.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))
        if continuesLists, let item = ListItem(currentLine),
           sel.location >= lineStart + item.prefixLength {
            continueList(item, lineStart: lineStart, contentsEnd: contentsEnd, selection: sel)
            return
        }
        let leadingWhitespace = String(currentLine.prefix(while: { $0 == " " || $0 == "\t" }))

        let beforeCursor = text.substring(with: NSRange(location: lineStart, length: sel.location - lineStart))
        let charBefore = beforeCursor.trimmingCharacters(in: .whitespaces).last

        let afterIndex = NSMaxRange(sel)
        let charAfter: Character? = {
            guard afterIndex < text.length, let scalar = Unicode.Scalar(text.character(at: afterIndex)) else { return nil }
            return Character(scalar)
        }()

        let opens: Set<Character> = ["{", "[", "("]
        let matchingOpen: [Character: Character] = ["}": "{", "]": "[", ")": "("]

        let opensBlock = charBefore.map(opens.contains) ?? false
        let tabSpaces = indentation.unit

        let insertion: String
        let cursorOffset: Int

        if opensBlock, let afterCh = charAfter, matchingOpen[afterCh] == charBefore {
            // Cursor sits between a fresh opener and its matching closer (e.g. "{|}") —
            // expand into an indented block instead of just carrying the indent over.
            let innerIndent = leadingWhitespace + tabSpaces
            insertion = "\n" + innerIndent + "\n" + leadingWhitespace
            cursorOffset = 1 + innerIndent.utf16.count
        } else {
            let newIndent = opensBlock ? leadingWhitespace + tabSpaces : leadingWhitespace
            insertion = "\n" + newIndent
            cursorOffset = insertion.utf16.count
        }

        guard shouldChangeText(in: sel, replacementString: insertion) else { return }
        replaceCharacters(in: sel, with: insertion)
        didChangeText()
        setSelectedRange(NSRange(location: sel.location + cursorOffset, length: 0))
    }

    // MARK: Lists

    /// Return in a list item: starts the next item, or on an empty item, steps out a level
    /// (or out of the list at the top level).
    private func continueList(_ item: ListItem, lineStart: Int, contentsEnd: Int, selection sel: NSRange) {
        let replaceRange: NSRange
        let insertion: String
        if item.content.allSatisfy(\.isWhitespace) && NSMaxRange(sel) >= contentsEnd {
            replaceRange = NSRange(location: lineStart, length: contentsEnd - lineStart)
            if item.indent.isEmpty {
                insertion = ""
            } else {
                var outdented = item
                outdented.indent = TextTransforms.outdentLines(item.indent, tabSize: indentWidth)
                insertion = outdented.prefix
            }
        } else {
            replaceRange = sel
            insertion = "\n" + item.nextPrefix
        }
        guard shouldChangeText(in: replaceRange, replacementString: insertion) else { return }
        replaceCharacters(in: replaceRange, with: insertion)
        didChangeText()
        setSelectedRange(NSRange(location: replaceRange.location + insertion.utf16.count, length: 0))
    }

    /// Tab / ⇧Tab on a list item nests or un-nests the whole item, wherever the caret is.
    /// A newly nested numbered item starts again at 1. False when the line isn't a list item.
    func shiftListItem(outdent: Bool) -> Bool {
        guard continuesLists, !hasMultipleSelections else { return false }
        let text = string as NSString
        let sel = selectedRange()
        var lineStart = 0, contentsEnd = 0
        text.getLineStart(&lineStart, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: sel.location, length: 0))
        guard NSMaxRange(sel) <= contentsEnd,
              var item = ListItem(text.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))) else { return false }
        let oldLength = item.prefixLength
        if outdent {
            guard !item.indent.isEmpty else { return true }
            item.indent = TextTransforms.outdentLines(item.indent, tabSize: indentWidth)
        } else {
            item.indent += indentation.unit
            if item.number != nil { item.bullet = "1" + String(item.bullet.last!) }
        }
        let range = NSRange(location: lineStart, length: oldLength)
        guard shouldChangeText(in: range, replacementString: item.prefix) else { return true }
        replaceCharacters(in: range, with: item.prefix)
        didChangeText()
        let delta = item.prefix.utf16.count - oldLength
        setSelectedRange(NSRange(location: max(lineStart, sel.location + delta), length: sel.length))
        return true
    }

    // MARK: Auto-closing brackets & quotes

    private static let autoCloseOpeners: [unichar: unichar] = [
        40: 41,   // ( )
        91: 93,   // [ ]
        123: 125, // { }
        34: 34,   // " "
        39: 39    // ' '
    ]
    private static let autoCloseClosersOnly: Set<unichar> = [41, 93, 125] // ) ] }
    private static let autoCloseQuoteChars: Set<unichar> = [34, 39]       // " '

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        if hasMultipleSelections, !hasMarkedText(), replacementRange.location == NSNotFound {
            let typed = (insertString as? String) ?? (insertString as? NSAttributedString)?.string ?? ""
            applyMultiEdit(multiEditRanges().map { ($0, typed) })
            return
        }
        guard let str = insertString as? String, str.utf16.count == 1, let ch = str.utf16.first else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }

        let sel = replacementRange.location != NSNotFound ? replacementRange : selectedRange()
        let text = string as NSString
        let isQuote = Self.autoCloseQuoteChars.contains(ch)

        // Type-over: typing a closing bracket/quote that's already right there just moves past it.
        if (Self.autoCloseClosersOnly.contains(ch) || (isQuote && autoCloseQuotes)),
           sel.length == 0, sel.location < text.length,
           text.character(at: sel.location) == ch {
            setSelectedRange(NSRange(location: sel.location + 1, length: 0))
            return
        }

        guard let closer = Self.autoCloseOpeners[ch], !isQuote || autoCloseQuotes else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }

        // Wrap the current selection in the pair, keeping the wrapped text selected.
        if sel.length > 0 {
            let selected = text.substring(with: sel)
            let replacement = str + selected + String(UnicodeScalar(closer)!)
            guard shouldChangeText(in: sel, replacementString: replacement) else { return }
            replaceCharacters(in: sel, with: replacement)
            didChangeText()
            setSelectedRange(NSRange(location: sel.location + 1, length: (selected as NSString).length))
            return
        }

        // Only pair when the caret is before whitespace, a closer, punctuation or the end —
        // typing "(" right before "foo" shouldn't produce "()foo".
        if sel.location < text.length {
            let next = text.character(at: sel.location)
            let pairsBefore: Set<unichar> = [41, 93, 125, 44, 59, 58]   // ) ] } , ; :
            if !(wcIsSpace(next) || pairsBefore.contains(next)) {
                super.insertText(insertString, replacementRange: replacementRange)
                return
            }
        }
        if isQuote, sel.location > 0 {
            let previous = text.character(at: sel.location - 1)
            // Not after a word character (the apostrophe in "don't"), and not when completing
            // a triple quote (""" would otherwise become """").
            let completesTriple = sel.location > 1 && previous == ch && text.character(at: sel.location - 2) == ch
            if wcIsWord(previous) || completesTriple {
                super.insertText(insertString, replacementRange: replacementRange)
                return
            }
        }

        let insertion = str + String(UnicodeScalar(closer)!)
        guard shouldChangeText(in: sel, replacementString: insertion) else { return }
        replaceCharacters(in: sel, with: insertion)
        didChangeText()
        setSelectedRange(NSRange(location: sel.location + 1, length: 0))
    }

    override func deleteBackward(_ sender: Any?) {
        if hasMultipleSelections {
            let edits = multiEditRanges().compactMap { range -> (NSRange, String)? in
                if range.length > 0 { return (range, "") }
                guard range.location > 0 else { return (range, "") }
                let text = string as NSString
                let composed = text.rangeOfComposedCharacterSequence(at: range.location - 1)
                return (composed, "")
            }
            // Adjacent carets can produce overlapping deletions; keep the first of each overlap.
            var nonOverlapping: [(NSRange, String)] = []
            for edit in edits where nonOverlapping.last.map({ NSMaxRange($0.0) <= edit.0.location }) ?? true {
                nonOverlapping.append(edit)
            }
            applyMultiEdit(nonOverlapping.map { (range: $0.0, text: $0.1) })
            return
        }
        let sel = selectedRange()
        // Deleting into folded text would remove a character the user can't see; open it instead.
        if sel.length == 0, let f = fold(endingAt: sel.location) {
            unfold(f)
            return
        }
        if sel.length == 0, sel.location > 0, sel.location < (string as NSString).length {
            let text = string as NSString
            let before = text.character(at: sel.location - 1)
            let after = text.character(at: sel.location)
            if Self.autoCloseOpeners[before] == after {
                let range = NSRange(location: sel.location - 1, length: 2)
                if shouldChangeText(in: range, replacementString: "") {
                    replaceCharacters(in: range, with: "")
                    didChangeText()
                    return
                }
            }
        }
        super.deleteBackward(sender)
    }

    override func deleteForward(_ sender: Any?) {
        let sel = selectedRange()
        if !hasMultipleSelections, sel.length == 0, let f = fold(startingAt: sel.location) {
            unfold(f)
            return
        }
        super.deleteForward(sender)
    }
    
    override func mouseDown(with event: NSEvent) {
        noteInteraction()
        // Clicking a fold's ⋯ opens it.
        if let f = fold(withPlaceholderAt: convert(event.locationInWindow, from: nil)) {
            unfold(f)
            setSelectedRange(NSRange(location: f.location, length: 0))
            return
        }
        super.mouseDown(with: event)
    }

    // MARK: Indent Guides

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawIndentGuides(in: dirtyRect)
        drawFoldPlaceholders(in: dirtyRect)
        if !extraCarets.isEmpty {
            insertionPointColor.setFill()
            for location in extraCarets {
                if let rect = caretRect(at: location), rect.intersects(dirtyRect) { rect.fill() }
            }
        }
        drawSpotlightDimming(in: bounds, dirtyRect: dirtyRect)
    }
    
    // MARK: Presentation
    //
    // Selecting lines spotlights them (everything else dims), ← / → step the spotlight
    // through the lines, and the caret and current-line band stay hidden until you type.
    
    var isPresenting = false {
        didSet {
            guard isPresenting != oldValue else { return }
            lastInteraction = .distantPast
            updateSelectionStyle()
            updateCaretVisibility()
        }
    }
    
    /// Runs once, after the next whole-document re-highlight lands (a font or theme change).
    var afterRestyle: (() -> Void)?
    
    /// The theme's caret colour; `insertionPointColor` follows it unless the caret is hidden.
    var caretColor: NSColor = .textColor { didSet { updateCaretVisibility() } }
    private var lastInteraction = Date.distantPast
    private var quietWork: DispatchWorkItem?
    private static let quietDelay: TimeInterval = 1.5
    private var normalSelectedTextAttributes: [NSAttributedString.Key: Any]?
    
    /// While presenting, the caret shows only for a moment after typing or clicking, so a
    /// still screen has nothing blinking on it.
    var hidesCaret: Bool { isPresenting && Date().timeIntervalSince(lastInteraction) >= Self.quietDelay }
    
    /// The whole lines the selection covers, while presenting.
    var spotlightRange: NSRange? {
        guard isPresenting, !hasMultipleSelections else { return nil }
        let selection = selectedRange()
        guard selection.length > 0, NSMaxRange(selection) <= (string as NSString).length else { return nil }
        return (string as NSString).lineRange(for: selection)
    }
    
    /// Shows the caret for a moment (it hides again when idle while presenting).
    func noteInteraction() {
        guard isPresenting else { return }
        let wasHidden = hidesCaret
        lastInteraction = Date()
        if wasHidden { updateCaretVisibility() }
        quietWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.updateCaretVisibility() }
        quietWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.quietDelay + 0.05, execute: work)
    }
    
    private func updateCaretVisibility() {
        // The background colour rather than clear, which can punch through the view.
        insertionPointColor = hidesCaret ? backgroundColor : caretColor
        needsDisplay = true   // the current-line band
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }
    
    /// The spotlight stands in for the selection highlight while it's up.
    private func updateSelectionStyle() {
        if normalSelectedTextAttributes == nil { normalSelectedTextAttributes = selectedTextAttributes }
        if spotlightRange != nil {
            selectedTextAttributes = [.backgroundColor: NSColor.clear]
        } else if let normal = normalSelectedTextAttributes {
            selectedTextAttributes = normal
        }
    }
    
    static let spotlightDimming: CGFloat = 0.75
    
    /// The spotlight's top and bottom edges in this view's coordinates.
    func spotlightSpan() -> (top: CGFloat, bottom: CGFloat)? {
        guard let spotlight = spotlightRange, let lm = layoutManager, spotlight.length > 0 else { return nil }
        let glyphs = lm.glyphRange(forCharacterRange: spotlight, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let first = lm.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let last = lm.lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
        return (first.minY + textContainerOrigin.y, last.maxY + textContainerOrigin.y)
    }
    
    /// Drops the spotlight, leaving the caret where the spotlight started.
    func clearSpotlight() {
        guard let spotlight = spotlightRange else { return }
        setSelectedRange(NSRange(location: spotlight.location, length: 0))
    }
    
    /// Dims `rect` above and below the spotlight, for this view or (with the scroll offset)
    /// the gutter beside it.
    func drawSpotlightDimming(in rect: NSRect, scrolledBy offset: CGFloat = 0, dirtyRect: NSRect) {
        guard let (top, bottom) = spotlightSpan() else { return }
        let litTop = top - offset, litBottom = bottom - offset
        backgroundColor.withAlphaComponent(Self.spotlightDimming).setFill()
        for dim in [NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(0, litTop - rect.minY)),
                    NSRect(x: rect.minX, y: litBottom, width: rect.width, height: max(0, rect.maxY - litBottom))] {
            let fill = dim.intersection(dirtyRect)
            if !fill.isEmpty { fill.fill(using: .sourceOver) }
        }
    }
    
    /// Spotlights the next or previous line, skipping blank ones. With no spotlight yet,
    /// starts from the line at the caret. (A bigger spotlight is a drag away.)
    func spotlightStep(forward: Bool) {
        let text = string as NSString
        let current = spotlightRange
        // Walk line by line from where the search starts, so a step costs the distance it
        // moves rather than the document's length.
        var location: Int
        switch (forward, current) {
        case (true, let current?): location = NSMaxRange(current)
        case (false, let current?): location = current.location - 1
        case (_, nil): location = min(selectedRange().location, text.length)
        }
        // The caret can sit at the very end, on a last line with no newline after it.
        while location >= 0, location < text.length || (location == text.length && current == nil) {
            var lineStart = 0, lineEnd = 0, contentsEnd = 0
            text.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            let contents = NSRange(location: lineStart, length: contentsEnd - lineStart)
            if text.rangeOfCharacter(from: CharacterSet.whitespaces.inverted, options: [], range: contents).location != NSNotFound {
                setSelectedRange(contents)
                scrollRangeToVisible(contents)
                return
            }
            if forward {
                guard lineEnd > location else { return }
                location = lineEnd
            } else {
                guard lineStart > 0 else { return }
                location = lineStart - 1
            }
        }
    }
    
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshTransientHighlights()
    }

    private func drawIndentGuides(in dirtyRect: NSRect) {
        guard let layoutManager = layoutManager, let container = textContainer else { return }
        let text = string as NSString
        let len = text.length
        guard len > 0 else { return }

        let tabSize = indentWidth
        let font = self.font ?? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let charWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        guard charWidth > 0 else { return }

        let guideColor = isDark ? NSColor.white.withAlphaComponent(0.06) : NSColor.black.withAlphaComponent(0.07)

        // Only walk the dirty (visible) glyph range — same reasoning as the line-number
        // gutter fix: per-line layout lookups across the whole document don't scale.
        // dirtyRect is in view coordinates; the layout manager wants container coordinates.
        let containerRect = dirtyRect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: containerRect, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let visibleEnd = min(charRange.location + charRange.length, len)

        var lineStart = 0
        text.getLineStart(&lineStart, end: nil, contentsEnd: nil, for: NSRange(location: charRange.location, length: 0))

        let insetX = textContainerInset.width + container.lineFragmentPadding
        let insetY = textContainerInset.height

        let path = NSBezierPath()
        path.lineWidth = 1

        var charIdx = lineStart
        while charIdx < len {
            // Lines merged into a folded line above draw nothing; skip past the fold.
            if let f = fold(hidingLineStart: charIdx) {
                charIdx = NSMaxRange(text.lineRange(for: NSRange(location: NSMaxRange(f), length: 0)))
                if charIdx > visibleEnd { break }
                continue
            }
            var ls = 0, le = 0, ce = 0
            text.getLineStart(&ls, end: &le, contentsEnd: &ce, for: NSRange(location: charIdx, length: 0))
            let lineText = text.substring(with: NSRange(location: ls, length: ce - ls))

            if !lineText.trimmingCharacters(in: .whitespaces).isEmpty {
                var columns = 0
                for ch in lineText {
                    if ch == " " { columns += 1 }
                    else if ch == "\t" { columns += tabSize }
                    else { break }
                }
                let levels = columns / tabSize
                // Column 0 is just the text's left edge, so guides start at the first indent stop.
                if levels > 1 {
                    let glyphIdx = layoutManager.glyphIndexForCharacter(at: ls)
                    if glyphIdx < layoutManager.numberOfGlyphs {
                        let fragRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: nil)
                        let top = fragRect.origin.y + insetY
                        let bottom = top + fragRect.height
                        for level in 1..<levels {
                            let x = insetX + CGFloat(level * tabSize) * charWidth
                            path.move(to: NSPoint(x: x, y: top))
                            path.line(to: NSPoint(x: x, y: bottom))
                        }
                    }
                }
            }

            charIdx = le
            if charIdx > visibleEnd { break }
        }

        guideColor.setStroke()
        path.stroke()
    }

    // MARK: Overrides

    override func moveWordForward(_ sender: Any?) {
        let sel = selectedRange()
        setSelectedRange(NSRange(location: vscodeWordEnd(from: sel.location + sel.length), length: 0))
    }
    
    override func moveWordBackward(_ sender: Any?) {
        let sel = selectedRange()
        setSelectedRange(NSRange(location: vscodeWordStart(from: sel.location), length: 0))
    }
    
    override func moveWordForwardAndModifySelection(_ sender: Any?) {
        let sel = selectedRange()
        let dest = vscodeWordEnd(from: sel.location + sel.length)
        setSelectedRange(NSRange(location: sel.location, length: dest - sel.location))
    }
    
    override func moveWordBackwardAndModifySelection(_ sender: Any?) {
        let sel = selectedRange()
        let dest = vscodeWordStart(from: sel.location)
        setSelectedRange(NSRange(location: dest, length: (sel.location + sel.length) - dest))
    }
    
    override func deleteWordBackward(_ sender: Any?) {
        let sel = selectedRange()
        guard sel.length == 0 else { super.deleteWordBackward(sender); return }
        let dest = vscodeWordStart(from: sel.location)
        let range = NSRange(location: dest, length: sel.location - dest)
        guard range.length > 0, shouldChangeText(in: range, replacementString: "") else { return }
        replaceCharacters(in: range, with: "")
        didChangeText()
    }
    
    // MARK: VS Code word algorithm (NSString / unichar based)
    
    private func wcIsWord(_ c: unichar) -> Bool {
        (c >= 65 && c <= 90)  ||  // A-Z
        (c >= 97 && c <= 122) ||  // a-z
        (c >= 48 && c <= 57)  ||  // 0-9
        c == 95                    // _
    }
    
    private func wcIsSpace(_ c: unichar) -> Bool {
        c == 32 || c == 9 || c == 10 || c == 13
    }
    
    private func vscodeWordEnd(from pos: Int) -> Int {
        let s = string as NSString
        let n = s.length
        var i = pos
        while i < n && wcIsSpace(s.character(at: i)) { i += 1 }
        guard i < n else { return n }
        if wcIsWord(s.character(at: i)) {
            while i < n && wcIsWord(s.character(at: i)) { i += 1 }
        } else {
            while i < n && !wcIsWord(s.character(at: i)) && !wcIsSpace(s.character(at: i)) { i += 1 }
        }
        return i
    }
    
    private func vscodeWordStart(from pos: Int) -> Int {
        let s = string as NSString
        var i = pos
        while i > 0 && wcIsSpace(s.character(at: i - 1)) { i -= 1 }
        guard i > 0 else { return 0 }
        if wcIsWord(s.character(at: i - 1)) {
            while i > 0 && wcIsWord(s.character(at: i - 1)) { i -= 1 }
        } else {
            while i > 0 && !wcIsWord(s.character(at: i - 1)) && !wcIsSpace(s.character(at: i - 1)) { i -= 1 }
        }
        return i
    }

    func wordRange(at pos: Int) -> NSRange { currentWordRange(at: pos) }
    
    /// The word touching `pos` (checking the char at and just before the caret), or a
    /// zero-length range at `pos` if neither side is a word character. Used by smart-select.
    fileprivate func currentWordRange(at pos: Int) -> NSRange {
        let s = string as NSString
        let n = s.length
        func isWordAt(_ idx: Int) -> Bool { idx >= 0 && idx < n && wcIsWord(s.character(at: idx)) }

        let anchor: Int
        if isWordAt(pos) { anchor = pos }
        else if isWordAt(pos - 1) { anchor = pos - 1 }
        else { return NSRange(location: pos, length: 0) }

        var start = anchor, end = anchor + 1
        while start > 0 && isWordAt(start - 1) { start -= 1 }
        while end < n && isWordAt(end) { end += 1 }
        return NSRange(location: start, length: end - start)
    }
}

// MARK: - Custom Text Editor

/// Highlightr's storage, plus running counts of the language's block delimiters (`/*`, `*/`,
/// `<!--`, `"""`…). Each edit recounts only the text around it, so the highlighter can tell
/// whether a comment or string opened or closed without rescanning the document per keystroke.
nonisolated final class MangleCodeStorage: CodeAttributedString {
    /// Documents this long skip block tracking (and so block-aware re-highlighting).
    static let maxTrackedLength = 300_000

    private static let blockCommentLanguages: Set<String> = [
        "c", "cpp", "java", "javascript", "typescript", "css", "scss", "less",
        "swift", "kotlin", "go", "rust", "php", "graphql"
    ]
    static func blockDelimiters(for language: String?) -> [(open: String, close: String)] {
        guard let language else { return [] }
        var result: [(String, String)] = []
        if blockCommentLanguages.contains(language) { result.append(("/*", "*/")) }
        if language == "xml" || language == "markdown" { result.append(("<!--", "-->")) }
        if language == "python" { result.append(("\"\"\"", "\"\"\"")); result.append(("'''", "'''")) }
        return result
    }

    /// Occurrences of each delimiter in the document, keyed by the delimiter itself.
    private(set) var delimiterCounts: [String: Int] = [:]
    private var needles: [String] = []

    override var language: String? {
        // willSet: the superclass highlights from its didSet, which must see the new counts.
        willSet { recount(for: newValue) }
    }

    private func recount(for language: String?) {
        let pairs = Self.blockDelimiters(for: language)
        needles = Array(Set(pairs.flatMap { [$0.open, $0.close] }))
        delimiterCounts = [:]
        let text = string as NSString
        guard text.length < Self.maxTrackedLength else { needles = []; return }
        let all = NSRange(location: 0, length: text.length)
        for n in needles { delimiterCounts[n] = text.occurrences(of: n, in: all) }
    }

    /// False for languages without block delimiters and for documents too long to track.
    var isTrackingDelimiters: Bool { !needles.isEmpty }

    override func replaceCharacters(in range: NSRange, with str: String) {
        guard !needles.isEmpty else {
            super.replaceCharacters(in: range, with: str)
            // Resume tracking once a long document is cut back below the limit.
            if length < Self.maxTrackedLength, !Self.blockDelimiters(for: language).isEmpty { recount(for: language) }
            return
        }
        // Any delimiter the edit creates or breaks overlaps the edited range, so counting a
        // margin of (longest delimiter - 1) either side before and after gives the change.
        let margin = needles.map { ($0 as NSString).length }.max()! - 1
        let lo = max(0, range.location - margin)
        let before = NSRange(location: lo, length: min(length, NSMaxRange(range) + margin) - lo)
        let old = string as NSString
        let oldCounts = needles.map { old.occurrences(of: $0, in: before) }
        super.replaceCharacters(in: range, with: str)
        let after = NSRange(location: lo, length: before.length - range.length + (str as NSString).length)
        let new = string as NSString
        for (i, n) in needles.enumerated() {
            delimiterCounts[n, default: 0] += new.occurrences(of: n, in: after) - oldCounts[i]
        }
        if length >= Self.maxTrackedLength { needles = []; delimiterCounts = [:] }
    }
}

struct CustomTextEditor: NSViewRepresentable {
    /// Text to push into the editor when `loadGeneration` changes. While editing, the text
    /// view itself is the source of truth — keystrokes don't round-trip through SwiftUI.
    var text: String
    /// Where to put the caret when `text` is applied (switching back to a parked document).
    var selection = NSRange(location: 0, length: 0)
    var loadGeneration: Int
    var language: String
    var fontSize: CGFloat
    var editorFont: EditorFont
    var wordWrap: Bool
    var isDark: Bool
    var themeName: String
    var status: EditorStatus
    /// Presentation mode: roomier margins, spotlighting, and a caret that hides when idle.
    var isPresenting = false
    /// Off while presenting unless asked for (fold chevrons stay either way).
    var showsLineNumbers = true
    var onTextViewReady: ((NSTextView) -> Void)?
    /// Called with the generation once its text is in the text view.
    var onLoadApplied: ((Int) -> Void)?
    /// Called (debounced) after the text changes.
    var onTextChange: (() -> Void)?
    /// Called after a paste that filled an empty document or replaced all of it.
    var onPasteReplacedDocument: (() -> Void)?
    
    func makeNSView(context: Context) -> NSView {
        guard let highlightr = Highlightr() else {
            // Fallback: return a plain NSScrollView with a basic NSTextView
            let tv = NSTextView()
            tv.isEditable = true
            tv.allowsUndo = true
            tv.string = text
            let sv = NSScrollView()
            sv.documentView = tv
            sv.hasVerticalScroller = true
            return sv
        }
        let coordinator = context.coordinator
        coordinator.isInViewUpdate = true
        defer { coordinator.isInViewUpdate = false }
        let theme = themeName
        highlightr.setTheme(to: theme)
        highlightr.theme.setCodeFont(editorFont.nsFont(size: fontSize))
        coordinator.lastAppliedTheme = theme
        coordinator.currentEditorFont = editorFont
        coordinator.highlightr = highlightr
        
        let textStorage = MangleCodeStorage(highlightr: highlightr)
        textStorage.language = nil
        textStorage.highlightDelegate = coordinator
        
        let layoutManager = NSLayoutManager()
        // Lay out only what's on screen instead of the whole document up to the viewport.
        layoutManager.allowsNonContiguousLayout = true
        textStorage.addLayoutManager(layoutManager)
        
        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)
        
        let textView = MangleTextView(frame: .zero, textContainer: textContainer)
        layoutManager.delegate = textView   // hides folded text
        textView.onPasteReplacedDocument = { [weak coordinator] in coordinator?.parent.onPasteReplacedDocument?() }
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.textContainerInset = Coordinator.textInset(presenting: isPresenting)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = coordinator
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isRichText = true
        // An empty document's line takes its height from the typing font, so without this
        // the current-line band grew when the first character went in.
        textView.typingAttributes[.font] = editorFont.nsFont(size: fontSize)
        coordinator.applyThemeColors(to: textView, isDark: isDark)
        
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        // Layer-backed so AppKit clips the ruler to the scroll view's own bounds,
        // preventing it from rendering over the SwiftUI bottom bar.
        scrollView.wantsLayer = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        
        let rulerView = LineNumberRulerView(scrollView: scrollView, orientation: .verticalRuler)
        rulerView.clientView = textView
        rulerView.fontSize = fontSize
        rulerView.showsLineNumbers = showsLineNumbers
        textView.isPresenting = isPresenting
        scrollView.verticalRulerView = rulerView
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        
        coordinator.rulerView = rulerView
        coordinator.scrollView = scrollView
        coordinator.textView = textView
        coordinator.codeStorage = textStorage
        
        NotificationCenter.default.addObserver(
            coordinator, selector: #selector(Coordinator.codeStorageDidProcessEditing(_:)),
            name: NSTextStorage.didProcessEditingNotification, object: textStorage
        )
        NotificationCenter.default.addObserver(
            coordinator, selector: #selector(Coordinator.gutterNeedsRedraw),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
        
        coordinator.applyLoadedText(text, language: language, generation: loadGeneration, to: textView)
        
        DispatchQueue.main.async {
            onTextViewReady?(textView)
        }
        return scrollView
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.isInViewUpdate = true
        defer { coordinator.isInViewUpdate = false }
        
        guard let scrollView = nsView as? NSScrollView,
              let textView = scrollView.documentView as? MangleTextView else { return }
        
        if coordinator.appliedGeneration != loadGeneration {
            coordinator.applyLoadedText(text, language: language, generation: loadGeneration, to: textView)
        } else if let storage = coordinator.codeStorage, storage.language != language {
            // Manual language change from the picker
            storage.language = language
            textView.autoCloseQuotes = Coordinator.pairsQuotes(language)
            textView.continuesLists = !Coordinator.pairsQuotes(language)
            textView.foldSkipsStrings = Coordinator.pairsQuotes(language)
        }
        
        if coordinator.rulerView?.showsLineNumbers != showsLineNumbers {
            coordinator.rulerView?.showsLineNumbers = showsLineNumbers
            coordinator.rulerView?.needsDisplay = true
        }
        let inset = Coordinator.textInset(presenting: isPresenting)
        if textView.textContainerInset != inset {
            textView.textContainerInset = inset
            coordinator.rulerView?.needsDisplay = true
        }
        textView.isPresenting = isPresenting
        
        let newFont = editorFont.nsFont(size: fontSize)
        let fontChanged = coordinator.rulerView?.fontSize != fontSize
            || coordinator.currentEditorFont != editorFont
        if fontChanged {
            coordinator.rulerView?.fontSize = fontSize
            coordinator.currentEditorFont = editorFont
        }
        
        let theme = themeName
        let themeChanged = coordinator.lastAppliedTheme != theme
        if themeChanged {
            coordinator.lastAppliedTheme = theme
            coordinator.highlightr?.setTheme(to: theme)
            coordinator.applyThemeColors(to: textView, isDark: isDark)
        }
        if fontChanged && !themeChanged {
            coordinator.applyFont(newFont, to: textView)
        } else if themeChanged {
            coordinator.highlightr?.theme.setCodeFont(newFont)
            // Re-highlight the entire text so the new font applies immediately,
            // not just on the next edit.
            if let storage = coordinator.codeStorage {
                let lang = storage.language
                // nil short-circuits inside CodeAttributedString.highlight() before it
                // dispatches any work, unlike "" (which isn't nil, so it still fires a
                // wasted async highlight pass with an invalid language string).
                storage.language = nil
                storage.language = lang
            }
            textView.typingAttributes[.font] = newFont
            coordinator.rulerView?.needsDisplay = true
        }
        
        // Feature 8 – Word wrap
        if wordWrap != coordinator.currentWordWrap {
            coordinator.currentWordWrap = wordWrap
            let rulerView = coordinator.rulerView
            if wordWrap {
                textView.isHorizontallyResizable = false
                textView.autoresizingMask = [.width]
                scrollView.hasHorizontalScroller = false
                // tile() updates the clip view dimensions but does NOT resize documentView.
                // We must explicitly shrink the textView (which may have grown wide in OFF mode).
                scrollView.tile()
                // contentView.frame.width is the full scrollView width; ruler sits inside it.
                let rulerWidth = scrollView.verticalRulerView?.frame.width ?? 0
                let targetWidth = scrollView.contentView.frame.width - rulerWidth
                var newFrame = textView.frame
                newFrame.size.width = targetWidth
                textView.frame = newFrame
                // Seed the container width; widthTracksTextView keeps it in sync on future resizes.
                let inset = textView.textContainerInset
                textView.textContainer?.containerSize = NSSize(
                    width: max(targetWidth - inset.width * 2, 0),
                    height: .greatestFiniteMagnitude
                )
                textView.textContainer?.widthTracksTextView = true
            } else {
                textView.isHorizontallyResizable = true
                textView.autoresizingMask = []
                textView.textContainer?.widthTracksTextView = false
                textView.textContainer?.containerSize = NSSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                )
                scrollView.hasHorizontalScroller = true
            }
            textView.layoutManager?.invalidateLayout(
                forCharacterRange: NSRange(location: 0, length: textView.string.utf16.count),
                actualCharacterRange: nil
            )
            rulerView?.needsDisplay = true
        }
    }
    
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    
    class Coordinator: NSObject, NSTextViewDelegate, HighlightDelegate {
        var parent: CustomTextEditor
        var rulerView: LineNumberRulerView?
        var scrollView: NSScrollView?
        weak var textView: MangleTextView?
        var highlightr: Highlightr?
        var codeStorage: MangleCodeStorage?
        var lastAppliedTheme: String?
        var currentEditorFont: EditorFont = .system
        // Feature 8
        var currentWordWrap: Bool = true
        var appliedGeneration = -1
        // Suppresses selection callbacks during programmatic text replacement
        var isApplyingProgrammaticChange = false
        /// True while SwiftUI is running makeNSView/updateNSView. Publishing ObservableObject
        /// changes then is "undefined behavior" per SwiftUI, so status writes are deferred.
        var isInViewUpdate = false
        
        /// Applies status (published) changes now, or right after the current view update.
        private func publishStatus(_ change: @escaping (EditorStatus) -> Void) {
            let status = parent.status
            if isInViewUpdate {
                DispatchQueue.main.async { change(status) }
            } else {
                change(status)
            }
        }
        
        private var textChangeWork: DispatchWorkItem?
        private var statsGeneration = 0
        
        init(_ parent: CustomTextEditor) { self.parent = parent }
        
        deinit {
            NotificationCenter.default.removeObserver(self)
        }
        
        static func textInset(presenting: Bool) -> NSSize {
            presenting ? NSSize(width: 28, height: 24) : NSSize(width: 6, height: 14)
        }
        
        static func pairsQuotes(_ language: String) -> Bool {
            language != "plaintext" && language != "markdown"
        }
        
        func applyThemeColors(to textView: NSTextView, isDark: Bool) {
            let themeBG = highlightr?.theme.themeBackgroundColor
            textView.backgroundColor = themeBG ?? (isDark ? AppTheme.editorDarkBG : .textBackgroundColor)
            let caret = isDark ? AppTheme.teal : NSColor(AppTheme.tealSUI)
            if let mtv = textView as? MangleTextView { mtv.caretColor = caret } else { textView.insertionPointColor = caret }
        }
        
        /// Pushes freshly loaded text into the editor: highlights once with the already-detected
        /// language, starts a fresh undo history, and puts the caret at the top.
        func applyLoadedText(_ text: String, language: String, generation: Int, to textView: NSTextView) {
            appliedGeneration = generation
            guard let storage = codeStorage else {
                textView.string = text
                parent.onLoadApplied?(generation)
                return
            }
            isApplyingProgrammaticChange = true
            (textView as? MangleTextView)?.removeAllFoldsForReload()
            // Disable highlighting while replacing so we don't run a pass with the previous
            // document's language, then highlight once with the right one.
            storage.language = nil
            storage.beginEditing()
            storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
            let font = currentEditorFont.nsFont(size: parent.fontSize)
            let fg: NSColor = parent.isDark ? NSColor(white: 0.85, alpha: 1) : NSColor(white: 0.1, alpha: 1)
            storage.setAttributes([.font: font, .foregroundColor: fg], range: NSRange(location: 0, length: storage.length))
            storage.endEditing()
            textView.typingAttributes[.font] = font
            tokenCounts = nil
            dirtyBlock = nil
            storage.language = language
            
            // The window (and its undo manager) is reused across sessions; without this, ⌘Z
            // after opening new text replayed the previous document's edits against it.
            textView.undoManager?.removeAllActions()
            if let mtv = textView as? MangleTextView {
                mtv.findRanges = []
                mtv.currentFindRange = nil
                mtv.bracketRanges = []
                mtv.autoCloseQuotes = Self.pairsQuotes(language)
                mtv.continuesLists = !Self.pairsQuotes(language)
                mtv.foldSkipsStrings = Self.pairsQuotes(language)
                let indentation = Indentation.detect(in: text) ?? .defaultForSettings
                mtv.indentation = indentation
                publishStatus { if $0.indentation != indentation { $0.indentation = indentation } }
            }
            let length = (text as NSString).length
            let location = min(parent.selection.location, length)
            let selection = NSRange(location: location, length: min(parent.selection.length, length - location))
            textView.setSelectedRange(selection)
            textView.scrollRangeToVisible(selection)
            isApplyingProgrammaticChange = false
            parent.onLoadApplied?(generation)
            
            updateCursor(in: textView)
            scheduleTextChange(for: textView, delay: 0)
        }
        
        private static var guessCache: [Int: String] = [:]
        // guessLanguage is a static utility callable from any thread, and Swift
        // Dictionary isn't safe for concurrent mutation, so guard the cache.
        private static let guessCacheLock = NSLock()

        static func guessLanguage(_ fullText: String) -> String {
            // A bounded prefix is plenty to recognise a language, and keeps detection (and the
            // cache-key hash) cheap for multi-MB pastes and on every history row.
            let text = fullText.utf16.count > 20_000 ? String(fullText.prefix(20_000)) : fullText
            let key = text.hashValue
            guessCacheLock.lock()
            if let hit = guessCache[key] {
                guessCacheLock.unlock()
                return hit
            }
            guessCacheLock.unlock()
            let result = _guessRaw(text)
            guessCacheLock.lock()
            if guessCache.count > 1_000 { guessCache.removeAll() }
            guessCache[key] = result
            guessCacheLock.unlock()
            return result
        }

        private static func _guessRaw(_ text: String) -> String {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return "plaintext" }
            let lines = t.components(separatedBy: "\n")
            let firstLine = lines.first ?? ""
            
            // Shebang — unambiguous interpreter hint
            if firstLine.hasPrefix("#!") {
                if firstLine.contains("python")                          { return "python" }
                if firstLine.contains("ruby")                            { return "ruby" }
                if firstLine.contains("node") || firstLine.contains("deno") { return "javascript" }
                return "bash"
            }
            
            // Unambiguous prefix markers
            let lower = t.lowercased()
            if t.hasPrefix("<?php")                                             { return "php" }
            if lower.hasPrefix("<!doctype html") || lower.hasPrefix("<html")   { return "xml" }
            if t.hasPrefix("<?xml") || (t.hasPrefix("<") && t.contains("</")) { return "xml" }
            
            // JSON — leading brace/bracket with quoted content
            if (t.hasPrefix("{") || t.hasPrefix("[")) && t.contains("\"") {
                return "json"
            }
            
            // SQL — leading keyword
            let up = t.uppercased()
            let sqlPrefixes = ["SELECT ", "INSERT INTO", "UPDATE ", "DELETE FROM",
                               "CREATE TABLE", "DROP TABLE", "ALTER TABLE", "WITH "]
            if sqlPrefixes.contains(where: { up.hasPrefix($0) }) { return "sql" }
            
            // C / C++ — #include is a dead giveaway; C++ tokens distinguish them
            if t.contains("#include") {
                return score(t, ["std::", "cout", "cin", "vector<", "nullptr", "template<", "::"]) >= 1
                ? "cpp" : "c"
            }
            
            // Swift — specific framework imports are unambiguous
            if score(t, ["import SwiftUI", "import Foundation", "import AppKit",
                         "import UIKit", "import Combine"]) >= 1 { return "swift" }
            if score(t, ["@State", "@Binding", "@Published", "@ObservedObject",
                         "@StateObject", "some View", "var body"]) >= 1 { return "swift" }
            if score(t, ["func ", "guard ", " -> ", "struct ", "enum ", "protocol ", "extension ", "var ", "let "]) >= 3 { return "swift" }
            // Swift range operators — "..<" is exclusive to Swift; "..." only counts when
            // used as a range (preceded by a word char), not as JS/TS spread (...arr)
            let hasSwiftRange = t.contains("..<") ||
            t.range(of: #"[\w\d]\.\.\."#, options: .regularExpression) != nil
            if hasSwiftRange &&
                score(t, ["func ", "var ", "let ", " -> ", "for "]) >= 2 { return "swift" }
            
            // Rust
            if score(t, ["fn ", "let mut ", "impl ", "pub struct", "pub fn",
                         "use std::", "Some(", "Ok(", "Err("]) >= 2 { return "rust" }
            
            // Go — `package` declaration anchors detection
            if t.contains("package ") &&
                score(t, ["func ", ":=", "fmt.", "var ", "type ", "interface{}", "map["]) >= 1 { return "go" }
            // Go — snippets without package: `func` + any Go-specific hint
            if t.contains("func ") &&
                score(t, [":=", "fmt.", "rand.", "defer ", "go func", "make(", "chan ", "goroutine"]) >= 1 { return "go" }
            if score(t, [":=", "fmt.", "rand.", "goroutine", "defer ", "go func"]) >= 2 { return "go" }
            
            // Kotlin — keywords not shared with Java
            if score(t, ["fun ", "val ", "data class", "companion object",
                         "suspend fun", "?.let", "?: "]) >= 2 { return "kotlin" }
            
            // Java
            if score(t, ["public class", "public static void main", "System.out.println",
                         "import java.", "@Override", "extends ", "implements "]) >= 2 { return "java" }
            
            // Python — colon-block style without braces separates it from JS/TS
            if score(t, ["def ", "elif ", "self.", "if __name__",
                         "print(", "lambda ", "import numpy", "import pandas"]) >= 2 { return "python" }
            if t.contains("def ") && t.contains(":") && !t.contains("{") { return "python" }
            
            // Perl — sub + Perl-specific sigils/builtins
            if t.contains("sub ") &&
                score(t, ["@_", "scalar(", "$_[", "my $", "use strict", "use warnings", "->{"]) >= 1 { return "perl" }
            if score(t, ["@_", "scalar(@", "my $", "use strict", "use warnings"]) >= 2 { return "perl" }
            
            // Ruby — `def`+`end` without braces is unambiguous (Python uses `:`, JS/Swift use `{}`)
            if t.contains("def ") && t.contains("end") && !t.contains("{") { return "ruby" }
            if score(t, ["def ", " do\n", " do |", "puts ", "require ",
                         "attr_accessor", ".each", "class << self", " end\n"]) >= 2 { return "ruby" }
            
            // TypeScript — type annotations checked before generic JS
            if score(t, ["interface ", ": string", ": number", ": boolean",
                         "export type ", "export interface", "readonly ", "<T>", " as "]) >= 2 { return "typescript" }
            
            // JavaScript
            if score(t, ["const ", "function ", "=>", "require(", "module.exports",
                         "console.log", "async ", "typeof "]) >= 2 { return "javascript" }
            
            // YAML — lines matching `key: value` pattern
            let yamlLines = lines.filter { line in
                let s = line.trimmingCharacters(in: .whitespaces)
                return !s.isEmpty && !s.hasPrefix("#") &&
                s.range(of: #"^[\w.-]+:\s"#, options: .regularExpression) != nil
            }
            if yamlLines.count >= 2 { return "yaml" }
            
            // CSS — specific property names, not generic punctuation
            if score(t, ["color:", "background:", "margin:", "padding:",
                         "display:", "font-size:", "border:", "flex:", "position:"]) >= 2 { return "css" }
            
            // Markdown
            if score(t, ["## ", "# ", "**", "```", "---", "> "]) >= 2 { return "markdown" }
            
            return "plaintext"
        }
        
        static func score(_ text: String, _ tokens: [String]) -> Int {
            tokens.filter { text.contains($0) }.count
        }
        
        @objc func gutterNeedsRedraw() {
            rulerView?.needsDisplay = true
        }
        
        @objc func codeStorageDidProcessEditing(_ notification: Notification) {
            guard let storage = notification.object as? NSTextStorage else { return }
            if storage.editedMask.contains(.editedCharacters) {
                textView?.noteCharactersEdited(in: storage.editedRange, changeInLength: storage.changeInLength)
            }
            rulerView?.needsDisplay = true
        }
        
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            scheduleTextChange(for: textView, delay: 0.12)
        }
        
        /// Debounced: recompute stats off the main thread and notify the view. Typing a burst
        /// of characters does this once, after the burst, instead of per keystroke.
        private func scheduleTextChange(for textView: NSTextView, delay: TimeInterval) {
            textChangeWork?.cancel()
            let work = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.statsGeneration += 1
                let generation = self.statsGeneration
                let snapshot = textView.string
                let status = self.parent.status
                DispatchQueue.global(qos: .userInitiated).async {
                    let stats = TextStats.compute(snapshot)
                    let lineEnding = LineEnding.detect(in: snapshot)
                    DispatchQueue.main.async {
                        guard generation == self.statsGeneration else { return }
                        if status.lineEnding != lineEnding { status.lineEnding = lineEnding }
                        if status.lines != stats.lines { status.lines = stats.lines }
                        if status.words != stats.words { status.words = stats.words }
                        if status.chars != stats.chars { status.chars = stats.chars }
                        self.rulerView?.setLineCount(stats.lines)
                    }
                }
                self.parent.onTextChange?()
            }
            textChangeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        // MARK: - Multi-line construct highlighting
        //
        // Highlightr's CodeAttributedString re-lexes only the single edited paragraph per
        // keystroke, with no memory of surrounding lines, so multi-line constructs (block
        // comments, triple-quoted strings) lose correct highlighting past their opening line.
        // We intercept those paragraph passes via HighlightDelegate: when an edit sits inside
        // such a construct — or adds/removes one of its delimiters — we skip Highlightr's pass
        // and, on the next run-loop turn, re-highlight the whole affected region ourselves
        // (from the construct's opening line to its close, or to the end of the document when
        // a delimiter appeared/disappeared).
        //
        // Every other pass comes through here too, rather than Highlightr's own. Those run on
        // an unordered concurrent queue and read the language when they run, so a pass started
        // around a language switch (e.g. pasting JSON into a scratch pad) could finish last and
        // repaint the whole document uncoloured, until each line was edited again. Our passes
        // are applied in order and only if the text and language still match.

        /// The storage's delimiter counts as of the last highlight pass.
        private var tokenCounts: [String: Int]?
        /// Pending block re-highlight: earliest dirty location, distance of the latest dirty
        /// end from the end of the document (stable under edits before it), and whether it
        /// must run to the end of the document.
        private var dirtyBlock: (start: Int, tail: Int, toEnd: Bool)?
        private let regionQueue = DispatchQueue(label: "co.liamo.mangle.highlight-region", qos: .userInitiated)
        /// Regions up to this size are highlighted synchronously (well under a frame);
        /// larger ones go to a background queue. Whole-document passes (load, language or
        /// theme change) get the higher limit, so a short document never shows uncoloured;
        /// per-edit passes the lower one, so typing in a long line doesn't wait on it.
        private static let syncDocumentLimit = 30_000
        private static let syncEditLimit = 2_000
        
        func shouldHighlight(_ range: NSRange) -> Bool {
            guard let storage = codeStorage, storage.language != nil else { return false }
            let len = storage.length
            let isFullPass = range.location == 0 && range.length >= len
            let countsChanged = storage.delimiterCounts != tokenCounts
            tokenCounts = storage.delimiterCounts
            
            let toEnd = isFullPass || countsChanged
            let start = isFullPass ? 0 : range.location
            let tail = isFullPass ? 0 : len - NSMaxRange(range)
            if let pending = dirtyBlock {
                dirtyBlock = (min(pending.start, start), min(pending.tail, tail), pending.toEnd || toEnd)
            } else {
                dirtyBlock = (start, tail, toEnd)
                DispatchQueue.main.async { [weak self] in self?.flushDirtyBlock() }
            }
            return false
        }
        
        /// Location of the unclosed opening delimiter before `location`, if it's inside a construct.
        private func blockOpener(before location: Int, open: String, close: String, in text: NSString) -> Int? {
            let before = NSRange(location: 0, length: location)
            if open == close {
                guard text.occurrences(of: open, in: before) % 2 == 1 else { return nil }
                let loc = text.range(of: open, options: [.literal, .backwards], range: before).location
                return loc == NSNotFound ? nil : loc
            }
            let lastOpen = text.range(of: open, options: [.literal, .backwards], range: before).location
            guard lastOpen != NSNotFound else { return nil }
            let lastClose = text.range(of: close, options: [.literal, .backwards], range: before).location
            return lastClose == NSNotFound || lastOpen > lastClose ? lastOpen : nil
        }
        
        /// Computes the region to re-highlight from the *current* text, so edits made while
        /// a pass was pending are folded in rather than racing it.
        private func flushDirtyBlock() {
            guard let dirty = dirtyBlock else { return }
            dirtyBlock = nil
            guard let storage = codeStorage, let language = storage.language else { return }
            let text = storage.string as NSString
            let len = text.length
            // Delimiters that don't occur can't open a construct around the edit.
            let delimiters = MangleCodeStorage.blockDelimiters(for: language)
                .filter { !storage.isTrackingDelimiters || storage.delimiterCounts[$0.open, default: 0] > 0 }
            
            let dirtyStart = min(dirty.start, len)
            let dirtyEnd = max(dirtyStart, len - min(dirty.tail, len))
            // Highlightr's span ends after a newline, so the line *at* dirtyEnd is the one after
            // the edit. Keep it: Return mid-line moves the rest of the line there, and it needs
            // recolouring too.
            var start = text.lineRange(for: NSRange(location: dirtyStart, length: 0)).location
            var end = NSMaxRange(text.lineRange(for: NSRange(location: dirtyEnd, length: 0)))
            if dirty.toEnd { end = len }
            for d in delimiters {
                guard let opener = blockOpener(before: dirtyStart, open: d.open, close: d.close, in: text) else { continue }
                start = min(start, text.lineRange(for: NSRange(location: opener, length: 0)).location)
                if !dirty.toEnd {
                    let searchFrom = dirtyEnd
                    let nextClose = text.range(of: d.close, options: .literal, range: NSRange(location: searchFrom, length: len - searchFrom))
                    end = max(end, nextClose.location == NSNotFound
                              ? len
                              : NSMaxRange(text.lineRange(for: NSRange(location: NSMaxRange(nextClose), length: 0))))
                }
            }
            let region = NSRange(location: start, length: max(0, min(end, len) - start))
            guard region.length > 0 else { return }
            highlightRegion(region, language: language)
        }
        
        /// Bumped by each font change, so a highlight pass started before it doesn't put the
        /// old font back.
        private var fontGeneration = 0

        /// Swaps the editor's fonts in place. Colours don't change with the font, so this
        /// skips a re-highlight, which ran highlight.js over the whole document on every zoom.
        func applyFont(_ font: NSFont, to textView: MangleTextView) {
            guard let theme = highlightr?.theme, let storage = codeStorage else { return }
            fontGeneration += 1
            let anchor = topVisibleAnchor(in: textView)
            // Before the swap, so the relayout sizes the empty last line from the new font too.
            textView.typingAttributes[.font] = font
            Self.swapFonts(in: storage, theme: theme, to: font)
            // Relayout only repaints the text itself, so shrinking left the old, taller
            // current-line band showing in the margin beside it.
            textView.needsDisplay = true
            rulerView?.needsDisplay = true

            if let anchor { restore(anchor, in: textView) }
            // The caret keeps its old size and place through an attribute-only change, and was
            // left behind as a stray bar after a zoom. Re-place it once layout has caught up.
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                textView.updateInsertionPointStateAndRestartTimer(true)
                textView.needsDisplay = true
            }
            if let then = textView.afterRestyle {
                textView.afterRestyle = nil
                then()
            }
        }

        /// Sets `theme`'s font and swaps it into already-highlighted text, regular, bold and
        /// italic runs each for their new counterpart.
        static func swapFonts(in storage: CodeAttributedString, theme: Theme, to font: NSFont) {
            let old = (regular: theme.codeFont, bold: theme.boldCodeFont, italic: theme.italicCodeFont)
            theme.setCodeFont(font)
            var replacements: [NSFont: NSFont] = [:]
            storage.replaceFonts { current in
                if let cached = replacements[current] { return cached }
                let new: NSFont
                if current == old.regular { new = theme.codeFont }
                else if current == old.bold { new = theme.boldCodeFont }
                else if current == old.italic { new = theme.italicCodeFont }
                else { new = NSFont(descriptor: current.fontDescriptor, size: font.pointSize) ?? font }
                replacements[current] = new
                return new
            }
        }

        /// The first visible character and how far down its line the viewport starts, so a
        /// zoom keeps the same text at the top instead of jumping.
        private func topVisibleAnchor(in textView: NSTextView) -> (char: Int, fraction: CGFloat)? {
            guard let lm = textView.layoutManager, let container = textView.textContainer,
                  textView.textStorage?.length ?? 0 > 0 else { return nil }
            let top = textView.visibleRect.minY - textView.textContainerOrigin.y
            guard top > 0 else { return nil }
            let glyph = lm.glyphIndex(for: NSPoint(x: 0, y: top), in: container)
            let line = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let fraction = line.height > 0 ? min(max((top - line.minY) / line.height, 0), 1) : 0
            return (lm.characterIndexForGlyph(at: glyph), fraction)
        }

        private func restore(_ anchor: (char: Int, fraction: CGFloat), in textView: NSTextView) {
            guard let lm = textView.layoutManager, let length = textView.textStorage?.length,
                  anchor.char < length else { return }
            let line = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: anchor.char), effectiveRange: nil)
            let y = line.minY + anchor.fraction * line.height + textView.textContainerOrigin.y
            textView.scroll(NSPoint(x: textView.visibleRect.minX, y: max(y, 0)))
        }

        private func highlightRegion(_ region: NSRange, language: String) {
            guard let storage = codeStorage, let highlightr else { return }
            let code = (storage.string as NSString).substring(with: region)
            let isWholeDocument = region.location == 0 && region.length == storage.length
            
            let fontGeneration = self.fontGeneration
            func apply(_ highlighted: NSAttributedString) -> Bool {
                // Drop stale results: the text, language or font changed meanwhile.
                guard NSMaxRange(region) <= storage.length,
                      storage.language == language,
                      fontGeneration == self.fontGeneration,
                      highlighted.string == code,
                      (storage.string as NSString).substring(with: region) == code else { return false }
                storage.beginEditing()
                highlighted.enumerateAttributes(in: NSRange(location: 0, length: highlighted.length)) { attrs, r, _ in
                    storage.setAttributes(attrs, range: NSRange(location: region.location + r.location, length: r.length))
                }
                storage.endEditing()
                if isWholeDocument, let textView, let then = textView.afterRestyle {
                    textView.afterRestyle = nil
                    then()
                }
                return true
            }
            
            if region.length <= (isWholeDocument ? Self.syncDocumentLimit : Self.syncEditLimit) {
                if let highlighted = highlightr.highlight(code, as: language) { _ = apply(highlighted) }
                return
            }
            // Distance from the region's end to the document's end: stable under edits inside
            // or before the region, so a retry can find the same span again.
            let tail = storage.length - NSMaxRange(region)
            regionQueue.async { [weak self] in
                guard let highlighted = highlightr.highlight(code, as: language) else { return }
                DispatchQueue.main.async {
                    guard let self, !apply(highlighted) else { return }
                    // The text changed while we were highlighting; retry over the same span.
                    let len = storage.length
                    let start = min(region.location, len)
                    if let pending = self.dirtyBlock {
                        self.dirtyBlock = (min(pending.start, start), min(pending.tail, tail), pending.toEnd)
                    } else {
                        self.dirtyBlock = (start, tail, false)
                        DispatchQueue.main.async { [weak self] in self?.flushDirtyBlock() }
                    }
                }
            }
        }
        
        // Feature 1 – cursor position
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isApplyingProgrammaticChange else { return }
            guard let textView = notification.object as? NSTextView else { return }
            updateCursor(in: textView)
        }
        
        private func updateCursor(in textView: NSTextView) {
            let nsText = textView.string as NSString
            let loc = min(textView.selectedRange().location, nsText.length)
            let lineNum = (textView as? MangleTextView)?.lineNumber(at: loc)
                ?? nsText.countNewlines(in: NSRange(location: 0, length: loc)) + 1
            
            var lineStart = 0
            nsText.getLineStart(&lineStart, end: nil, contentsEnd: nil, for: NSRange(location: loc, length: 0))
            // Count characters (grapheme clusters), not UTF-16 units, so an emoji is one column.
            let col = nsText.substring(with: NSRange(location: lineStart, length: loc - lineStart)).count + 1
            
            if rulerView?.activeLine != lineNum {
                rulerView?.activeLine = lineNum
                rulerView?.needsDisplay = true
            }
            publishStatus { status in
                if status.cursorLine != lineNum { status.cursorLine = lineNum }
                if status.cursorColumn != col { status.cursorColumn = col }
            }
            
            highlightMatchingBracket(in: textView)
        }
        
        // MARK: - Bracket Highlighting
        
        private static let bracketPairs: [unichar: unichar] = [
            40: 41, 123: 125, 91: 93,   // ( { [  →  ) } ]
            41: 40, 125: 123, 93: 91
        ]
        private static let openBrackets: Set<unichar> = [40, 123, 91]
        /// Bound the matching scan so a caret next to the outer brace of a huge minified
        /// file doesn't scan megabytes on every caret move.
        private static let bracketScanLimit = 20_000
        
        private func highlightMatchingBracket(in textView: NSTextView) {
            guard let mtv = textView as? MangleTextView else { return }
            let sel = textView.selectedRange()
            guard sel.length == 0 else {
                if !mtv.bracketRanges.isEmpty { mtv.bracketRanges = [] }
                return
            }
            
            // Try char before cursor first, then char after cursor
            let nsStr = textView.string as NSString
            let nsLen = nsStr.length
            let loc = sel.location
            var anchor: Int? = nil
            for pos in [loc - 1, loc] where pos >= 0 && pos < nsLen {
                if Self.bracketPairs[nsStr.character(at: pos)] != nil { anchor = pos; break }
            }
            guard let anchor else {
                if !mtv.bracketRanges.isEmpty { mtv.bracketRanges = [] }
                return
            }
            let bracketChar = nsStr.character(at: anchor)
            guard let matchChar = Self.bracketPairs[bracketChar] else { return }

            let isOpen = Self.openBrackets.contains(bracketChar)
            var depth = 0
            var matchPos: Int? = nil
            if isOpen {
                let end = min(nsLen, anchor + Self.bracketScanLimit)
                for i in anchor..<end {
                    let ch = nsStr.character(at: i)
                    if ch == bracketChar { depth += 1 }
                    else if ch == matchChar {
                        depth -= 1
                        if depth == 0 { matchPos = i; break }
                    }
                }
            } else {
                let end = max(0, anchor - Self.bracketScanLimit)
                for i in stride(from: anchor, through: end, by: -1) {
                    let ch = nsStr.character(at: i)
                    if ch == bracketChar { depth += 1 }
                    else if ch == matchChar {
                        depth -= 1
                        if depth == 0 { matchPos = i; break }
                    }
                }
            }
            
            var ranges = [NSRange(location: anchor, length: 1)]
            if let mp = matchPos { ranges.append(NSRange(location: mp, length: 1)) }
            if mtv.bracketRanges != ranges { mtv.bracketRanges = ranges }
        }
        
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                handleTab(textView: textView, reverse: false)
                return true
            } else if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                handleTab(textView: textView, reverse: true)
                return true
            } else if commandSelector == #selector(NSResponder.deleteToBeginningOfLine(_:)) {
                let selected = textView.selectedRange()
                let text = textView.string as NSString
                var lineStart = 0, lineEnd = 0, contentsEnd = 0
                text.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: selected)
                if selected.length == 0 && selected.location == lineStart && lineStart > 0 {
                    let range = NSRange(location: lineStart - 1, length: 1)
                    if textView.shouldChangeText(in: range, replacementString: "") {
                        textView.replaceCharacters(in: range, with: "")
                        textView.didChangeText()
                    }
                    return true
                }
                return false
            }
            return false
        }
        
        private func handleTab(textView: NSTextView, reverse: Bool) {
            let mtv = textView as? MangleTextView
            if mtv?.shiftListItem(outdent: reverse) == true { return }
            let indentation = mtv?.indentation ?? .defaultForSettings
            let tabSize = mtv?.indentWidth ?? max(SettingsManager.shared.tabSize, 1)
            let spaces = indentation.unit
            let selectedRange = textView.selectedRange()
            let text = textView.string as NSString
            
            var lineStart = 0, lineEnd = 0, contentsEnd = 0
            text.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: selectedRange)
            
            let selectedText = text.substring(with: selectedRange)
            let isMultiline = selectedText.contains("\n")
            
            if isMultiline {
                let fullRange = NSRange(location: lineStart, length: lineEnd - lineStart)
                let selectedLines = text.substring(with: fullRange)
                var lines = selectedLines.components(separatedBy: "\n")
                // The block usually ends with the last line's newline, which leaves an empty
                // trailing component. Indenting that used to push the *next* line in as well.
                let endsWithNewline = selectedLines.hasSuffix("\n")
                if endsWithNewline { lines.removeLast() }
                
                let block = lines.joined(separator: "\n")
                let modified = reverse
                    ? TextTransforms.outdentLines(block, tabSize: tabSize)
                    : TextTransforms.indentLines(block, unit: spaces)
                let newText = modified + (endsWithNewline ? "\n" : "")
                if textView.shouldChangeText(in: fullRange, replacementString: newText) {
                    textView.replaceCharacters(in: fullRange, with: newText)
                    textView.didChangeText()
                    // Keep the indented lines selected so Tab/⇧Tab can be repeated.
                    let selectedLength = (newText as NSString).length - (endsWithNewline ? 1 : 0)
                    textView.setSelectedRange(NSRange(location: lineStart, length: selectedLength))
                }
            } else {
                if reverse {
                    let lineText = text.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))
                    let beforeCursor = lineText.prefix(selectedRange.location - lineStart)
                    if beforeCursor.hasSuffix("\t") {
                        let removeRange = NSRange(location: selectedRange.location - 1, length: 1)
                        if textView.shouldChangeText(in: removeRange, replacementString: "") {
                            textView.replaceCharacters(in: removeRange, with: "")
                            textView.didChangeText()
                        }
                    } else {
                        let trailingSpaces = beforeCursor.reversed().prefix(while: { $0 == " " }).count
                        let toRemove = min(trailingSpaces, tabSize)
                        if toRemove > 0 {
                            let removeRange = NSRange(location: selectedRange.location - toRemove, length: toRemove)
                            if textView.shouldChangeText(in: removeRange, replacementString: "") {
                                textView.replaceCharacters(in: removeRange, with: "")
                                textView.didChangeText()
                            }
                        }
                    }
                } else {
                    // Advance to the next tab stop rather than inserting a fixed width.
                    let column = selectedRange.location - lineStart
                    let insertion = indentation == .tabs
                        ? "\t"
                        : String(repeating: " ", count: tabSize - (column % tabSize))
                    if textView.shouldChangeText(in: selectedRange, replacementString: insertion) {
                        textView.replaceCharacters(in: selectedRange, with: insertion)
                        textView.didChangeText()
                    }
                }
            }
        }
    }
}

// MARK: - Status Bar Labels

/// "Spaces: 4" (plus "· CRLF" when the line endings aren't LF) — shows the document's
/// indentation and line endings, and changes them. Converting to CR is left to the palette.
private struct DocumentFormatMenu: View {
    @ObservedObject var status: EditorStatus
    let onIndentation: (Indentation) -> Void
    let onConvertIndentation: (Indentation) -> Void
    let onLineEnding: (LineEnding) -> Void
    
    private let options: [Indentation] = [.spaces(2), .spaces(4), .tabs]
    
    var body: some View {
        BarMenu(title: title, systemImage: "increase.indent") {
            Picker("Indent Using", selection: Binding(get: { status.indentation }, set: onIndentation)) {
                ForEach(options, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
            Menu("Convert Indentation To") {
                ForEach(options, id: \.self) { option in
                    Button(option.label) { onConvertIndentation(option) }
                }
            }
            Divider()
            Section("Line Endings: \(status.lineEnding.rawValue)") {
                ForEach([LineEnding.lf, .crlf].filter { $0 != status.lineEnding }, id: \.self) { ending in
                    Button("Convert to \(ending.rawValue)") { onLineEnding(ending) }
                }
            }
        }
        .help("Indentation and line endings")
    }
    
    private var title: String {
        let indentation = status.indentation.label
        return status.lineEnding == .lf ? indentation : "\(indentation) · \(status.lineEnding.rawValue)"
    }
}

/// A bottom-bar menu drawn as a chip: icon (or colour dot), title and a small chevron on a
/// faint fill that brightens on hover.
private struct BarMenu<Content: View>: View {
    let title: String
    var systemImage: String? = nil
    var tint: Color? = nil
    var dot: Color? = nil
    @ViewBuilder let content: () -> Content
    @State private var hovered = false

    var body: some View {
        Menu(content: content) {
            BarChipLabel(title: title, systemImage: systemImage, tint: tint, dot: dot, hovered: hovered)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovered = $0 }
    }
}

private struct BarChipLabel: View {
    let title: String
    var systemImage: String? = nil
    var tint: Color? = nil
    var dot: Color? = nil
    let hovered: Bool

    var body: some View {
        HStack(spacing: 5) {
            if let dot {
                Circle()
                    .fill(dot)
                    .frame(width: 7, height: 7)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(tint ?? .secondary)
            }
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(hovered ? .primary : .primary.opacity(0.75))
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .bold))
                .foregroundColor(.secondary.opacity(hovered ? 0.9 : 0.5))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.secondary.opacity(hovered ? 0.16 : 0.07), in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
    }
}

/// A bottom-bar button's label: title and an optional shortcut, on a fill that shows on hover.
struct BarActionLabel: View {
    let title: String
    var systemImage: String? = nil
    var shortcut: String? = nil
    let hovered: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary.opacity(hovered ? 0.9 : 0.6))
            }
            Text(title)
                .foregroundColor(hovered ? .primary : .primary.opacity(0.75))
            if let shortcut {
                Text(shortcut)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(hovered ? .secondary : .secondary.opacity(0.6))
            }
        }
        .font(.system(size: 12))
        .fixedSize()
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(hovered ? Color.secondary.opacity(0.12) : Color.clear)
        .cornerRadius(5)
    }
}

/// The window's main action (Save, Edit): teal text on a teal tint.
struct BarPrimaryActionLabel: View {
    let title: String
    var shortcut: String? = nil
    let hovered: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .fontWeight(.medium)
                .foregroundColor(AppTheme.tealSUI)
            if let shortcut {
                Text(shortcut)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(AppTheme.tealSUI.opacity(0.6))
            }
        }
        .font(.system(size: 12))
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(AppTheme.tealSUI.opacity(hovered ? 0.22 : 0.14))
        .cornerRadius(5)
    }
}

/// A count and its unit ("12 ln") in the bottom bar.
struct BarStat: View {
    let value: Int
    let label: String
    /// Room is kept for this many digits, so the bar doesn't shift until the count outgrows it.
    var reservedDigits = 1

    var body: some View {
        ZStack(alignment: .leading) {
            stat(String(repeating: "0", count: reservedDigits)).hidden()
            stat("\(value)")
        }
        .font(.system(size: 11))
    }

    private func stat(_ number: String) -> some View {
        HStack(spacing: 2) {
            Text(number)
                .monospacedDigit()
                .foregroundColor(.primary.opacity(0.7))
            Text(label)
                .foregroundColor(.secondary.opacity(0.7))
        }
    }
}

struct BarDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.2))
            .frame(width: 1, height: 16)
    }
}

/// A menu item that runs a closure (NSMenuItem needs a target/action otherwise).
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}

/// Menu items laid out in columns (read down, then across), for lists too long for a short
/// window. Looks like ordinary menu items; picked with the mouse only.
private final class MenuGridView: NSView {
    struct Cell {
        let title: String
        let image: NSImage?
        let isChecked: Bool
        let action: () -> Void
    }

    private let cells: [Cell]
    private let rows: Int
    private let columnWidth: CGFloat
    private let rowHeight: CGFloat = 24
    private let inset: CGFloat = 5
    private let font = NSFont.menuFont(ofSize: 0)
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }

    init(cells: [Cell], columns: Int) {
        self.cells = cells
        rows = (cells.count + columns - 1) / columns
        let widest = cells.map { ($0.title as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)]).width }.max() ?? 0
        // Check mark, image, gap, title, trailing padding — like a menu item.
        columnWidth = ceil(22 + 12 + 6 + widest + 24)
        super.init(frame: NSRect(x: 0, y: 0, width: columnWidth * CGFloat(columns) + inset * 2, height: rowHeight * CGFloat(rows)))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    private func rect(of index: Int) -> NSRect {
        NSRect(x: inset + CGFloat(index / rows) * columnWidth, y: CGFloat(index % rows) * rowHeight,
               width: columnWidth, height: rowHeight)
    }

    private func index(at point: NSPoint) -> Int? {
        cells.indices.first { rect(of: $0).contains(point) }
    }

    override func mouseMoved(with event: NSEvent) { hovered = index(at: convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { hovered = nil }

    override func mouseUp(with event: NSEvent) {
        guard let index = index(at: convert(event.locationInWindow, from: nil)) else { return }
        enclosingMenuItem?.menu?.cancelTracking()
        let action = cells[index].action
        DispatchQueue.main.async { action() }
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, cell) in cells.enumerated() {
            let frame = rect(of: index)
            let isHovered = index == hovered
            if isHovered {
                NSColor.selectedContentBackgroundColor.setFill()
                NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6).fill()
            }
            let textColor: NSColor = isHovered ? .selectedMenuItemTextColor : .labelColor
            if cell.isChecked {
                let check = NSAttributedString(string: "✓", attributes: [.font: font, .foregroundColor: textColor])
                check.draw(at: NSPoint(x: frame.minX + 8, y: frame.midY - check.size().height / 2))
            }
            cell.image?.draw(in: NSRect(x: frame.minX + 22, y: frame.midY - 6, width: 12, height: 12),
                             from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            let title = NSAttributedString(string: cell.title, attributes: [.font: font, .foregroundColor: textColor])
            title.draw(at: NSPoint(x: frame.minX + 40, y: frame.midY - title.size().height / 2))
        }
    }
}

private struct CursorPositionLabel: View {
    @ObservedObject var status: EditorStatus
    
    var body: some View {
        ZStack(alignment: .leading) {
            Text("Ln 00, Col 00").hidden()
            Text("Ln \(status.cursorLine), Col \(status.cursorColumn)")
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundColor(.secondary)
        .fixedSize()
    }
}

private struct TextStatsLabel: View {
    @ObservedObject var status: EditorStatus
    
    var body: some View {
        HStack(spacing: 8) {
            BarStat(value: status.lines, label: "ln", reservedDigits: 2)
            BarStat(value: status.words, label: "wd", reservedDigits: 2)
            BarStat(value: status.chars, label: "ch", reservedDigits: 2)
        }
        .fixedSize()
    }
}

// MARK: - Shortcuts Popover

private struct ShortcutsPopover: View {
    private let sections: [(title: String, shortcuts: [(keys: String, action: String)])] = [
        ("General", [
            ("⌘ K  ⌘ ⇧ P", "Command palette"),
            ("⌘ S",        "Save to clipboard"),
            ("⌘ ↩",        "Save and paste into previous app"),
            ("⌘ N",        "New scratch pad"),
            ("Esc  ⌘ W",   "Hide editor"),
            ("⌥ ⌘ W",      "Discard and hide editor"),
        ]),
        ("Editing", [
            ("⌘ Z",        "Undo"),
            ("⌘ ⇧ Z",      "Redo"),
            ("⌘ /",        "Toggle comment"),
            ("⌘ ⇧ D",      "Duplicate line"),
            ("⌘ ⇧ K",      "Delete line"),
            ("⌥ ↑",        "Move line up"),
            ("⌥ ↓",        "Move line down"),
            ("⌘ ⌫",        "Delete to line start"),
            ("Tab",        "Indent"),
            ("⇧ Tab",      "Unindent"),
            ("⌘ ]",        "Indent lines"),
            ("⌘ [",        "Outdent lines"),
        ]),
        ("Selection", [
            ("⌘ A",        "Select all"),
            ("⌘ L",        "Select line"),
            ("⌘ D",        "Select next occurrence"),
            ("⌃ ⌘ G",      "Select all occurrences"),
            ("⌥ ⇧ ↑",      "Expand selection"),
            ("⌥ ⇧ ↓",      "Shrink selection"),
        ]),
        ("Find & Navigate", [
            ("⌘ F",        "Find & replace"),
            ("⌘ G",        "Find next"),
            ("⌘ ⇧ G",      "Find previous"),
            ("⌘ E",        "Use selection for find"),
            ("⌃ G",        "Go to line"),
        ]),
        ("View", [
            ("⌘ =",        "Increase font size"),
            ("⌘ −",        "Decrease font size"),
            ("⌘ 0",        "Reset font size"),
            ("⌥ ⌘ =",      "Increase window size"),
            ("⌥ ⌘ −",      "Decrease window size"),
            ("⌥ Z",        "Toggle word wrap"),
            ("⌥ ⌘ P",      "Presentation mode"),
        ]),
        ("Folding & JSON", [
            ("⌥ ⌘ ←",      "Fold block"),
            ("⌥ ⌘ →",      "Unfold block"),
            ("⌥ ⇧ ⌘ ←",    "Fold all"),
            ("⌥ ⇧ ⌘ →",    "Unfold all"),
            ("⌥ ⇧ ⌘ C",    "Copy JSON path"),
        ]),
        ("Transform", [
            ("⌘ T",        "Open Transform menu"),
            ("⌘ ⇧ F",      "Format code"),
            ("⌘ ⇧ T",      "Trim whitespace"),
            ("⌘ ⇧ L",      "Lowercase"),
            ("⌘ ⇧ U",      "Uppercase"),
            ("⌘ ⇧ N",      "Normalize indentation"),
        ]),
    ]
    
    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(sections, id: \.title) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.title)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(AppTheme.tealSUI)
                            .textCase(.uppercase)
                        
                        // The list is static, so position is a stable identity (actions and keys can repeat).
                        ForEach(section.shortcuts.indices, id: \.self) { index in
                            let shortcut = section.shortcuts[index]
                            HStack(spacing: 0) {
                                Text(shortcut.action)
                                    .font(.callout)
                                    .foregroundColor(.primary)
                                Spacer()
                                Text(shortcut.keys)
                                    .font(.callout.monospaced())
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Color(nsColor: AppTheme.controlBG), in: RoundedRectangle(cornerRadius: 5))
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 280, height: 520)
    }
}

struct EditorView_Previews: PreviewProvider {
    static var previews: some View {
        EditorView(viewModel: EditorViewModel(), onSave: {}, onClose: {})
    }
}
