import SwiftUI
import Carbon
import Combine
import ServiceManagement
import Highlightr

// Shortcut configuration
struct KeyboardShortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    
    var displayString: String {
        var parts: [String] = []
        
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        
        if let keyString = keyCodeToString(keyCode) {
            parts.append(keyString)
        }
        
        return parts.joined()
    }
    
    /// Lowercase character for use with NSMenuItem.keyEquivalent
    var keyEquivalent: String {
        keyCodeToString(keyCode)?.lowercased() ?? ""
    }
    
    /// NSEvent modifier flags for use with NSMenuItem.keyEquivalentModifierMask
    var cocoaModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        return flags
    }
    
    private func keyCodeToString(_ keyCode: UInt32) -> String? {
        let keyMap: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
            38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
            45: "N", 46: "M", 47: ".", 50: "`", 65: ".", 67: "*", 69: "+",
            71: "Clear", 75: "/", 76: "Enter", 78: "-", 81: "=",
            82: "0", 83: "1", 84: "2", 85: "3", 86: "4", 87: "5",
            88: "6", 89: "7", 91: "8", 92: "9",
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
            101: "F9", 103: "F11", 105: "F13", 107: "F14", 109: "F10",
            111: "F12", 113: "F15", 118: "F4", 119: "F2", 120: "F1",
            121: "F16", 122: "F17", 123: "←", 124: "→", 125: "↓", 126: "↑"
        ]
        return keyMap[keyCode]
    }
}

/// Whether the app follows the system's light/dark setting or forces one.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var id: String { rawValue }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

class SettingsManager: ObservableObject {
    static let shared = SettingsManager()
    
