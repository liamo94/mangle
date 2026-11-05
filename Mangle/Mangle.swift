import SwiftUI
import AppKit
import Carbon
import Combine
import UniformTypeIdentifiers

@main
struct MangleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            // ⌘, would otherwise open this empty placeholder scene, behind the floating editor.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { appDelegate.showSettings() }
                    .keyboardShortcut(",")
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    static weak var shared: AppDelegate?
    var editorWindow: NSWindow?
    var historyWindow: NSWindow?
    var settingsWindow: NSWindow?
    var hotKeyRef: EventHotKeyRef?
    var historyHotKeyRef: EventHotKeyRef?
    var scratchHotKeyRef: EventHotKeyRef?
    var editorViewModel = EditorViewModel()
    var historyManager = HistoryManager()
    private let recentPreview = RecentPreviewPanel()
    private let menuHint = MenuHintPanel()
    private weak var recentMenu: NSMenu?
    var statusItem: NSStatusItem?
    var eventHandlerInstalled = false
    /// Handles keys pressed in History; set by `HistoryView`. Returns nil when handled.
    var historyKeyHandler: ((NSEvent) -> NSEvent?)?
    var keyEventMonitor: Any?
    var clipboardChangeCountOnHide: Int = 0
    /// The app that was frontmost when the editor/history opened — Save & Paste returns to it,
    /// and so does focus when the last Mangle window hides.
    private var previousApp: NSRunningApplication?
    /// Keeps the editor's title in step with what it's showing.
    private var titleObserver: AnyCancellable?
    /// What's on disk for each document (nil = no file), so unchanged drafts aren't rewritten
    /// every time the app loses focus.
    private var writtenEditDraft: EditorDraft?
    private var writtenScratchDraft: EditorDraft?
    private static let editorSizeKey = "EditorWindowSize"
    private static let historySizeKey = "HistoryWindowSize"
    private static let takeOverNotification = Notification.Name("liamo.co.mangle.takeOver")
    /// Global monitor for the ⌘C ⌘C trigger (see `updateDoubleCopyMonitor`).
    private var doubleCopyMonitor: Any?
    private var lastCopyPress: Date = .distantPast
    /// The editor's frame before presentation mode enlarged it.
    private var frameBeforePresenting: NSRect?
    /// Runs once the editor has left full screen (see `exitFullScreen(then:)`).
    private var afterFullScreenExit: (() -> Void)?
    /// Between windowWillEnterFullScreen and its did/didFail. A toggle sent then can be ignored,
    /// so an exit asked for meanwhile waits for the window to arrive.
    private var isEnteringFullScreen = false
    private static let editorCollectionBehavior: NSWindow.CollectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        SettingsManager.shared.applyAppearance()

        // Two copies (say an Xcode build and the installed app) both receive the global
        // hotkeys, so each would open its own editor. The newest launch takes over — but only
        // once the old copy has exited, so its unsaved draft and history are on disk before
        // we read them and its hotkeys are free to register.
        // The sandbox blocks the quit Apple Event behind `terminate()`, so the request goes
        // out as a distributed notification that every copy listens for.
        let ownPID = String(ProcessInfo.processInfo.processIdentifier)
        // Only a newer copy of this same app wins, so two launched together (login item and a
        // manual open) don't quit each other.
        DistributedNotificationCenter.default().addObserver(forName: Self.takeOverNotification, object: nil, queue: .main) { note in
            guard let sender = (note.object as? String).flatMap(pid_t.init),
                  let other = NSRunningApplication(processIdentifier: sender),
                  other.bundleIdentifier == Bundle.main.bundleIdentifier,
                  Self.launched(.current, before: other) else { return }
            NSApp.terminate(nil)
        }
        let others = Bundle.main.bundleIdentifier.map {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0)
                .filter { $0 != NSRunningApplication.current }
        } ?? []
        guard !others.isEmpty else {
            finishLaunching()
            return
        }
        DistributedNotificationCenter.default().postNotificationName(Self.takeOverNotification, object: ownPID, userInfo: nil, deliverImmediately: true)
        others.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(3)
        func waitForExit() {
            if others.allSatisfy(\.isTerminated) || Date() >= deadline {
                historyManager.reload()
                finishLaunching()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { waitForExit() }
            }
        }
        waitForExit()
    }

    /// Launch order, with the process ID breaking a tie (or a missing launch date).
    private static func launched(_ a: NSRunningApplication, before b: NSRunningApplication) -> Bool {
        if let dateA = a.launchDate, let dateB = b.launchDate, dateA != dateB { return dateA < dateB }
        return a.processIdentifier < b.processIdentifier
    }

    private func finishLaunching() {
        // Unsaved text from the previous run goes straight back into the two documents; the
        // next hotkey press brings it back under the same rules as a hidden editor.
        let drafts = EditorDraft.load()
        writtenEditDraft = drafts.edit
        writtenScratchDraft = drafts.scratch
        if let edit = drafts.edit {
            editorViewModel.set(edit.buffer, scratch: false)
            editorViewModel.origin = .restored
            clipboardChangeCountOnHide = edit.clipboardChangeCount
        }
        if let scratch = drafts.scratch {
            editorViewModel.set(scratch.buffer, scratch: true)
        }
        
        // Setup settings callback
        SettingsManager.shared.onShortcutsChanged = { [weak self] in
            self?.reregisterHotkeys()
            self?.updateMenuShortcuts()
            self?.updateDoubleCopyMonitor()
        }
        
        // Listen for clear-history requests from Settings UI
        NotificationCenter.default.addObserver(
            self, selector: #selector(clearHistory),
            name: .clearHistory, object: nil
        )
        
        // Register global hotkeys
        registerGlobalHotkey()
        updateDoubleCopyMonitor()
        
        // Create menu bar icon
        setupMenuBar()
        
        // History's keys (see `HistoryView.handleKey`).
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.historyWindow, event.window === window,
                  let handler = self.historyKeyHandler else { return event }
            return handler(event)
        }
        
        // Hide editor/history when user switches to another app
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidResignActive),
            name: NSApplication.didResignActiveNotification, object: nil
        )
        
        // Register with macOS Accessibility. The prompt call triggers the OS dialog (which adds Mangle
        // to the Settings list). The AX read attempt below also forces TCC registration even if the
        // dialog is suppressed. Both are safe no-ops when permission is already granted.
        let axOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(axOptions)
        let sysEl = AXUIElementCreateSystemWide()
        var _unused: CFTypeRef?
        AXUIElementCopyAttributeValue(sysEl, kAXFocusedApplicationAttribute as CFString, &_unused)
        
        // Hide dock icon for a cleaner utility app experience
        NSApp.setActivationPolicy(.accessory)
        
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        historyManager.flush()
        saveDraft()
        if let monitor = doubleCopyMonitor {
            NSEvent.removeMonitor(monitor)
            doubleCopyMonitor = nil
        }
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
    }
    
    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            if let img = NSImage(named: "MenuBarIcon") {
                img.isTemplate = true
                img.size = NSSize(width: 18, height: 18)
                button.image = img
            } else {
                button.image = NSImage(systemSymbolName: "curlybraces", accessibilityDescription: "Mangle")
            }
        }
        
        updateMenuShortcuts()
    }
    
    func updateMenuShortcuts() {
        let menu = NSMenu()
        menu.delegate = self
        
        let settings = SettingsManager.shared
        
        let editorItem = NSMenuItem(title: "Edit Selection or Clipboard", action: #selector(showEditorFromMenu), keyEquivalent: settings.editorShortcut.keyEquivalent)
        editorItem.keyEquivalentModifierMask = settings.editorShortcut.cocoaModifiers
        // A hint shown by `menuHint` (see `menu(_:willHighlight:)`).
        editorItem.representedObject = "Opens the text selected in the front app, or the clipboard if nothing is selected."
        menu.addItem(editorItem)
        
        let scratchItem = NSMenuItem(title: "Open Scratch Pad", action: #selector(showScratch), keyEquivalent: settings.scratchShortcut.keyEquivalent)
        scratchItem.keyEquivalentModifierMask = settings.scratchShortcut.cocoaModifiers
        scratchItem.representedObject = "A notepad for your own notes. It keeps its text between uses."
        menu.addItem(scratchItem)
        
        let historyItem = NSMenuItem(title: "Open History", action: #selector(showHistory), keyEquivalent: settings.historyShortcut.keyEquivalent)
        historyItem.keyEquivalentModifierMask = settings.historyShortcut.cocoaModifiers
        menu.addItem(historyItem)
        
        // Filled in each time it opens (see `menuNeedsUpdate`).
        let recentMenu = NSMenu(title: "Copy Recent")
        recentMenu.delegate = self
        self.recentMenu = recentMenu
        let recentItem = NSMenuItem(title: "Copy Recent", action: nil, keyEquivalent: "")
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        
        statusItem?.menu = menu
    }
    
    /// The Copy Recent submenu: the first few snippets, in History's order.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        let entries = historyManager.entries
        let ordered = entries.filter(\.isPinned) + entries.filter { !$0.isPinned }
        guard !ordered.isEmpty else {
            let empty = NSMenuItem(title: "No Snippets Yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        let font = SettingsManager.shared.editorFont.nsFont(size: 12)
        for (index, entry) in ordered.prefix(9).enumerated() {
            let meta = historyManager.meta(for: entry)
            var title = meta.preview
            if title.count > 40 { title = String(title.prefix(39)) + "…" }
            if title.isEmpty { title = "(whitespace)" }
            // Unmodified digits work while the submenu is open, like History's ⌘1…⌘9.
            let item = NSMenuItem(title: title, action: #selector(copyRecent(_:)), keyEquivalent: "\(index + 1)")
            item.keyEquivalentModifierMask = []
            item.attributedTitle = NSAttributedString(string: title, attributes: [.font: font])
            item.subtitle = recentSubtitle(entry, meta: meta)
            item.target = self
            item.representedObject = entry.id
            item.image = recentIcon(entry, meta: meta)
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem.separator())
        let all = NSMenuItem(title: "Show All…", action: #selector(showHistory), keyEquivalent: "")
        all.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        all.target = self
        menu.addItem(all)
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        if let hint = item?.representedObject as? String {
            menuHint.schedule(hint)
        } else {
            menuHint.hide()
        }
        guard let id = item?.representedObject as? UUID,
              let entry = historyManager.entries.first(where: { $0.id == id }) else {
            recentPreview.hide()
            return
        }
        let language = entry.language ?? historyManager.meta(for: entry).detectedLanguage
        // The submenu opens level with its item, so its top is below the top of the menu it came from.
        let submenu = RecentPreviewPanel.menuWindows().min { $0.frame.maxY < $1.frame.maxY }
        recentPreview.show(entry, language: language, beside: submenu)
    }
    
    func menuDidClose(_ menu: NSMenu) {
        recentPreview.hide()
        menuHint.hide()
    }
    
    /// "2m ago · Swift · 12 lines", matching History's rows.
    private func recentSubtitle(_ entry: HistoryEntry, meta: HistoryEntryMeta) -> String {
        var parts = [formatRelativeDate(entry.timestamp)]
        let language = entry.language ?? meta.detectedLanguage
        if language != "plaintext" { parts.append(EditorView.languageLabel(language)) }
        parts.append(meta.lines == 1 ? "1 line" : "\(meta.lines) lines")
        return parts.joined(separator: " · ")
    }

    /// A pin for pinned snippets, otherwise the language's dot (grey for plain text).
    private func recentIcon(_ entry: HistoryEntry, meta: HistoryEntryMeta) -> NSImage? {
        if entry.isPinned {
            let pin = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")
            return pin?.withSymbolConfiguration(.init(paletteColors: [AppTheme.teal]))
        }
        let language = entry.language ?? meta.detectedLanguage
        let color = language == "plaintext" ? NSColor.tertiaryLabelColor : NSColor(EditorView.languageColor(language))
        return NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.midX - 4, y: rect.midY - 4, width: 8, height: 8)).fill()
            return true
        }
    }
    
    @objc private func copyRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let entry = historyManager.entries.first(where: { $0.id == id }) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
        showToast("Copied to clipboard")
    }
    
    @objc func showEditorFromMenu() {
        showEditor(fromMenu: true)
    }
    
    // MARK: - Opening and hiding
    
    /// The scratch shortcut: shows the scratch pad as you left it (blank the first time).
    /// Pressed while it's frontmost, it hides; pressed over the edit, it switches to it.
    @objc func showScratch() {
        let vm = editorViewModel
        if editorWindow?.isKeyWindow == true {
            if vm.isScratch {
                dismissEditor()
            } else {
                vm.show(scratch: true)
                focusEditorTextView()
            }
            return
        }
        rememberFrontmostApp()
        let anchor = visibleWindowFrame()
        closeHistory()
        vm.show(scratch: true)
        presentEditorWindow(replacing: anchor)
    }
    
    /// ⌘N: a blank scratch pad, keeping the current one's unsaved text in history.
    func newScratch() {
        let scratch = editorViewModel.buffer(scratch: true)
        if scratch.isDirty { stash(scratch.text, isScratch: true) }
        editorViewModel.loadScratch()
        presentEditorWindow(replacing: visibleWindowFrame())
    }
    
    /// Shows `text` as the edit document, keeping an unsaved edit it replaces in history.
    /// (The scratch pad is a separate document, so it's untouched.)
    private func openEdit(_ text: String, origin: EditorOrigin, language: String? = nil,
                          sourceEntryID: UUID? = nil, replacing anchor: NSRect?) {
        let edit = editorViewModel.buffer(scratch: false)
        if edit.isDirty { stash(edit.text, isScratch: false) }
        editorViewModel.load(text, language: language)
        editorViewModel.sourceEntryID = sourceEntryID
        editorViewModel.origin = origin
        presentEditorWindow(replacing: anchor)
    }
    
    /// Brings back the edit document as it was left. (Undo history only survives when the
    /// edit was still on screen, not when it was parked behind the scratch pad.)
    private func resumeEdit(replacing anchor: NSRect?) {
        if editorViewModel.buffer(scratch: false).isDirty { editorViewModel.origin = .restored }
        editorViewModel.show(scratch: false)
        presentEditorWindow(replacing: anchor)
    }
    
    /// Saves text that's about to be replaced to history, so starting something new never
    /// loses work.
    private func stash(_ text: String, isScratch: Bool) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if SettingsManager.shared.pauseHistory {
            showToast("History is paused — previous text not kept")
            return
        }
        historyManager.addEntry(text, isScratch: isScratch)
        showToast(isScratch ? "Scratch saved to History" : "Previous edit saved to History")
    }
    
    /// ⌥⌘W: throws away the document on screen and hides the editor. Unsaved text still
    /// goes to history first — ⌥⌘W is also "Close All", so it's easy to press by habit.
    /// Unlike Esc, it doesn't return to History when the edit came from there.
    func discardDocument() {
        let current = editorViewModel.buffer(scratch: editorViewModel.isScratch)
        if current.isDirty { stash(current.text, isScratch: editorViewModel.isScratch) }
        closeHistory()
        dismissEditor()
        editorViewModel.discard()
    }
    
    /// Hides the editor at the user's request (Esc, ⌘W, the close button, the hotkey again).
    func dismissEditor() {
        closeEditor()
        returnFocusIfIdle()
    }
    
    /// Once no Mangle window is showing, hands focus back to the app the user came from —
    /// otherwise Mangle stays active with nothing to type into until they click somewhere.
    private func returnFocusIfIdle() {
        DispatchQueue.main.async { [self] in
            guard NSApp.isActive,
                  ![editorWindow, historyWindow, settingsWindow].contains(where: { $0?.isVisible == true }) else { return }
            if let app = previousApp, !app.isTerminated {
                app.activate()
            } else {
                NSApp.hide(nil)
            }
        }
    }
    
    // MARK: - Presentation mode
    
    /// Large text and minimal chrome for showing something to others. The window grows to
    /// most of the screen and stays up when another app is clicked.
    func togglePresentation() {
        guard let window = editorWindow else { return }
        if editorViewModel.isPresenting {
            endPresentation(animate: true)
            return
        }
        frameBeforePresenting = window.frame
        editorViewModel.isPresenting = true
        // Normal level so the app being demoed can come in front; the editor stays behind it
        // rather than hiding, and the hotkey brings it back.
        window.level = .normal
        let screen = (window.screen ?? screenAtCursor()).visibleFrame
        let size = NSSize(width: (screen.width * 0.8).rounded(), height: (screen.height * 0.85).rounded())
        let frame = NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height)
        window.setFrame(frame, display: true, animate: true)
    }
    
    /// Grows (+1) or shrinks (-1) the editor by a tenth around its centre, kept on screen.
    /// Steps double and skip the animation while the key is held.
    func resizeEditor(by direction: CGFloat, held: Bool) {
        guard let window = editorWindow, !window.styleMask.contains(.fullScreen), !isEnteringFullScreen else { return }
        let screen = (window.screen ?? screenAtCursor()).visibleFrame
        let scale = 1 + direction * (held ? 0.2 : 0.1)
        let old = window.frame
        let size = NSSize(width: min(max(old.width * scale, 400), screen.width).rounded(),
                          height: min(max(old.height * scale, 300), screen.height).rounded())
        var frame = NSRect(x: old.midX - size.width / 2, y: old.midY - size.height / 2, width: size.width, height: size.height)
        frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - frame.width).rounded()
        frame.origin.y = min(max(frame.minY, screen.minY), screen.maxY - frame.height).rounded()
        window.setFrame(frame, display: true, animate: !held)
        rememberSize(of: window, key: Self.editorSizeKey)
    }
    
    private func endPresentation(animate: Bool) {
        guard editorViewModel.isPresenting else { return }
        if exitFullScreen(then: { [weak self] in self?.endPresentation(animate: animate) }) { return }
        editorViewModel.isPresenting = false
        editorWindow?.level = .floating
        if let frame = frameBeforePresenting, let window = editorWindow {
            window.setFrame(frame, display: true, animate: animate && window.isVisible)
        }
        frameBeforePresenting = nil
    }
    
    /// While presenting: native full screen, filling the display on its own Space with the
    /// menu bar and Dock out of the way.
    func togglePresentationFullScreen() {
        guard let window = editorWindow, editorViewModel.isPresenting, afterFullScreenExit == nil, !isEnteringFullScreen else { return }
        // Full screen needs a primary window; the editor is normally auxiliary, so it can
        // open over other apps' full-screen Spaces.
        if !window.styleMask.contains(.fullScreen) { window.collectionBehavior = [.fullScreenPrimary] }
        window.toggleFullScreen(nil)
    }
    
    /// Leaves full screen and runs `then` once the window is back in place. False (and
    /// `then` isn't run) when the editor isn't full screen. Asked again mid-exit (Esc twice,
    /// Esc then ⌘W), it queues `then` rather than toggling back into full screen. Asked while
    /// entering, it leaves once the window has arrived.
    private func exitFullScreen(then: @escaping () -> Void) -> Bool {
        if let pending = afterFullScreenExit {
            afterFullScreenExit = { pending(); then() }
            return true
        }
        guard let window = editorWindow, isEnteringFullScreen || window.styleMask.contains(.fullScreen) else { return false }
        afterFullScreenExit = then
        if !isEnteringFullScreen { window.toggleFullScreen(nil) }
        return true
    }
    
    func windowWillEnterFullScreen(_ notification: Notification) {
        guard notification.object as? NSWindow === editorWindow else { return }
        isEnteringFullScreen = true
    }
    
    func windowDidEnterFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === editorWindow else { return }
        isEnteringFullScreen = false
        if afterFullScreenExit != nil { window.toggleFullScreen(nil) }
    }
    
    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        guard window === editorWindow else { return }
        isEnteringFullScreen = false
        window.collectionBehavior = Self.editorCollectionBehavior
        let then = afterFullScreenExit
        afterFullScreenExit = nil
        then?()
    }
    
    func windowDidExitFullScreen(_ notification: Notification) {
        guard notification.object as? NSWindow === editorWindow else { return }
        editorWindow?.collectionBehavior = Self.editorCollectionBehavior
        let then = afterFullScreenExit
        afterFullScreenExit = nil
        then?()
    }
    
    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        guard window === editorWindow else { return }
        let then = afterFullScreenExit
        afterFullScreenExit = nil
        then?()
    }
    
    @objc func appDidResignActive() {
        clipboardChangeCountOnHide = NSPasteboard.general.changeCount
        rememberSize(of: editorWindow, key: Self.editorSizeKey)
        rememberSize(of: historyWindow, key: Self.historySizeKey)
        // While presenting, clicking another app (to run a demo) mustn't hide the editor.
        if !editorViewModel.isPresenting { editorWindow?.orderOut(nil) }
        historyWindow?.orderOut(nil)
        saveDraft()
    }
    
    // MARK: - ⌘C ⌘C trigger
    
    /// Installs or removes the global key monitor for ⌘C ⌘C. Global monitors only see
    /// other apps' key events and only receive them once Accessibility access is granted,
    /// which the app already asks for — no extra permission needed.
    func updateDoubleCopyMonitor() {
        let enabled = SettingsManager.shared.doubleCopyOpensEditor
        if enabled, doubleCopyMonitor == nil {
            doubleCopyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handleGlobalKeyDown(event)
            }
        } else if !enabled, let monitor = doubleCopyMonitor {
            NSEvent.removeMonitor(monitor)
            doubleCopyMonitor = nil
        }
        // A monitor installed before Accessibility was granted may never receive events;
        // once access arrives, reinstall it.
        if enabled, !AXIsProcessTrusted() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                if AXIsProcessTrusted() {
                    if let monitor = self.doubleCopyMonitor { NSEvent.removeMonitor(monitor) }
                    self.doubleCopyMonitor = nil
                }
                self.updateDoubleCopyMonitor()
            }
        }
    }
    
    private static let doubleCopyInterval: TimeInterval = 0.4
    /// Marks the ⌘C the editor hotkey posts, so the double-copy monitor doesn't count it.
    private static let syntheticEventTag: Int64 = 0x4D616E67
    
    private func handleGlobalKeyDown(_ event: NSEvent) {
        if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventTag {
            lastCopyPress = .distantPast
            return
        }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        // Match the character, not the key code, so ⌘C works on non-QWERTY layouts.
        guard mods == .command, !event.isARepeat,
              event.charactersIgnoringModifiers?.lowercased() == "c" else {
            lastCopyPress = .distantPast
            return
        }
        let now = Date()
        if now.timeIntervalSince(lastCopyPress) <= Self.doubleCopyInterval {
            lastCopyPress = .distantPast   // a third press starts a new pair
            openEditorFromDoubleCopy()
        } else {
            lastCopyPress = now
        }
    }
    
    /// The second ⌘C is still being handled by the source app, so wait (briefly) for the
    /// pasteboard to update before reading it.
    private func openEditorFromDoubleCopy() {
        let pasteboard = NSPasteboard.general
        let changeCountAtPress = pasteboard.changeCount
        let deadline = Date().addingTimeInterval(0.15)
        func finish() {
            guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
                showToast("Nothing to edit — copy some text first")
                return
            }
            rememberFrontmostApp()
            let anchor = visibleWindowFrame()
            closeHistory()
            openEdit(text, origin: .clipboard, replacing: anchor)
        }
        func poll() {
            if pasteboard.changeCount != changeCountAtPress || Date() >= deadline {
                finish()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { poll() }
            }
        }
        poll()
    }
    
    private func rememberFrontmostApp() {
        if let app = NSWorkspace.shared.frontmostApplication, app != NSRunningApplication.current {
            previousApp = app
        }
    }
    
    /// Persists both documents so they survive quitting: the edit while it's unsaved, the
    /// scratch pad while it has anything in it.
    private func saveDraft() {
        let vm = editorViewModel
        let edit = vm.buffer(scratch: false)
        let editDraft = edit.isDirty && !edit.text.isEmpty
            ? EditorDraft(edit, clipboardChangeCount: clipboardChangeCountOnHide, isScratch: false) : nil
        if editDraft != writtenEditDraft {
            if let editDraft { editDraft.save() } else { EditorDraft.clear(scratch: false) }
            writtenEditDraft = editDraft
        }
        let scratch = vm.buffer(scratch: true)
        // The scratch pad's draft doesn't use the clipboard count, so leave it out of the
        // comparison — otherwise every copy elsewhere would rewrite it.
        let scratchDraft = scratch.text.isEmpty ? nil : EditorDraft(scratch, clipboardChangeCount: 0, isScratch: true)
        if scratchDraft != writtenScratchDraft {
            if let scratchDraft { scratchDraft.save() } else { EditorDraft.clear(scratch: true) }
            writtenScratchDraft = scratchDraft
        }
    }
    
    @objc func clearHistory() {
        historyManager.clearHistory()
    }
    
    @objc func showSettings() {
        if exitFullScreen(then: { [weak self] in self?.showSettings() }) { return }
        closeEditor()
        closeHistory()
        
        if let window = settingsWindow {
            // Fresh view each time so edits abandoned with Cancel don't linger in @State.
            let screen = screenAtCursor()
            window.setContentSize(settingsContentSize(on: screen))
            window.contentView = NSHostingView(rootView: ScrollView { SettingsView() })
            SettingsManager.shared.applyAppearance()
            centerWindow(window, on: screen)
            bringSettingsForward(window)
        } else {
            createSettingsWindow()
        }
    }
    
    /// Activates Mangle before ordering front: `NSApp.activate(ignoringOtherApps:)` has no
    /// effect on macOS 14+, which left a reopened Settings behind the frontmost app.
    private func bringSettingsForward(_ window: NSWindow) {
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        window.makeKeyAndOrderFront(nil)
    }
    
    /// Fits the Settings content, but leaves it to scroll rather than run off a short screen.
    private func settingsContentSize(on screen: NSScreen) -> NSSize {
        let fitting = NSHostingView(rootView: SettingsView()).fittingSize
        return NSSize(width: fitting.width, height: min(fitting.height, screen.visibleFrame.height - 40))
    }
    
    func createSettingsWindow() {
        let screen = screenAtCursor()
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: settingsContentSize(on: screen)),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        
        centerWindow(window, on: screen)
        window.title = "Mangle Settings"
        window.backgroundColor = AppTheme.windowBG
        // Let the title bar show the background colour instead of the system's lighter one.
        window.titlebarAppearsTransparent = true
        window.contentView = NSHostingView(rootView: ScrollView { SettingsView() })
        window.isReleasedWhenClosed = false
        // Like the editor: open on the current Space (or over a full-screen app), not the
        // Space Settings was last shown on.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // Settings previews the appearance before Save; closing any other way drops the preview.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            SettingsManager.shared.applyAppearance()
        }
        
        self.settingsWindow = window
        bringSettingsForward(window)
    }
    
    func registerGlobalHotkey() {
        // Only install the event handler once
        if !eventHandlerInstalled {
            var eventType = EventTypeSpec()
            eventType.eventClass = OSType(kEventClassKeyboard)
            eventType.eventKind = OSType(kEventHotKeyPressed)
            
            InstallEventHandler(
                GetApplicationEventTarget(),
                { (nextHandler, theEvent, userData) -> OSStatus in
                    var hotKeyID = EventHotKeyID()
                    GetEventParameter(theEvent,
                                      EventParamName(kEventParamDirectObject),
                                      EventParamType(typeEventHotKeyID),
                                      nil,
                                      MemoryLayout<EventHotKeyID>.size,
                                      nil,
                                      &hotKeyID)
                    
                    let appDelegate = Unmanaged<AppDelegate>.fromOpaque(userData!).takeUnretainedValue()
                    
                    if hotKeyID.id == 1 {
                        appDelegate.showEditor()
                    } else if hotKeyID.id == 2 {
                        appDelegate.showHistory()
                    } else if hotKeyID.id == 3 {
                        appDelegate.showScratch()
                    }
                    
                    return noErr
                },
                1,
                &eventType,
                Unmanaged.passUnretained(self).toOpaque(),
                nil
            )
            eventHandlerInstalled = true
        }
        
        registerHotkeys()
    }
    
    func reregisterHotkeys() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let ref = historyHotKeyRef {
            UnregisterEventHotKey(ref)
            historyHotKeyRef = nil
        }
        if let ref = scratchHotKeyRef {
            UnregisterEventHotKey(ref)
            scratchHotKeyRef = nil
        }
        registerHotkeys()
    }
    
    private func registerHotkeys() {
        let settings = SettingsManager.shared
        
        var hotKeyID1 = EventHotKeyID()
        hotKeyID1.signature = OSType("QEDT".fourCharCodeValue)
        hotKeyID1.id = 1
        let status1 = RegisterEventHotKey(settings.editorShortcut.keyCode, settings.editorShortcut.modifiers, hotKeyID1, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status1 != noErr {
            DispatchQueue.main.async { self.showToast("⚠️ Edit Selection shortcut conflict") }
        }
        
        var hotKeyID2 = EventHotKeyID()
        hotKeyID2.signature = OSType("HIST".fourCharCodeValue)
        hotKeyID2.id = 2
        let status2 = RegisterEventHotKey(settings.historyShortcut.keyCode, settings.historyShortcut.modifiers, hotKeyID2, GetApplicationEventTarget(), 0, &historyHotKeyRef)
        if status2 != noErr {
            DispatchQueue.main.async { self.showToast("⚠️ History shortcut conflict") }
        }
        
        var hotKeyID3 = EventHotKeyID()
        hotKeyID3.signature = OSType("SCRT".fourCharCodeValue)
        hotKeyID3.id = 3
        let status3 = RegisterEventHotKey(settings.scratchShortcut.keyCode, settings.scratchShortcut.modifiers, hotKeyID3, GetApplicationEventTarget(), 0, &scratchHotKeyRef)
        if status3 != noErr {
            DispatchQueue.main.async { self.showToast("⚠️ Scratch Pad shortcut conflict") }
        }
    }
    
    /// The history shortcut. Pressed while History is frontmost, it hides it.
    @objc func showHistory() {
        if historyWindow?.isKeyWindow == true {
            closeHistory()
            returnFocusIfIdle()
            return
        }
        // Out of full screen first: hiding the editor there would leave its empty Space behind.
        if exitFullScreen(then: { [weak self] in self?.showHistory() }) { return }
        rememberFrontmostApp()
        closeSettings()
        
        // Leave presentation first, so history takes the editor's normal frame, not the
        // enlarged one — and a hidden editor isn't left in presentation mode.
        endPresentation(animate: false)
        
        let anchor = visibleWindowFrame()
        // Back from editing one of its entries: return to the same list.
        if let hw = historyWindow, editorViewModel.buffer(scratch: false).sourceEntryID != nil {
            editorWindow?.orderOut(nil)
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            hw.makeKeyAndOrderFront(nil)
            if let anchor { place(hw, replacing: anchor) }
            return
        }
        
        // Otherwise start fresh — no leftover search or selection from last time.
        closeHistory()
        closeEditor()
        createHistoryWindow(replacing: anchor)
    }
    
    func createHistoryWindow(replacing anchor: NSRect? = nil) {
        let contentView = HistoryView(
            historyManager: historyManager,
            onSelectEntry: { [weak self] entry in
                self?.loadEntryToEditor(entry)
            },
            onPaste: { [weak self] entry in
                self?.pasteFromHistory(entry)
            },
            onClose: { [weak self] in
                self?.closeHistory()
                self?.returnFocusIfIdle()
            }
        )
        
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: savedSize(key: Self.historySizeKey, default: NSSize(width: 700, height: 500))),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        place(window, replacing: anchor)
        window.title = "History"
        window.backgroundColor = AppTheme.windowBG
        // Let the title bar show the background colour instead of the system's lighter one.
        window.titlebarAppearsTransparent = true
        window.identifier = NSUserInterfaceItemIdentifier("history")
        window.contentView = NSHostingView(rootView: contentView)
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 600, height: 400)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = self
        
        self.historyWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        // Focus the list so first entry is highlighted. Force layout so the SwiftUI List's
        // table exists now; fall back to the next run loop turn if it still doesn't.
        window.contentView?.layoutSubtreeIfNeeded()
        if let tableView = findTableView(in: window.contentView) {
            window.makeFirstResponder(tableView)
        } else {
            DispatchQueue.main.async {
                if let tableView = self.findTableView(in: window.contentView) {
                    window.makeFirstResponder(tableView)
                }
            }
        }
    }
    
    func findSubview<T: NSView>(ofType type: T.Type, in view: NSView?) -> T? {
        guard let view = view else { return nil }
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let found = findSubview(ofType: type, in: subview) {
                return found
            }
        }
        return nil
    }
    
    func findTableView(in view: NSView?) -> NSTableView? {
        findSubview(ofType: NSTableView.self, in: view)
    }
    
    func findTextView(in view: NSView?) -> NSTextView? {
        findSubview(ofType: NSTextView.self, in: view)
    }
    
    func loadEntryToEditor(_ entry: HistoryEntry) {
        // Hide but don't destroy — closing the editor returns here
        let anchor = historyWindow?.frame
        historyWindow?.orderOut(nil)
        openEdit(entry.text, origin: .history, language: entry.language, sourceEntryID: entry.id, replacing: anchor)
    }
    
    /// ⌘↩ / ⌘1–9 in History: pastes the entry into the app the user came from.
    func pasteFromHistory(_ entry: HistoryEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
        closeHistory()
        editorWindow?.orderOut(nil)
        pasteIntoPreviousApp()
    }
    
    func closeHistory() {
        if let window = historyWindow { rememberSize(of: window, key: Self.historySizeKey) }
        historyWindow?.close()
        historyWindow = nil
        historyKeyHandler = nil
        historyManager.forgetDeleted()
    }
    
    /// The editor shortcut: opens the editor on the selection in the frontmost app, or the
    /// clipboard, or brings back the unsaved edit when there's nothing new. Pressed while the
    /// edit is frontmost it hides; over the scratch pad it switches to the edit.
    /// From the menu bar it skips the simulated ⌘C.
    func showEditor(fromMenu: Bool = false) {
        let vm = editorViewModel
        let pasteboard = NSPasteboard.general
        if let window = editorWindow, window.isKeyWindow {
            if !vm.isScratch {
                // The menu item only ever opens; the hotkey toggles.
                if fromMenu { presentEditorWindow(replacing: window.frame) } else { dismissEditor() }
            } else if vm.buffer(scratch: false).text.isEmpty {
                openEdit(pasteboard.string(forType: .string) ?? "", origin: .clipboard, replacing: visibleWindowFrame())
            } else {
                resumeEdit(replacing: visibleWindowFrame())
            }
            return
        }
        // Still on screen behind another app (presentation mode): just bring it forward,
        // rather than replacing what's being presented.
        if let window = editorWindow, window.isVisible {
            presentEditorWindow(replacing: window.frame)
            return
        }
        
        let sourceApp = NSWorkspace.shared.frontmostApplication
        rememberFrontmostApp()
        let anchor = visibleWindowFrame()
        
        // History is frontmost: there's no selection to read, so use the clipboard —
        // or, mid-way through editing one of its entries, go back to that.
        if historyWindow?.isKeyWindow == true {
            if vm.buffer(scratch: false).sourceEntryID != nil {
                historyWindow?.orderOut(nil)
                resumeEdit(replacing: anchor)
            } else {
                closeHistory()
                openEdit(pasteboard.string(forType: .string) ?? "", origin: .clipboard, replacing: anchor)
            }
            return
        }
        closeHistory()
        
        let hasEdit = !vm.buffer(scratch: false).text.isEmpty
        let clipboardChanged = pasteboard.changeCount != clipboardChangeCountOnHide
        let selectionOrigin = EditorOrigin.selection(app: sourceApp == NSRunningApplication.current ? nil : sourceApp?.localizedName)
        
        // Try AX first — instant, no side effects
        if AXIsProcessTrusted(), let selected = selectedTextFromFrontmostApp(), !selected.isEmpty {
            openEdit(selected, origin: selectionOrigin, replacing: anchor)
            return
        }
        
        // Nothing new to read: bring back the unsaved edit unless something's been copied
        // since it was hidden.
        guard AXIsProcessTrusted(), !fromMenu else {
            if hasEdit, !clipboardChanged {
                resumeEdit(replacing: anchor)
            } else {
                openEdit(pasteboard.string(forType: .string) ?? "", origin: .clipboard, replacing: anchor)
            }
            return
        }
        
        // Simulate Cmd+C — this also catches selections in apps that don't expose AX text.
        // What the user had copied is put back afterwards, when it's plain text.
        let previousText = pasteboard.string(forType: .string) ?? ""
        let savedChangeCount = pasteboard.changeCount
        let savedItems = snapshotPasteboard()
        
        let src = CGEventSource(stateID: .hidSystemState)
        let dn = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: true)
        dn?.flags = .maskCommand
        dn?.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventTag)
        let up = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: false)
        up?.flags = .maskCommand
        up?.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventTag)
        dn?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        
        // Poll for the copy to land instead of always waiting the full timeout — most apps
        // write the pasteboard within a few ms, so the editor appears almost immediately.
        let deadline = Date().addingTimeInterval(0.15)
        func finish() {
            let newText = pasteboard.string(forType: .string) ?? ""
            let copied = pasteboard.changeCount != savedChangeCount
            let gotNewText = copied && !newText.isEmpty && newText != previousText
            if copied, !savedItems.isEmpty {
                pasteboard.clearContents()
                pasteboard.writeObjects(savedItems)
            }
            if gotNewText {
                openEdit(newText, origin: selectionOrigin, replacing: anchor)
            } else if hasEdit, !clipboardChanged {
                resumeEdit(replacing: anchor)
            } else {
                openEdit(previousText, origin: .clipboard, replacing: anchor)
            }
        }
        func poll() {
            // Some apps clear the pasteboard and write the text a moment later, so wait until
            // there's actually a string, not just a changeCount bump.
            let copied = pasteboard.changeCount != savedChangeCount && pasteboard.string(forType: .string) != nil
            if copied || Date() >= deadline {
                finish()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { poll() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { poll() }
    }
    
    /// A copy of the pasteboard, so it can be put back after a simulated ⌘C — but only when
    /// it holds nothing but text. Apps like Excel and Photoshop render most of their formats
    /// only when asked, so reading those could stall the hotkey for seconds; then the copy
    /// is left in place instead (empty result).
    private func snapshotPasteboard() -> [NSPasteboardItem] {
        let items = NSPasteboard.general.pasteboardItems ?? []
        let allText = items.allSatisfy { item in
            item.types.allSatisfy { type in
                guard let utType = UTType(type.rawValue) else { return false }
                return utType.conforms(to: .text) || utType.conforms(to: .url)
            }
        }
        guard allText else { return [] }
        return items.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }
    
    /// Reads the selected text from the currently frontmost app via the Accessibility API.
    /// Returns nil if permission hasn't been granted or nothing is selected.
    private func selectedTextFromFrontmostApp() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // AX calls block until the target app answers; a hung app (common with Electron)
        // would otherwise stall the hotkey for the default ~6s timeout.
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        var focusedEl: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedEl) == .success,
              let el = focusedEl else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el as! AXUIElement, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = value as? String, !text.isEmpty else { return nil }
        return text
    }
    
    /// Shows the editor in place of `anchor` (the frame of a Mangle window that was on
    /// screen), or near the cursor when nothing was showing.
    private func presentEditorWindow(replacing anchor: NSRect? = nil) {
        closeSettings()
        
        if let window = editorWindow {
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            window.makeKeyAndOrderFront(nil)
            // Position after makeKeyAndOrderFront so our placement overrides any macOS window restoration
            if !editorViewModel.isPresenting { place(window, replacing: anchor) }
        } else {
            createEditorWindow(replacing: anchor)
        }
        focusEditorTextView()
    }
    
    /// Make the text view first responder right away so the first keystrokes aren't lost.
    /// On first creation the SwiftUI hierarchy may not be built yet, so force a layout pass.
    private func focusEditorTextView() {
        guard let window = editorWindow else { return }
        if editorViewModel.textView == nil { window.contentView?.layoutSubtreeIfNeeded() }
        if let textView = editorViewModel.textView ?? findTextView(in: window.contentView) {
            window.makeFirstResponder(textView)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self, let textView = self.editorViewModel.textView ?? self.findTextView(in: window.contentView) else { return }
                window.makeFirstResponder(textView)
            }
        }
    }
    
    func createEditorWindow(replacing anchor: NSRect? = nil) {
        let contentView = EditorView(viewModel: editorViewModel, onSave: { [weak self] in
            self?.saveToClipboard()
            self?.returnFocusIfIdle()
        }, onSaveAndPaste: { [weak self] in
            self?.saveAndPaste()
        }, onClose: { [weak self] in
            self?.dismissEditor()
        }, onDiscard: { [weak self] in
            self?.discardDocument()
        }, onNewScratch: { [weak self] in
            self?.newScratch()
        }, onTogglePresentation: { [weak self] in
            self?.togglePresentation()
        }, onTogglePresentationFullScreen: { [weak self] in
            self?.togglePresentationFullScreen()
        }, onResizeWindow: { [weak self] direction, held in
            self?.resizeEditor(by: direction, held: held)
        }, onShowHistory: { [weak self] in
            self?.showHistory()
        }, onShowSettings: { [weak self] in
            self?.showSettings()
        })
        
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: savedSize(key: Self.editorSizeKey, default: NSSize(width: 680, height: 480))),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        place(window, replacing: anchor)
        window.identifier = NSUserInterfaceItemIdentifier("editor")
        window.backgroundColor = AppTheme.windowBG
        // Let the title bar show the background colour instead of the system's lighter one.
        window.titlebarAppearsTransparent = true
        window.contentView = NSHostingView(rootView: contentView)
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        // Full-screen auxiliary so it opens over a full-screen app instead of switching Spaces.
        window.collectionBehavior = Self.editorCollectionBehavior
        window.delegate = self
        titleObserver = editorViewModel.$isScratch.combineLatest(editorViewModel.$origin)
            .sink { [weak window] isScratch, origin in
                // Always "Mangle", with where the text came from underneath.
                window?.title = "Mangle"
                window?.subtitle = isScratch ? "Scratch Pad" : origin.title
            }
        
        self.editorWindow = window
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        window.makeKeyAndOrderFront(nil)
    }
    
    /// Copies, closes, then switches back to the app the text came from and pastes it there.
    func saveAndPaste() {
        // Paste only once the editor is out of full screen and hidden, or ⌘V lands mid-transition.
        if exitFullScreen(then: { [weak self] in self?.saveAndPaste() }) { return }
        saveToClipboard(toast: nil)
        pasteIntoPreviousApp()
    }
    
    /// Switches back to the app the user came from and pastes the clipboard there.
    private func pasteIntoPreviousApp() {
        guard let target = previousApp, !target.isTerminated else {
            showToast("Copied to clipboard")
            return
        }
        guard AXIsProcessTrusted() else {
            showToast("Copied — enable Accessibility to paste automatically")
            target.activate()
            return
        }
        target.activate()
        // Wait for the target to actually become frontmost before sending ⌘V, or the
        // keystroke can land in the wrong app.
        let deadline = Date().addingTimeInterval(1.0)
        func attempt() {
            if NSWorkspace.shared.frontmostApplication == target {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    let src = CGEventSource(stateID: .hidSystemState)
                    let down = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
                    down?.flags = .maskCommand
                    let up = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
                    up?.flags = .maskCommand
                    down?.post(tap: .cghidEventTap)
                    up?.post(tap: .cghidEventTap)
                    self?.showToast("Pasted")
                }
            } else if Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { attempt() }
            } else {
                showToast("Copied to clipboard")
            }
        }
        attempt()
    }
    
    func saveToClipboard(toast: String? = "Copied to clipboard") {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(editorViewModel.text, forType: .string)
        
        // Persist manually-set language back to the source history entry
        if let sourceID = editorViewModel.sourceEntryID, editorViewModel.languageIsManual {
            historyManager.updateLanguage(for: sourceID, language: editorViewModel.currentLanguage)
        }
        
        // Save to history (unless paused). Saving an edit of a history entry updates it.
        if !SettingsManager.shared.pauseHistory {
            historyManager.addEntry(editorViewModel.text, isScratch: editorViewModel.isScratch,
                                    replacing: editorViewModel.sourceEntryID)
        }
        
        editorViewModel.sourceEntryID = nil
        editorViewModel.markSaved()
        closeHistory()
        closeEditor()
        saveDraft()
        if let toast { showToast(toast) }
    }
    
    private func screenAtCursor() -> NSScreen {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens[0]
    }
    
    private func centerWindow(_ window: NSWindow, on screen: NSScreen) {
        let sf = screen.visibleFrame
        let wf = window.frame
        window.setFrameOrigin(NSPoint(x: sf.midX - wf.width / 2, y: sf.midY - wf.height / 2))
    }
    
    /// The frame of whichever editor/history window is on screen, so the next one can open
    /// in its place instead of jumping to the cursor.
    private func visibleWindowFrame() -> NSRect? {
        [editorWindow, historyWindow].compactMap { $0 }.first { $0.isVisible }?.frame
    }
    
    /// Puts `window` where `anchor` was (top-left corners aligned, since the windows differ
    /// in size), or near the cursor when there's no anchor.
    private func place(_ window: NSWindow, replacing anchor: NSRect?) {
        guard let anchor else {
            positionWindowNearCursor(window)
            return
        }
        guard anchor != window.frame else { return }
        window.setFrameTopLeftPoint(NSPoint(x: anchor.minX, y: anchor.maxY))
    }
    
    private func positionWindowNearCursor(_ window: NSWindow) {
        let screen = screenAtCursor()
        let cursor = NSEvent.mouseLocation
        // Keep clear of the screen edges (and the menu bar and Dock) rather than opening flush
        // against them. A window too big for the inset area still keeps its top-left on screen.
        let margin: CGFloat = 32
        let sf = screen.visibleFrame.insetBy(dx: margin, dy: margin)
        let wf = window.frame
        let x = max(sf.minX, min(cursor.x - wf.width / 2,  sf.maxX - wf.width))
        let y = min(sf.maxY - wf.height, max(sf.minY, cursor.y - wf.height / 2))
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
    
    func showToast(_ message: String) {
        // Always defer to next run loop so we never trigger NSPanel constraint
        // loops when called from inside a SwiftUI layout pass or button action.
        DispatchQueue.main.async { self._showToast(message) }
    }
    
    private func _showToast(_ message: String) {
        let screen = screenAtCursor()
        
        // Pure AppKit toast — avoids NSHostingView constraint loops in borderless panels.
        let hPad: CGFloat = 12
        let iconSize: CGFloat = 16
        let spacing: CGFloat = 8
        let height: CGFloat = 34
        
        // Size the label from the field itself — measuring the bare string ignores the
        // cell's padding and clips the last character.
        let label = NSTextField(labelWithString: message)
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byClipping
        let labelSize = label.fittingSize
        let width = hPad + iconSize + spacing + ceil(labelSize.width) + hPad
        
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        let container = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.material = .popover
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 9
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = NSColor.separatorColor.cgColor

        // The popover material reads a bit light in dark mode; dim it slightly.
        if container.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            let dim = NSView(frame: container.bounds)
            dim.wantsLayer = true
            dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
            container.addSubview(dim)
        }
        
        let icon = NSImageView(frame: NSRect(x: hPad, y: (height - iconSize) / 2, width: iconSize, height: iconSize))
        if let logo = NSImage(named: "MenuBarIcon")?.copy() as? NSImage {
            logo.isTemplate = true
            icon.image = logo
        }
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = AppTheme.teal
        container.addSubview(icon)
        
        label.frame = NSRect(
            x: hPad + iconSize + spacing,
            y: (height - labelSize.height) / 2,
            width: ceil(labelSize.width),
            height: labelSize.height
        )
        container.addSubview(label)
        
        panel.contentView = container
        // The shadow is computed from the window's opaque pixels; refresh once content is in.
        panel.invalidateShadow()
        
        // Top-right of the editor/history window while one is showing (below its title
        // bar); top-right of the screen otherwise, e.g. after Save has closed the editor.
        let x: CGFloat
        let y: CGFloat
        if let window = [editorWindow, historyWindow].compactMap({ $0 }).first(where: { $0.isVisible }) {
            let margin: CGFloat = 12
            let contentTop = window.frame.minY + window.contentLayoutRect.maxY
            x = window.frame.maxX - width - margin
            y = contentTop - height - margin
        } else {
            let margin: CGFloat = 16
            x = screen.visibleFrame.maxX - width  - margin
            y = screen.visibleFrame.maxY - height - margin
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        
        panel.alphaValue = 0
        panel.orderFront(nil)
        
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.close()
            })
        }
    }
    
    func closeEditor() {
        // Hiding a full-screen window would leave its empty Space behind.
        if exitFullScreen(then: { [weak self] in
            self?.closeEditor()
            self?.returnFocusIfIdle()
        }) { return }
        endPresentation(animate: false)
        let anchor = editorWindow?.isVisible == true ? editorWindow?.frame : nil
        editorWindow?.orderOut(nil)
        // Cancelling an edit ends the history→editor context, so clear the source reference.
        // This ensures the next editor open is treated as fresh (cursor-positioned) rather
        // than a restore, even if historyWindow is still alive but hidden.
        editorViewModel.sourceEntryID = nil
        if let hw = historyWindow {
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            hw.makeKeyAndOrderFront(nil)
            // Back to history in the editor's place, in case the editor was moved.
            if let anchor { place(hw, replacing: anchor) }
        }
    }
    
    func closeSettings() {
        settingsWindow?.close()
    }
    
    // MARK: - Window delegate
    
    /// The close button hides, the same as Esc, rather than closing.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === editorWindow {
            if let requestClose = editorViewModel.requestClose { requestClose() } else { dismissEditor() }
            return false
        }
        if sender === historyWindow {
            closeHistory()
            returnFocusIfIdle()
            return false
        }
        return true
    }
    
    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === editorWindow { rememberSize(of: window, key: Self.editorSizeKey) }
        if window === historyWindow { rememberSize(of: window, key: Self.historySizeKey) }
    }
    
    /// Window sizes (not positions — windows open by the cursor) are kept across launches.
    private func rememberSize(of window: NSWindow?, key: String) {
        guard let window else { return }
        if window === editorWindow, editorViewModel.isPresenting { return }
        UserDefaults.standard.set(NSStringFromSize(window.frame.size), forKey: key)
    }
    
    private func savedSize(key: String, default size: NSSize) -> NSSize {
        guard let string = UserDefaults.standard.string(forKey: key) else { return size }
        let saved = NSSizeFromString(string)
        return saved.width >= 400 && saved.height >= 300 ? saved : size
    }
}

// Helper extension for FourCharCode
extension String {
    var fourCharCodeValue: FourCharCode {
        var result: FourCharCode = 0
        for char in self.utf8 {
            result = (result << 8) + FourCharCode(char)
        }
        return result
    }
}
