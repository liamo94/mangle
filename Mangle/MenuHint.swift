import AppKit

/// A short explanation beside a status menu item, shown after a pause. Replaces `toolTip`,
/// which appears almost at once in menus and can't be styled.
final class MenuHintPanel {
    private static let delay: TimeInterval = 0.8
    private static let maxTextWidth: CGFloat = 220

    private let panel: NSPanel
    private let background = NSVisualEffectView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private var timer: Timer?

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false

        background.material = .menu
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.separatorColor.cgColor

        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.isSelectable = false
        background.addSubview(label)
        panel.contentView = background
    }

    /// Shows `text` beside the open menu after a pause, or straight away when moving from
    /// one hinted item to another.
    func schedule(_ text: String) {
        timer?.invalidate()
        if panel.isVisible {
            show(text)
            return
        }
        let timer = Timer(timeInterval: Self.delay, repeats: false) { [weak self] _ in self?.show(text) }
        // Menus track the mouse in their own run loop mode.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        panel.orderOut(nil)
    }

    private func show(_ text: String) {
        guard let menu = RecentPreviewPanel.menuWindows().max(by: { $0.frame.maxY < $1.frame.maxY }) else { return }
        label.stringValue = text
        let padding = NSSize(width: 10, height: 7)
        let textSize = label.sizeThatFits(NSSize(width: Self.maxTextWidth, height: .greatestFiniteMagnitude))
        let size = NSSize(width: ceil(textSize.width) + padding.width * 2, height: ceil(textSize.height) + padding.height * 2)
        label.frame = NSRect(x: padding.width, y: padding.height, width: ceil(textSize.width), height: ceil(textSize.height))
        panel.setFrame(NSRect(origin: origin(for: size, beside: menu), size: size), display: true)
        panel.orderFront(nil)
    }

    /// Beside the menu, level with the pointer (the highlighted item), on whichever side fits.
    private func origin(for size: NSSize, beside menuWindow: NSWindow) -> NSPoint {
        let gap: CGFloat = 6
        let menu = menuWindow.frame
        let screen = (menuWindow.screen ?? NSScreen.main)?.visibleFrame ?? menu
        var x = menu.maxX + gap
        if x + size.width > screen.maxX { x = menu.minX - gap - size.width }
        x = min(max(x, screen.minX), screen.maxX - size.width)
        let mouseY = NSEvent.mouseLocation.y
        let centerY = (menu.minY...menu.maxY).contains(mouseY) ? mouseY : menu.maxY - size.height / 2
        let y = min(max(centerY - size.height / 2, screen.minY), screen.maxY - size.height)
        return NSPoint(x: x, y: y)
    }
}