    @Published var editorShortcut: KeyboardShortcut
    @Published var historyShortcut: KeyboardShortcut
    @Published var scratchShortcut: KeyboardShortcut
    @Published var fontSize: CGFloat {
        didSet {
            UserDefaults.standard.set(Double(fontSize), forKey: fontSizeKey)
        }
    }
    /// Font size while presenting — zooming in presentation mode changes this, not `fontSize`.
    @Published var presentationFontSize: CGFloat {
        didSet {
            UserDefaults.standard.set(Double(presentationFontSize), forKey: presentationFontSizeKey)
        }
    }
    /// Presentation mode switches to an accessible high-contrast syntax theme.
    @Published var presentationHighContrast: Bool {
        didSet {
            UserDefaults.standard.set(presentationHighContrast, forKey: presentationHighContrastKey)
        }
    }
    /// Line numbers stay visible while presenting (off by default, for a cleaner slide).
    @Published var presentationLineNumbers: Bool {
        didSet {
            UserDefaults.standard.set(presentationLineNumbers, forKey: presentationLineNumbersKey)
        }
    }
    @Published var pauseHistory: Bool {
        didSet {
            UserDefaults.standard.set(pauseHistory, forKey: pauseHistoryKey)
        }
    }
    /// Most unpinned entries to keep; 0 keeps everything.
    @Published var maxHistory: Int {
        didSet {
            UserDefaults.standard.set(maxHistory, forKey: maxHistoryKey)
        }
    }
    @Published var tabSize: Int {
        didSet {
            UserDefaults.standard.set(tabSize, forKey: tabSizeKey)
        }
    }
    @Published var wordWrap: Bool {
        didSet {
            UserDefaults.standard.set(wordWrap, forKey: wordWrapKey)
        }
    }
    @Published var editorFont: EditorFont {
        didSet {
            UserDefaults.standard.set(editorFont.rawValue, forKey: editorFontKey)
        }
    }
    /// Default indentation for documents whose own indentation can't be detected.
    @Published var useTabs: Bool {
        didSet {
            UserDefaults.standard.set(useTabs, forKey: useTabsKey)
        }
    }
    /// Pressing ⌘C twice quickly in any app opens the editor with what was copied.
    @Published var doubleCopyOpensEditor: Bool {
        didSet {
            UserDefaults.standard.set(doubleCopyOpensEditor, forKey: doubleCopyKey)
        }
    }
    @Published var appearance: AppAppearance {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: appearanceKey)
            applyAppearance()
        }
    }
    @Published var darkTheme: String {
        didSet {
            UserDefaults.standard.set(darkTheme, forKey: darkThemeKey)
        }
    }
    @Published var lightTheme: String {
        didSet {
            UserDefaults.standard.set(lightTheme, forKey: lightThemeKey)
        }
    }
    
    static let defaultDarkTheme = "atom-one-dark"
    static let defaultLightTheme = "xcode"
    static let defaultPresentationFontSize: CGFloat = 24
    static let presentationFontSizeRange: ClosedRange<CGFloat> = 14...72
    
    func themeName(isDark: Bool, presenting: Bool = false) -> String {
        if presenting, presentationHighContrast {
            let name = isDark ? "a11y-dark" : "a11y-light"
            if ThemeCatalog.names.contains(name) { return name }
        }
        return isDark ? darkTheme : lightTheme
    }

    /// Every window, and so every syntax theme, follows the app's appearance.
    func applyAppearance() {
        NSApp.appearance = appearance.nsAppearance
    }

    var onShortcutsChanged: (() -> Void)?

    private let editorKey = "EditorShortcut"
    private let historyKey = "HistoryShortcut"
    private let scratchKey = "ScratchShortcut"
    private let presentationFontSizeKey = "PresentationFontSize"
    private let presentationHighContrastKey = "PresentationHighContrast"
    private let presentationLineNumbersKey = "PresentationLineNumbers"
    private let pauseHistoryKey = "PauseHistory"
    private let fontSizeKey = "EditorFontSize"
    private let maxHistoryKey = "MaxHistory"
    private let tabSizeKey = "TabSize"
    private let wordWrapKey = "WordWrap"
    private let editorFontKey = "EditorFontName"
    private let useTabsKey = "UseTabs"
    private let doubleCopyKey = "DoubleCopyOpensEditor"
    private let appearanceKey = "Appearance"
    private let darkThemeKey = "DarkTheme"
    private let lightThemeKey = "LightTheme"

    init() {
        // Default: Ctrl+Cmd+E for editor
        let defaultEditor = KeyboardShortcut(keyCode: 14, modifiers: UInt32(controlKey | cmdKey))
        // Default: Ctrl+Cmd+H for history
        let defaultHistory = KeyboardShortcut(keyCode: 4, modifiers: UInt32(controlKey | cmdKey))
        // Default: Ctrl+Cmd+N for a new scratch pad
        let defaultScratch = KeyboardShortcut(keyCode: 45, modifiers: UInt32(controlKey | cmdKey))
        
        if let data = UserDefaults.standard.data(forKey: editorKey),
           let shortcut = try? JSONDecoder().decode(KeyboardShortcut.self, from: data) {
            editorShortcut = shortcut
        } else {
            editorShortcut = defaultEditor
        }
        
        if let data = UserDefaults.standard.data(forKey: historyKey),
           let shortcut = try? JSONDecoder().decode(KeyboardShortcut.self, from: data) {
            historyShortcut = shortcut
        } else {
            historyShortcut = defaultHistory
        }
        
        if let data = UserDefaults.standard.data(forKey: scratchKey),
           let shortcut = try? JSONDecoder().decode(KeyboardShortcut.self, from: data) {
            scratchShortcut = shortcut
        } else {
            scratchShortcut = defaultScratch
        }
        
        pauseHistory = UserDefaults.standard.bool(forKey: pauseHistoryKey)
        
        let storedFontSize = UserDefaults.standard.double(forKey: fontSizeKey)
        fontSize = storedFontSize > 0 ? CGFloat(storedFontSize) : NSFont.systemFontSize
        let storedPresentationSize = UserDefaults.standard.double(forKey: presentationFontSizeKey)
        presentationFontSize = storedPresentationSize > 0 ? CGFloat(storedPresentationSize) : Self.defaultPresentationFontSize
        presentationHighContrast = UserDefaults.standard.object(forKey: presentationHighContrastKey) as? Bool ?? true
        presentationLineNumbers = UserDefaults.standard.bool(forKey: presentationLineNumbersKey)
        
        // Absent means never set (default 100); a stored 0 means unlimited.
        maxHistory = UserDefaults.standard.object(forKey: "MaxHistory") == nil
            ? 100 : max(0, UserDefaults.standard.integer(forKey: "MaxHistory"))
        
        let storedTabSize = UserDefaults.standard.integer(forKey: "TabSize")
        tabSize = storedTabSize > 0 ? storedTabSize : 4

        wordWrap = UserDefaults.standard.object(forKey: "WordWrap") as? Bool ?? true

        let storedFontName = UserDefaults.standard.string(forKey: "EditorFontName")
        editorFont = storedFontName.map(EditorFont.init(rawValue:)) ?? .system
        
        useTabs = UserDefaults.standard.bool(forKey: "UseTabs")
        doubleCopyOpensEditor = UserDefaults.standard.object(forKey: "DoubleCopyOpensEditor") as? Bool ?? true
        appearance = UserDefaults.standard.string(forKey: appearanceKey).flatMap(AppAppearance.init(rawValue:)) ?? .system
        darkTheme = UserDefaults.standard.string(forKey: "DarkTheme") ?? Self.defaultDarkTheme
        lightTheme = UserDefaults.standard.string(forKey: "LightTheme") ?? Self.defaultLightTheme
    }
    
    func save() {
        if let data = try? JSONEncoder().encode(editorShortcut) {
            UserDefaults.standard.set(data, forKey: editorKey)
        }
        if let data = try? JSONEncoder().encode(historyShortcut) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
        if let data = try? JSONEncoder().encode(scratchShortcut) {
            UserDefaults.standard.set(data, forKey: scratchKey)
        }
        onShortcutsChanged?()
    }
}

