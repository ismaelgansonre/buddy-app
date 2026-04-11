import AppKit

class AuthGateWindow: NSWindow {

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // Dark theme matching PetTheme
    private static let paperBg    = NSColor(red: 0.075, green: 0.075, blue: 0.118, alpha: 1)  // #131320
    private static let cardBg     = NSColor(red: 0.118, green: 0.118, blue: 0.176, alpha: 1)  // #1E1E2D
    private static let accent     = NSColor(red: 0.878, green: 0.122, blue: 0.122, alpha: 1)  // #E01F1F Spider-Man red
    private static let inkText    = NSColor(red: 0.906, green: 0.910, blue: 0.945, alpha: 1)  // #E7E8F1
    private static let mutedText  = NSColor(red: 0.906, green: 0.910, blue: 0.945, alpha: 0.5)
    private static let fieldBg    = NSColor(red: 0.118, green: 0.118, blue: 0.176, alpha: 1)  // #1E1E2D
    private static let fieldBorder = NSColor(red: 0.906, green: 0.910, blue: 0.945, alpha: 0.12)
    private static let errorColor = NSColor(red: 1.0, green: 0.4, blue: 0.4, alpha: 1)

    private var actionBtn: NSButton!
    private var statusLabel: NSTextField!
    private var authObserver: Any?

    var onComplete: (() -> Void)?

    init() {
        let frame = NSRect(x: 0, y: 0, width: 400, height: 320)
        super.init(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isMovableByWindowBackground = true
        center()

        let outer = NSView(frame: frame)
        outer.wantsLayer = true
        outer.layer?.backgroundColor = Self.paperBg.cgColor
        outer.layer?.cornerRadius = 16
        outer.layer?.masksToBounds = true
        contentView = outer

        buildUI(in: outer)

        authObserver = NotificationCenter.default.addObserver(
            forName: AuthManager.stateChangedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            if AuthManager.shared.isSignedIn {
                self?.onComplete?()
            }
        }
    }

    deinit {
        if let observer = authObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    static func show(completion: @escaping () -> Void) {
        let win = AuthGateWindow()
        win.onComplete = {
            win.orderOut(nil)
            completion()
        }
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildUI(in outer: NSView) {
        let emoji = makeLabel("🔐", size: 40)
        emoji.frame = NSRect(x: 0, y: 210, width: 400, height: 50)
        emoji.alignment = .center
        outer.addSubview(emoji)

        let titleLabel = makeLabel("Welcome to Buddy", size: 22, weight: .bold)
        titleLabel.alignment = .center
        titleLabel.frame = NSRect(x: 40, y: 170, width: 320, height: 32)
        outer.addSubview(titleLabel)

        let subtitleLabel = makeLabel("Sign in to access free AI chat", size: 13)
        subtitleLabel.textColor = Self.mutedText
        subtitleLabel.alignment = .center
        subtitleLabel.frame = NSRect(x: 40, y: 144, width: 320, height: 20)
        outer.addSubview(subtitleLabel)

        actionBtn = makePrimaryButton("Sign In via Browser")
        actionBtn.frame = NSRect(x: 75, y: 90, width: 250, height: 44)
        actionBtn.target = self
        actionBtn.action = #selector(signInTapped)
        outer.addSubview(actionBtn)

        statusLabel = makeLabel("Opens buddy.artiphik.com in your browser", size: 11)
        statusLabel.textColor = Self.mutedText
        statusLabel.alignment = .center
        statusLabel.frame = NSRect(x: 40, y: 64, width: 320, height: 18)
        outer.addSubview(statusLabel)

        let skipBtn = NSButton()
        skipBtn.isBordered = false
        skipBtn.wantsLayer = true
        skipBtn.attributedTitle = NSAttributedString(
            string: "Skip for now",
            attributes: [
                .font: roundedFont(size: 12, weight: .medium),
                .foregroundColor: Self.mutedText,
            ]
        )
        skipBtn.frame = NSRect(x: 60, y: 28, width: 280, height: 24)
        skipBtn.target = self
        skipBtn.action = #selector(skipTapped)
        outer.addSubview(skipBtn)
    }

    @objc private func signInTapped() {
        AuthManager.shared.signIn()
        statusLabel.stringValue = "Waiting for sign-in..."
        statusLabel.textColor = Self.accent
    }

    @objc private func skipTapped() {
        onComplete?()
    }

    // MARK: - Helpers

    private func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = roundedFont(size: size, weight: weight)
        label.textColor = Self.inkText
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.isBezeled = false
        return label
    }

    private func makePrimaryButton(_ title: String) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 12
        button.layer?.backgroundColor = Self.accent.cgColor

        let style = NSMutableParagraphStyle()
        style.alignment = .center

        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: roundedFont(size: 15, weight: .semibold),
                .foregroundColor: NSColor.white,
                .paragraphStyle: style,
            ]
        )
        return button
    }

    private func roundedFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let systemFont = NSFont.systemFont(ofSize: size, weight: weight)
        if let descriptor = systemFont.fontDescriptor.withDesign(.rounded) {
            return NSFont(descriptor: descriptor, size: size) ?? systemFont
        }
        return systemFont
    }
}

// MARK: - Vertically Centered Text Field Cell

private class AuthGateTextFieldCell: NSTextFieldCell {
    private let horizontalPadding: CGFloat = 10

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var newRect = super.drawingRect(forBounds: rect)
        let textSize = cellSize(forBounds: rect)
        let heightDelta = newRect.height - textSize.height
        if heightDelta > 0 {
            newRect.size.height = textSize.height
            newRect.origin.y += heightDelta / 2
        }
        newRect.origin.x += horizontalPadding
        newRect.size.width -= horizontalPadding * 2
        return newRect
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: drawingRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: drawingRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }
}
