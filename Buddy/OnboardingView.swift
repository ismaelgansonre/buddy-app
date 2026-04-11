import AppKit

// MARK: - OnboardingWindow

class OnboardingWindow: NSWindow {

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // MARK: Theme

    private static let paperBg   = NSColor(red: 0.98, green: 0.96, blue: 0.93, alpha: 1)
    private static let inkText   = NSColor(red: 0.1,  green: 0.08, blue: 0.06, alpha: 1)
    private static let accent    = NSColor(red: 0.843, green: 0.467, blue: 0.341, alpha: 1)
    private static let mutedText = NSColor(red: 0.1,  green: 0.08, blue: 0.06, alpha: 0.5)
    private static let fieldBg   = NSColor(red: 0.96, green: 0.94, blue: 0.90, alpha: 1)
    private static let fieldBorder = NSColor(red: 0.1, green: 0.08, blue: 0.06, alpha: 0.12)

    // MARK: State

    private enum Step: Int, CaseIterable {
        case welcome = 0, auth, nameRole, workStyle, healthGoals, done
    }

    private var currentStep: Step = .welcome
    private var collectedName = ""
    private var collectedRole = ""
    private var collectedWorkStyle: PersonalContext.WorkStyle = .mixed
    private var collectedHealthGoals: Set<String> = []

    var onComplete: (() -> Void)?

    private let containerView = NSView()
    private var stepViews: [Step: NSView] = [:]

    // MARK: Init

    init() {
        let frame = NSRect(x: 0, y: 0, width: 400, height: 500)
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

        containerView.frame = outer.bounds
        containerView.autoresizingMask = [.width, .height]
        outer.addSubview(containerView)

        buildAllSteps()
        showStep(.welcome, animated: false)
    }

    // MARK: Convenience