struct ShortcutRecorder: View {
    let title: String
    @Binding var shortcut: KeyboardShortcut
    @State private var isRecording = false
    
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button(action: { isRecording = true }) {
                Text(isRecording ? "Press shortcut..." : shortcut.displayString)
                    .frame(minWidth: 100)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .background(
                ShortcutCaptureView(isRecording: $isRecording, shortcut: $shortcut)
            )
        }
    }
}

// NSView wrapper to capture key events
struct ShortcutCaptureView: NSViewRepresentable {
    @Binding var isRecording: Bool
    @Binding var shortcut: KeyboardShortcut
    
    func makeNSView(context: Context) -> ShortcutCaptureNSView {
        let view = ShortcutCaptureNSView()
        view.onShortcutCaptured = { keyCode, modifiers in
            shortcut = KeyboardShortcut(keyCode: keyCode, modifiers: modifiers)
            isRecording = false
        }
        view.onCancel = {
            isRecording = false
        }
        return view
    }
    
    func updateNSView(_ nsView: ShortcutCaptureNSView, context: Context) {
        if isRecording {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }
}

class ShortcutCaptureNSView: NSView {
    var onShortcutCaptured: ((UInt32, UInt32) -> Void)?
    var onCancel: (() -> Void)?
    
    override var acceptsFirstResponder: Bool { true }
    
    override func keyDown(with event: NSEvent) {
        // Escape cancels
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        
        // Require at least Cmd or Ctrl modifier
        let flags = event.modifierFlags
        guard flags.contains(.command) || flags.contains(.control) else {
            return
        }
        
        var carbonModifiers: UInt32 = 0
        if flags.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }
        if flags.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if flags.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        
        onShortcutCaptured?(UInt32(event.keyCode), carbonModifiers)
    }
}

/// Highlightr's bundled syntax themes, read once.
enum ThemeCatalog {
    private static let highlightr = Highlightr()
    private static var backgrounds: [String: NSColor] = [:]

    static let names: [String] = {
        guard let h = highlightr else { return [SettingsManager.defaultDarkTheme, SettingsManager.defaultLightTheme] }
        return h.availableThemes().sorted()
    }()

    /// A theme's background colour, read once per theme.
    static func background(_ name: String) -> NSColor? {
        if let cached = backgrounds[name] { return cached }
        let color = highlightr?.backgroundColor(ofTheme: name)
        backgrounds[name] = color
        return color
    }
    
    static func displayName(_ name: String) -> String {
        name.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

struct SettingsView: View {
    @ObservedObject var settings = SettingsManager.shared
    // Pop-up buttons keep the title color they were drawn with when the appearance flips,
    // leaving dark text on a dark button, so they're rebuilt per color scheme.
    @Environment(\.colorScheme) private var colorScheme
    
    @State private var editorShortcut: KeyboardShortcut
    @State private var historyShortcut: KeyboardShortcut
    @State private var scratchShortcut: KeyboardShortcut
    @State private var showClearConfirm = false
    @State private var maxHistory: Int
    /// The limit field's text, kept to digits. Separate from `maxHistory` so the field can be
    /// empty mid-edit; it snaps back to the saved limit when editing ends.
    @State private var limitText: String
    /// The limit to restore when Unlimited is switched back off.
    @State private var lastLimit: Int
    @FocusState private var limitFocused: Bool
    // Edited locally and applied on Save, so Cancel discards them like it does the shortcuts.
    @State private var pauseHistory: Bool
    @State private var tabSize: Int
    @State private var editorFont: EditorFont
    @State private var useTabs: Bool
    @State private var doubleCopyOpensEditor: Bool
    @State private var appearance: AppAppearance
    @State private var darkTheme: String
    @State private var lightTheme: String
    @State private var presentationHighContrast: Bool
    @State private var presentationLineNumbers: Bool
    /// Which theme the preview shows: the last one picked, else the one for the current appearance.
    @State private var previewDark: Bool?
    
    init() {
        let settings = SettingsManager.shared
        _editorShortcut = State(initialValue: settings.editorShortcut)
        _historyShortcut = State(initialValue: settings.historyShortcut)
        _scratchShortcut = State(initialValue: settings.scratchShortcut)
        _maxHistory = State(initialValue: settings.maxHistory)
        let limit = settings.maxHistory > 0 ? settings.maxHistory : 100
        _limitText = State(initialValue: String(limit))
        _lastLimit = State(initialValue: limit)
        _pauseHistory = State(initialValue: settings.pauseHistory)
        _tabSize = State(initialValue: settings.tabSize)
        _editorFont = State(initialValue: settings.editorFont)
        _useTabs = State(initialValue: settings.useTabs)
        _doubleCopyOpensEditor = State(initialValue: settings.doubleCopyOpensEditor)
        _appearance = State(initialValue: settings.appearance)
        _darkTheme = State(initialValue: settings.darkTheme)
        _lightTheme = State(initialValue: settings.lightTheme)
        _presentationHighContrast = State(initialValue: settings.presentationHighContrast)
        _presentationLineNumbers = State(initialValue: settings.presentationLineNumbers)
    }
    
    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 10) {
                Image("MenuBarIcon")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 32, height: 32)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Mangle")
                        .font(.title3.weight(.semibold))
                    if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                        Text("Version \(version)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 20) {
                    section("Keyboard Shortcuts", caption: "Click a shortcut and press a new key combination. Must include ⌘ or ⌃. Press Esc to cancel.") {
                        HStack {
                            Text("Press ⌘C Twice to Edit")
                            Spacer()
                            Toggle("", isOn: $doubleCopyOpensEditor)
                                .labelsHidden()
                        }
                        .help("Copy, then press ⌘C again quickly to open the copied text in the editor. Requires Accessibility access.")
                        Divider()
                        ShortcutRecorder(title: "Edit Selection or Clipboard", shortcut: $editorShortcut)
                        ShortcutRecorder(title: "Open History", shortcut: $historyShortcut)
                        ShortcutRecorder(title: "Open Scratch Pad", shortcut: $scratchShortcut)
                    }
                    
                    section("General") {
                        HStack {
                            Text("Launch at Login")
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { SMAppService.mainApp.status == .enabled },
                                set: { newValue in
                                    do {
                                        if newValue {
                                            try SMAppService.mainApp.register()
                                        } else {
                                            try SMAppService.mainApp.unregister()
                                        }
                                    } catch {
                                        // login item update failed — silently ignore
                                    }
                                }
                            ))
                            .labelsHidden()
                        }
                        
                        Divider()
                        
                        HStack {
                            Text("Pause History")
                            Spacer()
                            Toggle("", isOn: $pauseHistory)
                                .labelsHidden()
                        }
                        
                        Divider()
                        
                        HStack {
                            Text("Unlimited History")
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { maxHistory == 0 },
                                set: { maxHistory = $0 ? 0 : lastLimit }
                            ))
                            .labelsHidden()
                        }
                        .help("Keep every entry. Pinned entries are always kept.")
                        
                        if maxHistory > 0 {
                            HStack {
                                Text("History Limit")
                                Spacer()
                                // Text, not a number format: those only commit on Return, so a
                                // typed value could be lost by clicking Save.
                                TextField("", text: $limitText)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 70)
                                    .focused($limitFocused)
                                    .onChange(of: limitText) { _, text in
                                        // Digits only: no minus signs, decimals or letters.
                                        let digits = String(text.filter { $0.isASCII && $0.isNumber }.prefix(9))
                                        if digits != text { limitText = digits; return }
                                        if let n = Int(digits), n > 0 { maxHistory = n }
                                    }
                                    // An empty field or 0 isn't a limit; show the one in effect.
                                    .onChange(of: limitFocused) { _, focused in
                                        if !focused { limitText = String(maxHistory) }
                                    }
                                    .onSubmit { limitText = String(maxHistory) }
                                Stepper("", value: $maxHistory, in: 1...999_999_999, step: 50)
                                    .labelsHidden()
                                Text("entries")
                                    .foregroundColor(.secondary)
                            }
                            .help("Oldest unpinned entries are dropped past this. Type any number from 1 up.")
                            .onChange(of: maxHistory) { _, limit in
                                guard limit > 0 else { return }
                                lastLimit = limit
                                // The stepper changed it; keep the field in step.
                                if Int(limitText) != limit { limitText = String(limit) }
                            }
                        }
                        
                        Divider()
                        
                        HStack {
                            Text("Clear History")
                            Spacer()
                            Button("Clear") {
                                showClearConfirm = true
                            }
                            .alert("Clear History", isPresented: $showClearConfirm) {
                                Button("Cancel", role: .cancel) {}
                                Button("Clear", role: .destructive) {
                                    NotificationCenter.default.post(name: .clearHistory, object: nil)
                                }
                            } message: {
                                Text("This will permanently delete all clipboard history.")
                            }
                        }
                    }
                }
                
                VStack(spacing: 20) {
                    section("Editor") {
                        HStack {
                            Text("Font")
                            Spacer()
                            FontPopUp(selection: $editorFont)
                                .frame(width: 160)
                            .id(colorScheme)
                        }
                        
                        Divider()
                        
                        HStack {
                            Text("Appearance")
                            Spacer()
                            TealSegmentedPicker(selection: $appearance, options: AppAppearance.allCases.map { ($0, $0.rawValue) })
                                .frame(width: 200)
                            // Previewed straight away; Save keeps it, and Cancel or closing reverts.
                            .onChange(of: appearance) {
                                NSApp.appearance = appearance.nsAppearance
                                previewDark = nil
                            }
                        }
                        
                        Divider()
                        
                        HStack {
                            Text("Dark Theme")
                            Spacer()
                            themePicker($darkTheme)
                                .onChange(of: darkTheme) { previewDark = true }
                        }
                        
                        Divider()
                        
                        HStack {
                            Text("Light Theme")
                            Spacer()
                            themePicker($lightTheme)
                                .onChange(of: lightTheme) { previewDark = false }
                        }
                        
                        let showDark = previewDark ?? (colorScheme == .dark)
                        ThemePreview(theme: showDark ? darkTheme : lightTheme, font: editorFont)
                            .help("Preview of the \(showDark ? "dark" : "light") theme")
                        
                        Divider()
                        
                        HStack {
                            Text("High Contrast When Presenting")
                            Spacer()
                            Toggle("", isOn: $presentationHighContrast)
                                .labelsHidden()
                        }
                        .help("Presentation mode (⌥⌘P) switches to an accessible high-contrast theme")
                        
                        Divider()
                        
                        HStack {
                            Text("Line Numbers When Presenting")
                            Spacer()
                            Toggle("", isOn: $presentationLineNumbers)
                                .labelsHidden()
                        }
                        .help("Keep line numbers in presentation mode (⌥⌘P), so the audience can refer to them")
                    }
                    
                    section("Default Indentation", caption: "Used for new documents and text whose indentation can't be detected. Change a document's own indentation from the bottom bar.") {
                        HStack {
                            Text("Indent Width")
                            Spacer()
                            TealSegmentedPicker(selection: $tabSize, options: [(2, "2"), (4, "4")])
                                .frame(width: 140)
                        }
                        
                        Divider()
                        
                        HStack {
                            Text("Indent With Tabs")
                            Spacer()
                            Toggle("", isOn: $useTabs)
                                .labelsHidden()
                        }
                    }
                }
            }
            
            HStack {
                Spacer()
                
                Button("Cancel") {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.escape, modifiers: [])
                
                Button("Save") {
                    settings.editorShortcut = editorShortcut
                    settings.historyShortcut = historyShortcut
                    settings.scratchShortcut = scratchShortcut
                    settings.maxHistory = maxHistory
                    settings.pauseHistory = pauseHistory
                    settings.tabSize = tabSize
                    settings.editorFont = editorFont
                    settings.useTabs = useTabs
                    settings.doubleCopyOpensEditor = doubleCopyOpensEditor
                    settings.appearance = appearance
                    settings.darkTheme = darkTheme
                    settings.lightTheme = lightTheme
                    settings.presentationHighContrast = presentationHighContrast
                    settings.presentationLineNumbers = presentationLineNumbers
                    settings.save()
                    // Apply a lowered limit now rather than on the next copy.
                    AppDelegate.shared?.historyManager.enforceLimit(save: true)
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(TealProminentButtonStyle())
            }
        }
        .padding()
        .frame(width: 720)
        .tint(AppTheme.tealSUI)
        .toggleStyle(TealCheckboxStyle())
    }
    
    /// A titled card of rows, with an optional caption under it.
    private func section<Content: View>(_ title: String, caption: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            VStack(spacing: 12) {
                content()
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: AppTheme.controlBG))
            .cornerRadius(8)
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    
    private func themePicker(_ selection: Binding<String>) -> some View {
        Picker("", selection: selection) {
            ForEach(ThemeCatalog.names, id: \.self) { name in
                Text(ThemeCatalog.displayName(name)).tag(name)
            }
        }
        .labelsHidden()
        .frame(width: 180)
        .id(colorScheme)
    }
}