    static func show(completion: @escaping () -> Void) {
        let win = OnboardingWindow()
        win.onComplete = {
            win.orderOut(nil)
            completion()
        }
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Step Building

    private func buildAllSteps() {
        stepViews[.welcome]     = buildWelcomeStep()
        stepViews[.auth]        = buildAuthStep()
        stepViews[.nameRole]    = buildNameRoleStep()
        stepViews[.workStyle]   = buildWorkStyleStep()
        stepViews[.healthGoals] = buildHealthGoalsStep()
        stepViews[.done]        = buildDoneStep()

        for (_, view) in stepViews {
            view.frame = containerView.bounds
            view.autoresizingMask = [.width, .height]
            view.isHidden = true
            containerView.addSubview(view)
        }
    }

    // MARK: Welcome

    private func buildWelcomeStep() -> NSView {
        let view = NSView()

        let emoji = makeLabel("👋", size: 48, weight: .regular, alignment: .center)
        emoji.frame = NSRect(x: 0, y: 340, width: 400, height: 60)
        view.addSubview(emoji)

        let title = makeLabel("Hey! I'm Buddy.", size: 28, weight: .bold, alignment: .center)
        title.frame = NSRect(x: 40, y: 290, width: 320, height: 40)
        view.addSubview(title)

        let desc = makeLabel(
            "I'm your desktop companion. I'll keep you company while you work, remind you to take breaks, stay hydrated, and help you stay focused.",
            size: 14, weight: .regular, alignment: .center
        )
        desc.textColor = Self.mutedText
        desc.maximumNumberOfLines = 4
        desc.frame = NSRect(x: 50, y: 200, width: 300, height: 80)
        view.addSubview(desc)

        let button = makePrimaryButton("Let's get to know each other")
        button.frame = NSRect(x: 75, y: 120, width: 250, height: 44)
        button.target = self
        button.action = #selector(welcomeNext)
        view.addSubview(button)

        return view
    }

    @objc private func welcomeNext() {
        showStep(.auth, animated: true)
    }

    // MARK: Auth (Magic Link via Browser)

    private var authStatusLabel: NSTextField!
    private var authObserver: Any?

    private func buildAuthStep() -> NSView {
        let view = NSView()

        let emoji = makeLabel("🔐", size: 40, weight: .regular, alignment: .center)
        emoji.frame = NSRect(x: 0, y: 380, width: 400, height: 50)
        view.addSubview(emoji)

        let titleLabel = makeLabel("Sign in to continue", size: 22, weight: .bold, alignment: .center)
        titleLabel.frame = NSRect(x: 40, y: 340, width: 320, height: 32)
        view.addSubview(titleLabel)

        let subtitle = makeLabel("Get 100K free AI tokens daily. No credit card needed.", size: 13, weight: .regular, alignment: .center)
        subtitle.textColor = Self.mutedText
        subtitle.frame = NSRect(x: 40, y: 310, width: 320, height: 20)
        view.addSubview(subtitle)

        let actionBtn = makePrimaryButton("Sign In via Browser")
        actionBtn.frame = NSRect(x: 75, y: 230, width: 250, height: 44)
        actionBtn.target = self
        actionBtn.action = #selector(authSignInTapped)
        view.addSubview(actionBtn)

        authStatusLabel = makeLabel("Opens buddy.artiphik.com in your browser", size: 11, weight: .regular, alignment: .center)
        authStatusLabel.textColor = Self.mutedText
        authStatusLabel.frame = NSRect(x: 40, y: 204, width: 320, height: 18)
        view.addSubview(authStatusLabel)

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
        skipBtn.frame = NSRect(x: 60, y: 160, width: 280, height: 24)
        skipBtn.target = self
        skipBtn.action = #selector(authSkipTapped)
        view.addSubview(skipBtn)

        // Listen for auth state changes
        authObserver = NotificationCenter.default.addObserver(
            forName: AuthManager.stateChangedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            if AuthManager.shared.isSignedIn {
                self?.showStep(.nameRole, animated: true)
            }
        }

        return view
    }

    @objc private func authSignInTapped() {
        AuthManager.shared.signIn()
        authStatusLabel.stringValue = "Waiting for sign-in..."
        authStatusLabel.textColor = Self.accent
    }

    @objc private func authSkipTapped() {
        showStep(.nameRole, animated: true)
    }

    // MARK: Name + Role

    private var nameField: NSTextField!
    private var roleField: NSTextField!

    private func buildNameRoleStep() -> NSView {
        let view = NSView()

        let stepLabel = makeStepLabel("1 of 3")
        view.addSubview(stepLabel)

        let title = makeLabel("What should I call you?", size: 22, weight: .bold, alignment: .center)
        title.frame = NSRect(x: 40, y: 370, width: 320, height: 32)
        view.addSubview(title)

        let nameLabel = makeLabel("Your name", size: 12, weight: .medium, alignment: .left)
        nameLabel.textColor = Self.mutedText
        nameLabel.frame = NSRect(x: 60, y: 330, width: 280, height: 18)
        view.addSubview(nameLabel)

        nameField = makeTextField(placeholder: "e.g. Alex")
        nameField.frame = NSRect(x: 60, y: 292, width: 280, height: 34)
        view.addSubview(nameField)

        let roleLabel = makeLabel("What do you do?", size: 12, weight: .medium, alignment: .left)
        roleLabel.textColor = Self.mutedText
        roleLabel.frame = NSRect(x: 60, y: 256, width: 280, height: 18)
        view.addSubview(roleLabel)

        roleField = makeTextField(placeholder: "e.g. designer, developer, student")
        roleField.frame = NSRect(x: 60, y: 218, width: 280, height: 34)
        view.addSubview(roleField)

        let button = makePrimaryButton("Next")
        button.frame = NSRect(x: 75, y: 140, width: 250, height: 44)
        button.target = self
        button.action = #selector(nameRoleNext)
        view.addSubview(button)

        return view
    }

    @objc private func nameRoleNext() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            shakeField(nameField)
            return
        }
        collectedName = name
        collectedRole = roleField.stringValue.trimmingCharacters(in: .whitespaces)
        showStep(.workStyle, animated: true)
    }

    // MARK: Work Style

    private var workStyleButtons: [PersonalContext.WorkStyle: NSButton] = [:]

    private func buildWorkStyleStep() -> NSView {
        let view = NSView()

        let stepLabel = makeStepLabel("2 of 3")
        view.addSubview(stepLabel)

        let title = makeLabel("How do you usually work?", size: 22, weight: .bold, alignment: .center)
        title.frame = NSRect(x: 40, y: 370, width: 320, height: 32)
        view.addSubview(title)

        let options: [(PersonalContext.WorkStyle, String, String)] = [
            (.deepFocus,  "🎯", "Deep Focus"),
            (.meetings,   "📅", "Lots of Meetings"),
            (.creative,   "🎨", "Creative Work"),
            (.mixed,      "🔀", "Mixed"),
        ]

        let cardW: CGFloat = 150
        let cardH: CGFloat = 64
        let gapX: CGFloat = 16
        let gapY: CGFloat = 12
        let totalW = cardW * 2 + gapX
        let startX = (400 - totalW) / 2
        let startY: CGFloat = 238

        for (i, (style, emoji, label)) in options.enumerated() {
            let col = CGFloat(i % 2)
            let row = CGFloat(i / 2)
            let x = startX + col * (cardW + gapX)
            let y = startY + (1 - row) * (cardH + gapY)

            let button = NSButton(frame: NSRect(x: x, y: y, width: cardW, height: cardH))
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 12
            button.layer?.borderWidth = 2
            button.layer?.borderColor = Self.fieldBorder.cgColor
            button.layer?.backgroundColor = Self.fieldBg.cgColor

            let attrTitle = NSMutableAttributedString()
            attrTitle.append(NSAttributedString(
                string: emoji + " ",
                attributes: [.font: NSFont.systemFont(ofSize: 18)]
            ))
            attrTitle.append(NSAttributedString(
                string: label,
                attributes: [
                    .font: roundedFont(size: 13, weight: .medium),
                    .foregroundColor: Self.inkText
                ]
            ))
            button.attributedTitle = attrTitle

            button.tag = style.hashValue
            button.target = self
            button.action = #selector(workStyleTapped(_:))
            workStyleButtons[style] = button
            view.addSubview(button)
        }

        // Pre-select mixed
        selectWorkStyle(.mixed)

        let button = makePrimaryButton("Next")
        button.frame = NSRect(x: 75, y: 140, width: 250, height: 44)
        button.target = self
        button.action = #selector(workStyleNext)
        view.addSubview(button)

        return view
    }

    @objc private func workStyleTapped(_ sender: NSButton) {
        for (style, btn) in workStyleButtons {
            if btn === sender {
                selectWorkStyle(style)
                return
            }
        }
    }

    private func selectWorkStyle(_ style: PersonalContext.WorkStyle) {
        collectedWorkStyle = style
        for (s, btn) in workStyleButtons {
            if s == style {
                btn.layer?.borderColor = Self.accent.cgColor
                btn.layer?.backgroundColor = Self.accent.withAlphaComponent(0.08).cgColor
            } else {
                btn.layer?.borderColor = Self.fieldBorder.cgColor
                btn.layer?.backgroundColor = Self.fieldBg.cgColor
            }
        }
    }

    @objc private func workStyleNext() {
        showStep(.healthGoals, animated: true)
    }

    // MARK: Health Goals

    private var healthCheckboxes: [String: NSButton] = [:]

    private func buildHealthGoalsStep() -> NSView {
        let view = NSView()

        let stepLabel = makeStepLabel("3 of 3")
        view.addSubview(stepLabel)

        let title = makeLabel("Any health goals?", size: 22, weight: .bold, alignment: .center)
        title.frame = NSRect(x: 40, y: 370, width: 320, height: 32)
        view.addSubview(title)

        let subtitle = makeLabel("I'll send gentle reminders throughout the day.", size: 13, weight: .regular, alignment: .center)
        subtitle.textColor = Self.mutedText
        subtitle.frame = NSRect(x: 40, y: 346, width: 320, height: 20)
        view.addSubview(subtitle)

        let goals: [(String, String)] = [
            ("Drink more water",    "💧"),
            ("Take regular breaks", "⏸️"),
            ("Better posture",      "🧘"),
            ("Move more",           "🏃"),
            ("Reduce eye strain",   "👁️"),
        ]

        let checkH: CGFloat = 36
        let startY: CGFloat = 310 - checkH
        let leftX: CGFloat = 70

        for (i, (goal, emoji)) in goals.enumerated() {
            let y = startY - CGFloat(i) * (checkH + 6)
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(healthGoalToggled(_:)))
            checkbox.frame = NSRect(x: leftX, y: y, width: 280, height: checkH)

            let attr = NSMutableAttributedString()
            attr.append(NSAttributedString(
                string: emoji + "  ",
                attributes: [.font: NSFont.systemFont(ofSize: 16)]
            ))
            attr.append(NSAttributedString(
                string: goal,
                attributes: [
                    .font: roundedFont(size: 14, weight: .regular),
                    .foregroundColor: Self.inkText
                ]
            ))
            checkbox.attributedTitle = attr
            checkbox.identifier = NSUserInterfaceItemIdentifier(goal)
            healthCheckboxes[goal] = checkbox
            view.addSubview(checkbox)
        }

        let button = makePrimaryButton("Finish")
        button.frame = NSRect(x: 75, y: 60, width: 250, height: 44)
        button.target = self
        button.action = #selector(healthGoalsNext)
        view.addSubview(button)

        return view
    }

    @objc private func healthGoalToggled(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        if sender.state == .on {
            collectedHealthGoals.insert(id)
        } else {
            collectedHealthGoals.remove(id)
        }
    }

    @objc private func healthGoalsNext() {
        saveToProfile()
        if let doneView = stepViews[.done] {
            updateDoneStep(in: doneView)
        }
        showStep(.done, animated: true)
    }

    // MARK: Done

    private func buildDoneStep() -> NSView {
        let view = NSView()

        let emoji = makeLabel("🎉", size: 48, weight: .regular, alignment: .center)
        emoji.frame = NSRect(x: 0, y: 340, width: 400, height: 60)
        emoji.identifier = NSUserInterfaceItemIdentifier("done-emoji")
        view.addSubview(emoji)

        let title = makeLabel("Nice to meet you!", size: 28, weight: .bold, alignment: .center)
        title.frame = NSRect(x: 40, y: 290, width: 320, height: 40)
        title.identifier = NSUserInterfaceItemIdentifier("done-title")
        view.addSubview(title)

        let desc = makeLabel(
            "I'm all set. I'll be right here on your desktop whenever you need me.",
            size: 14, weight: .regular, alignment: .center
        )
        desc.textColor = Self.mutedText
        desc.maximumNumberOfLines = 3
        desc.frame = NSRect(x: 50, y: 220, width: 300, height: 60)
        view.addSubview(desc)

        let button = makePrimaryButton("Let's go")
        button.frame = NSRect(x: 75, y: 140, width: 250, height: 44)
        button.target = self
        button.action = #selector(doneTapped)
        view.addSubview(button)

        return view
    }

    private func updateDoneStep(in view: NSView) {
        for subview in view.subviews {
            if subview.identifier?.rawValue == "done-title", let label = subview as? NSTextField {
                label.stringValue = "Nice to meet you, \(collectedName)!"
            }
        }
    }

    @objc private func doneTapped() {
        onComplete?()
    }

    // MARK: - Navigation

    private func showStep(_ step: Step, animated: Bool) {
        let previousStep = currentStep
        currentStep = step

        guard let nextView = stepViews[step] else { return }

        if animated {
            let prevView = stepViews[previousStep]

            nextView.alphaValue = 0
            nextView.isHidden = false
            nextView.frame = containerView.bounds
            // Slide in from the right
            nextView.frame.origin.x = 30

            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                prevView?.animator().alphaValue = 0
                prevView?.animator().frame.origin.x = -30
                nextView.animator().alphaValue = 1
                nextView.animator().frame.origin.x = 0
            }, completionHandler: {
                prevView?.isHidden = true
                prevView?.frame.origin.x = 0
            })
        } else {
            for (_, v) in stepViews {
                v.isHidden = true
            }
            nextView.isHidden = false
            nextView.alphaValue = 1
        }
    }

    // MARK: - Save

    private func saveToProfile() {
        PersonalContext.shared.update { profile in
            profile.name = collectedName
            profile.role = collectedRole
            profile.workStyle = collectedWorkStyle
            profile.healthGoals = Array(collectedHealthGoals)
        }
    }

    // MARK: - UI Helpers

    private func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight, alignment: NSTextAlignment) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = roundedFont(size: size, weight: weight)
        label.textColor = Self.inkText
        label.alignment = alignment
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.isBezeled = false
        return label
    }

    private func makeStepLabel(_ text: String) -> NSTextField {
        let label = makeLabel(text, size: 11, weight: .medium, alignment: .center)
        label.textColor = Self.mutedText
        label.frame = NSRect(x: 0, y: 420, width: 400, height: 16)
        return label
    }

    private func makeTextField(placeholder: String) -> NSTextField {
        let field = NSTextField()
        field.font = roundedFont(size: 14, weight: .regular)
        field.textColor = Self.inkText
        field.placeholderString = placeholder
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = false
        field.wantsLayer = true
        field.layer?.backgroundColor = Self.fieldBg.cgColor
        field.layer?.cornerRadius = 8
        field.layer?.borderWidth = 1
        field.layer?.borderColor = Self.fieldBorder.cgColor

        // Inset the text a bit by using a custom cell
        let cell = VerticallyCenteredTextFieldCell(textCell: "")
        cell.font = field.font
        cell.textColor = field.textColor
        cell.placeholderString = placeholder
        cell.isEditable = true
        cell.isScrollable = true
        field.cell = cell

        return field
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
                .paragraphStyle: style
            ]
        )

        // Hover / press tracking
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: ButtonHoverHandler.shared(for: button, accent: Self.accent),
            userInfo: nil
        )
        button.addTrackingArea(area)

        return button
    }

    private func shakeField(_ field: NSTextField) {
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.duration = 0.4
        animation.values = [0, -8, 8, -6, 6, -3, 3, 0]
        field.layer?.add(animation, forKey: "shake")
        field.layer?.borderColor = Self.accent.cgColor

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak field] in
            field?.layer?.borderColor = Self.fieldBorder.cgColor
        }
    }

    private func roundedFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let systemFont = NSFont.systemFont(ofSize: size, weight: weight)
        if let descriptor = systemFont.fontDescriptor.withDesign(.rounded) {
            return NSFont(descriptor: descriptor, size: size) ?? systemFont
        }
        return systemFont
    }
}

// MARK: - VerticallyCenteredTextFieldCell

private class VerticallyCenteredTextFieldCell: NSTextFieldCell {
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

// MARK: - ButtonHoverHandler

private class ButtonHoverHandler: NSResponder {
    private weak var button: NSButton?
    private var accentColor: NSColor

    private static var handlers: [ObjectIdentifier: ButtonHoverHandler] = [:]

    static func shared(for button: NSButton, accent: NSColor) -> ButtonHoverHandler {
        let key = ObjectIdentifier(button)
        if let existing = handlers[key] {
            return existing
        }
        let handler = ButtonHoverHandler(button: button, accent: accent)
        handlers[key] = handler
        return handler
    }

    private init(button: NSButton, accent: NSColor) {
        self.button = button
        self.accentColor = accent
        super.init()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            button?.animator().alphaValue = 0.85
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            button?.animator().alphaValue = 1.0
        }
    }
}