/// A short code sample drawn in a syntax theme, so themes can be compared without opening the editor.
struct ThemePreview: View {
    var theme: String
    var font: EditorFont
    
    // Highlightr spins up a JavaScript context, so one is shared by every preview.
    private static let highlightr = Highlightr()
    private static let sample = """
    // Greet everyone on the list
    func greet(_ names: [String]) -> Int {
        for name in names {
            print("Hello, \\(name)!")
        }
        return names.count * 42
    }
    """
    
    var body: some View {
        let (code, background) = render()
        AttributedLabel(text: code)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: background), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
    }
    
    private func render() -> (NSAttributedString, NSColor) {
        guard let highlightr = Self.highlightr else {
            return (NSAttributedString(string: Self.sample), .textBackgroundColor)
        }
        highlightr.setTheme(to: theme)
        highlightr.theme.setCodeFont(font.nsFont(size: 11))
        let code = highlightr.highlight(Self.sample, as: "swift") ?? NSAttributedString(string: Self.sample)
        return (code, highlightr.theme.themeBackgroundColor ?? .textBackgroundColor)
    }
}

/// Shows an attributed string with its AppKit colors, which SwiftUI's `Text` drops.
private struct AttributedLabel: NSViewRepresentable {
    var text: NSAttributedString
    
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.isSelectable = false
        field.lineBreakMode = .byClipping
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    
    func updateNSView(_ field: NSTextField, context: Context) {
        field.attributedStringValue = text
    }
}

// MARK: - Teal Controls
// The system draws white text and checkmarks on a tinted fill, which only reaches ~2:1
// contrast on teal, so the teal controls here draw their own with `AppTheme.onTeal`.

/// A segmented control whose selected segment is teal with dark text.
struct TealSegmentedPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .foregroundColor(selected ? AppTheme.onTealSUI : .primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                        .background(selected ? AppTheme.tealSUI : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }
}

/// A checkbox that fills teal with a dark checkmark when on.
struct TealCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(configuration.isOn ? AppTheme.tealSUI : Color.primary.opacity(0.1))
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.primary.opacity(configuration.isOn ? 0 : 0.2), lineWidth: 0.5)
                    if configuration.isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(AppTheme.onTealSUI)
                    }
                }
                .frame(width: 16, height: 16)
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

/// The default-action button: teal with dark text.
struct TealProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(AppTheme.onTealSUI)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(AppTheme.tealSUI.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// The font picker, with each font's name drawn in that font. (SwiftUI's menu picker draws
/// every item in the menu font.)
private struct FontPopUp: NSViewRepresentable {
    @Binding var selection: EditorFont

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        // A saved font that's since been uninstalled stays listed (drawn in the fallback).
        let fonts = EditorFont.allCases.contains(selection) ? EditorFont.allCases : EditorFont.allCases + [selection]
        if button.itemArray.compactMap({ $0.representedObject as? String }) != fonts.map(\.rawValue) {
            button.removeAllItems()
            for (index, font) in fonts.enumerated() {
                button.addItem(withTitle: font.label)
                let item = button.lastItem
                item?.attributedTitle = NSAttributedString(string: font.label, attributes: [.font: font.nsFont(size: 13)])
                item?.representedObject = font.rawValue
                // The system font apart from the installed ones.
                if index == 0, fonts.count > 1 { button.menu?.addItem(.separator()) }
            }
        }
        if button.selectedItem?.representedObject as? String != selection.rawValue {
            button.select(button.itemArray.first { $0.representedObject as? String == selection.rawValue })
        }
    }

    final class Coordinator: NSObject {
        var parent: FontPopUp
        init(_ parent: FontPopUp) { self.parent = parent }

        @objc func changed(_ sender: NSPopUpButton) {
            guard let raw = sender.selectedItem?.representedObject as? String else { return }
            parent.selection = EditorFont(rawValue: raw)
        }
    }
}
