import AppKit
import AVFoundation

class SettingsWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    private static var current: SettingsWindow?

    private var providerButtons: [ModelProvider: NSButton] = [:]
    private var modelPopup: NSPopUpButton!
    private var statusLabel: NSTextField!

    // Local engines
    private var localHeader: NSTextField!
    private var localStatusLabel: NSTextField!
    private var localDetailLabel: NSTextField!
    private var localPrimaryBtn: NSButton!
    private var endpointField: NSTextField!
    private var endpointSaveBtn: NSButton!
    private var endpointLabel: NSTextField!

    // API key
    private var apiKeyField: NSSecureTextField!
    private var apiKeySaveBtn: NSButton!
    private var apiKeyDeleteBtn: NSButton!
    private var apiKeyProviderLabel: NSTextField!
    private var apiKeyHeader: NSTextField!
    private var apiKeyHintLabel: NSTextField!

    private var voiceHeader: NSTextField!
    private var voiceStatusLabel: NSTextField!
    private var voiceHintLabel: NSTextField!
    private var voiceSettingsBtn: NSButton!

    private var monitor: Any?
    /// Models reported by the running local engines, if any were found.
    private var discoveredModels: [LocalModelInfo] = []

    private static let windowWidth: CGFloat = 440
    private static let windowHeight: CGFloat = 660

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.windowWidth, height: Self.windowHeight),
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

        let outer = NSView(frame: NSRect(x: 0, y: 0, width: Self.windowWidth, height: Self.windowHeight))
        outer.wantsLayer = true
        outer.layer?.backgroundColor = PetTheme.paper.cgColor
        outer.layer?.cornerRadius = 16
        outer.layer?.masksToBounds = true
        outer.layer?.borderWidth = 1
        outer.layer?.borderColor = PetTheme.milk.cgColor
        contentView = outer

        buildUI(in: outer, width: Self.windowWidth, height: Self.windowHeight)
        refreshState()
        refreshDiscoveredModels()
    }

    static func show() {
        if let existing = current, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let win = SettingsWindow()
        current = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        win.installMonitor()
    }

    private var activeProvider: ModelProvider {
        SettingsManager.shared.settings.activeProvider
    }

    // MARK: - Build UI

    private func buildUI(in outer: NSView, width W: CGFloat, height H: CGFloat) {
        let pad: CGFloat = 24
        var y = H - pad

        // Title
        y -= 28
        let title = makeLabel("Settings", size: 20, weight: .bold)
        title.frame = NSRect(x: pad, y: y, width: W - pad * 2, height: 28)
        outer.addSubview(title)

        // Close button
        let closeBtn = NSButton(frame: NSRect(x: W - pad - 24, y: y + 2, width: 24, height: 24))
        closeBtn.isBordered = false
        closeBtn.attributedTitle = NSAttributedString(
            string: "X",
            attributes: [
                .font: PetFonts.rounded(size: 14, weight: .bold),
                .foregroundColor: PetTheme.ink.withAlphaComponent(0.5),
            ]
        )
        closeBtn.target = self
        closeBtn.action = #selector(closeTapped)
        outer.addSubview(closeBtn)

        // MARK: Model engine
        y -= 32
        let modelHeader = makeSectionHeader("Model engine")
        modelHeader.frame = NSRect(x: pad, y: y, width: W - pad * 2, height: 18)
        outer.addSubview(modelHeader)

        // Engines on this Mac first, then the ones reached over the network.
        let rows: [[(ModelProvider, String)]] = [
            [
                (.appleFoundation, "Apple"),
                (.ollama, "Ollama"),
                (.localServer, "Local API"),
                (.claudeCLI, "Claude CLI"),
            ],
            [
                (.claudeAPI, "Claude API"),
                (.openAI, "OpenAI"),
                (.gemini, "Gemini"),
            ],
        ]

        let columns = CGFloat(rows[0].count)
        let gap: CGFloat = 6
        let btnW = (W - pad * 2 - gap * (columns - 1)) / columns
        let btnH: CGFloat = 28

        y -= 8
        for row in rows {
            y -= btnH
            var bx = pad
            for (provider, label) in row {
                let btn = NSButton(frame: NSRect(x: bx, y: y, width: btnW, height: btnH))
                btn.isBordered = false
                btn.wantsLayer = true
                btn.layer?.cornerRadius = 8
                btn.layer?.borderWidth = 1
                btn.layer?.borderColor = PetTheme.milk.cgColor
                btn.layer?.backgroundColor = PetTheme.milk.cgColor
                btn.attributedTitle = NSAttributedString(
                    string: label,
                    attributes: [
                        .font: PetFonts.rounded(size: 10, weight: .medium),
                        .foregroundColor: PetTheme.ink,
                    ]
                )
                btn.target = self
                btn.action = #selector(providerTapped(_:))
                providerButtons[provider] = btn
                outer.addSubview(btn)
                bx += btnW + gap
            }
            y -= gap
        }
        y += gap

        // Model dropdown
        y -= 34
        modelPopup = NSPopUpButton(frame: NSRect(x: pad, y: y, width: W - pad * 2, height: 28))
        modelPopup.isBordered = false
        modelPopup.wantsLayer = true
        modelPopup.layer?.backgroundColor = PetTheme.milk.cgColor
        modelPopup.layer?.cornerRadius = 8
        (modelPopup.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
        modelPopup.font = PetFonts.rounded(size: 12, weight: .medium)
        modelPopup.target = self
        modelPopup.action = #selector(modelChanged(_:))
        outer.addSubview(modelPopup)

        // Status
        y -= 20
        statusLabel = makeLabel("", size: 11, weight: .medium)
        statusLabel.frame = NSRect(x: pad, y: y, width: W - pad * 2, height: 16)
        outer.addSubview(statusLabel)

        // MARK: Local AI
        y -= 28
        localHeader = makeSectionHeader("Local AI")
        localHeader.frame = NSRect(x: pad, y: y, width: W - pad * 2, height: 18)
        outer.addSubview(localHeader)

        y -= 20
        localStatusLabel = makeLabel("", size: 11, weight: .medium)
        localStatusLabel.frame = NSRect(x: pad, y: y, width: W - pad * 2, height: 16)
        outer.addSubview(localStatusLabel)

        y -= 18
        localDetailLabel = makeLabel("", size: 10, weight: .regular)
        localDetailLabel.textColor = PetTheme.ink.withAlphaComponent(0.4)
        localDetailLabel.lineBreakMode = .byWordWrapping
        localDetailLabel.maximumNumberOfLines = 2
        localDetailLabel.frame = NSRect(x: pad, y: y - 8, width: W - pad * 2, height: 28)
        outer.addSubview(localDetailLabel)

        // Endpoint field, used by the engines that live in another process.
        y -= 40
        endpointLabel = makeLabel("", size: 10, weight: .medium)
        endpointLabel.textColor = PetTheme.ink.withAlphaComponent(0.5)
        endpointLabel.frame = NSRect(x: pad, y: y, width: W - pad * 2, height: 14)
        outer.addSubview(endpointLabel)

        y -= 30
        endpointField = NSTextField(frame: NSRect(x: pad, y: y, width: W - pad * 2 - 64, height: 26))
        endpointField.isBordered = false
        endpointField.wantsLayer = true
        endpointField.layer?.backgroundColor = PetTheme.milk.cgColor
        endpointField.layer?.cornerRadius = 8
        endpointField.font = PetFonts.mono(size: 11)
        endpointField.textColor = PetTheme.ink
        endpointField.backgroundColor = PetTheme.milk
        endpointField.focusRingType = .none
        outer.addSubview(endpointField)

        endpointSaveBtn = makeSmallButton("Save", action: #selector(saveEndpoint))
        endpointSaveBtn.frame = NSRect(x: W - pad - 58, y: y, width: 58, height: 26)
        outer.addSubview(endpointSaveBtn)

        y -= 26
        localPrimaryBtn = makeSmallButton("Refresh", action: #selector(localPrimaryTapped))
        localPrimaryBtn.frame = NSRect(x: pad, y: y - 6, width: 130, height: 26)
        outer.addSubview(localPrimaryBtn)

        // MARK: API keys
        y -= 46
        apiKeyHeader = makeSectionHeader("API Key")
        apiKeyHeader.frame = NSRect(x: pad, y: y, width: W - pad * 2, height: 18)
        outer.addSubview(apiKeyHeader)

        y -= 20
        apiKeyProviderLabel = makeLabel("", size: 11, weight: .medium)
        apiKeyProviderLabel.textColor = PetTheme.ink.withAlphaComponent(0.5)
        apiKeyProviderLabel.frame = NSRect(x: pad, y: y, width: W - pad * 2, height: 16)
        outer.addSubview(apiKeyProviderLabel)

        y -= 34
        apiKeyField = NSSecureTextField(frame: NSRect(x: pad, y: y, width: W - pad * 2 - 120, height: 28))
        apiKeyField.isBordered = false
        apiKeyField.wantsLayer = true
        apiKeyField.layer?.backgroundColor = PetTheme.milk.cgColor
        apiKeyField.layer?.cornerRadius = 8
        apiKeyField.font = PetFonts.mono(size: 11)
        apiKeyField.textColor = PetTheme.ink
        apiKeyField.backgroundColor = PetTheme.milk
        apiKeyField.focusRingType = .none
        outer.addSubview(apiKeyField)

        apiKeySaveBtn = makeSmallButton("Save", action: #selector(saveAPIKey))
        apiKeySaveBtn.frame = NSRect(x: W - pad - 112, y: y, width: 52, height: 28)
        outer.addSubview(apiKeySaveBtn)

        apiKeyDeleteBtn = makeSmallButton("Delete", action: #selector(deleteAPIKey))
        apiKeyDeleteBtn.frame = NSRect(x: W - pad - 56, y: y, width: 52, height: 28)
        outer.addSubview(apiKeyDeleteBtn)

        y -= 22
        apiKeyHintLabel = makeLabel("", size: 10, weight: .regular)
        apiKeyHintLabel.textColor = PetTheme.ink.withAlphaComponent(0.35)
        apiKeyHintLabel.frame = NSRect(x: pad, y: y, width: W - pad * 2, height: 14)
        outer.addSubview(apiKeyHintLabel)

        // MARK: Voice
        y -= 30
        voiceHeader = makeSectionHeader("Voice")
        voiceHeader.frame = NSRect(x: pad, y: y, width: W - pad * 2, height: 18)
        outer.addSubview(voiceHeader)

        y -= 20
        voiceStatusLabel = makeLabel("", size: 11, weight: .medium)
        voiceStatusLabel.frame = NSRect(x: pad, y: y, width: W - pad * 2, height: 16)
        outer.addSubview(voiceStatusLabel)

        y -= 20
        voiceHintLabel = makeLabel("", size: 10, weight: .regular)
        voiceHintLabel.textColor = PetTheme.ink.withAlphaComponent(0.35)
        voiceHintLabel.lineBreakMode = .byWordWrapping
        voiceHintLabel.maximumNumberOfLines = 2
        voiceHintLabel.frame = NSRect(x: pad, y: y - 8, width: W - pad * 2 - 90, height: 28)
        outer.addSubview(voiceHintLabel)

        voiceSettingsBtn = makeSmallButton("Open", action: #selector(openVoiceSettings))
        voiceSettingsBtn.frame = NSRect(x: W - pad - 80, y: y - 4, width: 72, height: 24)
        outer.addSubview(voiceSettingsBtn)
    }

    // MARK: - State

    func refreshState() {
        let settings = SettingsManager.shared.settings
        let provider = settings.activeProvider

        // Highlight the active engine
        for (candidate, btn) in providerButtons {
            let isActive = candidate == provider
            btn.layer?.backgroundColor = (isActive ? PetTheme.shell : PetTheme.milk).cgColor
            btn.layer?.borderColor = (isActive ? PetTheme.shell : PetTheme.milk).cgColor
            btn.attributedTitle = NSAttributedString(
                string: btn.attributedTitle.string,
                attributes: [
                    .font: PetFonts.rounded(size: 10, weight: isActive ? .bold : .medium),
                    .foregroundColor: isActive ? NSColor.white : PetTheme.ink,
                ]
            )
        }

        // Model list
        modelPopup.removeAllItems()
        var entries: [(id: String, title: String)] = AvailableModels.models(for: provider)
            .map { (id: $0.id, title: $0.displayName) }
        if provider.hasDynamicModels {
            entries = discoveredModels.map { (id: $0.id, title: $0.displayName) }
            if entries.isEmpty {
                entries = [(id: "", title: "No models found — is the engine running?")]
            }
        }
        for entry in entries {
            modelPopup.addItem(withTitle: entry.title)
            modelPopup.lastItem?.representedObject = entry.id
        }
        if let index = entries.firstIndex(where: { $0.id == settings.activeModelId }) {
            modelPopup.selectItem(at: index)
        }

        refreshStatus(provider: provider, settings: settings)
        refreshLocalSection(provider: provider, settings: settings)
        refreshAPIKeySection(provider: provider)
        refreshVoiceSection()
    }

    private func refreshStatus(provider: ModelProvider, settings: SettingsManager.Settings) {
        let okColor = NSColor(red: 0.3, green: 0.75, blue: 0.45, alpha: 1)
        let warnColor = NSColor(red: 0.85, green: 0.35, blue: 0.3, alpha: 1)

        switch provider {
        case .appleFoundation:
            let availability = AppleIntelligence.availability()
            statusLabel.stringValue = availability.message
            statusLabel.textColor = availability.isAvailable ? okColor : warnColor

        case .ollama:
            statusLabel.stringValue = settings.activeModelId.isEmpty
                ? "Start Ollama and pick a model"
                : "Local model: \(settings.activeModelId)"
            statusLabel.textColor = settings.activeModelId.isEmpty
                ? PetTheme.ink.withAlphaComponent(0.5) : okColor

        case .localServer:
            statusLabel.stringValue = settings.activeModelId.isEmpty
                ? "Start your local server and pick a model"
                : "Local model: \(settings.activeModelId)"
            statusLabel.textColor = settings.activeModelId.isEmpty
                ? PetTheme.ink.withAlphaComponent(0.5) : okColor

        case .claudeCLI:
            let paths = [
                "/usr/local/bin/claude",
                "/opt/homebrew/bin/claude",
                "\(NSHomeDirectory())/.local/bin/claude",
                "\(NSHomeDirectory())/.claude/local/claude",
            ]
            let found = paths.contains { FileManager.default.isExecutableFile(atPath: $0) }
            statusLabel.stringValue = found ? "Claude CLI detected" : "Claude CLI not found — install it first"
            statusLabel.textColor = found ? okColor : warnColor

        case .claudeAPI, .openAI, .gemini:
            let hasKey = KeychainHelper.apiKey(for: provider) != nil
            let name: String
            switch provider {
            case .claudeAPI: name = "Anthropic"
            case .openAI: name = "OpenAI"
            default: name = "Google AI"
            }
            statusLabel.stringValue = hasKey ? "API key saved" : "Add your \(name) API key"
            statusLabel.textColor = hasKey ? okColor : PetTheme.ink.withAlphaComponent(0.5)

        case .buddyProxy:
            statusLabel.stringValue = "Buddy subscription proxy"
            statusLabel.textColor = PetTheme.ink.withAlphaComponent(0.5)
        }
    }

    /// Everything that only concerns engines running on this Mac.
    private func refreshLocalSection(provider: ModelProvider, settings: SettingsManager.Settings) {
        let showsLocal = provider.isLocal
        localHeader.isHidden = !showsLocal
        localStatusLabel.isHidden = !showsLocal
        localDetailLabel.isHidden = !showsLocal
        localPrimaryBtn.isHidden = !showsLocal
        let showsEndpoint = provider == .ollama || provider == .localServer
        endpointField.isHidden = !showsEndpoint
        endpointSaveBtn.isHidden = !showsEndpoint
        endpointLabel.isHidden = !showsEndpoint
        guard showsLocal else { return }

        switch provider {
        case .appleFoundation:
            let availability = AppleIntelligence.availability()
            localStatusLabel.stringValue = availability.message
            localStatusLabel.textColor = availability.isAvailable
                ? NSColor(red: 0.3, green: 0.75, blue: 0.45, alpha: 1)
                : NSColor(red: 0.85, green: 0.35, blue: 0.3, alpha: 1)
            localDetailLabel.stringValue = availability.isAvailable
                ? "Chats stay on this Mac. No account, no API key."
                : "Buddy needs Apple Intelligence enabled in System Settings."
            localPrimaryBtn.isHidden = !availability.canOpenSettings
            localPrimaryBtn.title = "System Settings"

        case .ollama:
            endpointLabel.stringValue = "Ollama address"
            if firstResponder !== endpointField {
                endpointField.stringValue = settings.ollamaBaseURL
            }
            localStatusLabel.stringValue = "Ollama on this Mac"
            localStatusLabel.textColor = PetTheme.ink
            localDetailLabel.stringValue = discoveredModels.isEmpty
                ? "No models answered at this address. Start Ollama with a model pulled."
                : "\(discoveredModels.count) model(s) available. Requests stay on this Mac."
            localPrimaryBtn.isHidden = false
            localPrimaryBtn.title = "Refresh models"

        case .localServer:
            endpointLabel.stringValue = "Server address (OpenAI compatible)"
            if firstResponder !== endpointField {
                endpointField.stringValue = settings.localServerBaseURL
            }
            localStatusLabel.stringValue = "Local server on this Mac"
            localStatusLabel.textColor = PetTheme.ink
            localDetailLabel.stringValue = discoveredModels.isEmpty
                ? "No models answered at this address. Start LM Studio or llama.cpp first."
                : "\(discoveredModels.count) model(s) available. Requests stay on this Mac."
            localPrimaryBtn.isHidden = false
            localPrimaryBtn.title = "Refresh models"

        default:
            break
        }
    }

    private func refreshAPIKeySection(provider: ModelProvider) {
        let needsKey = provider.requiresAPIKey
        apiKeyHeader.isHidden = !needsKey
        apiKeyField.isHidden = !needsKey
        apiKeySaveBtn.isHidden = !needsKey
        apiKeyProviderLabel.isHidden = !needsKey
        apiKeyHintLabel.isHidden = !needsKey
        apiKeyDeleteBtn.isHidden = true
        guard needsKey else { return }

        let hasKey = KeychainHelper.apiKey(for: provider) != nil
        apiKeyDeleteBtn.isHidden = !hasKey

        switch provider {
        case .claudeAPI:
            apiKeyProviderLabel.stringValue = "Anthropic API Key"
            apiKeyField.placeholderString = "sk-ant-..."
            apiKeyHintLabel.stringValue = "Get one at console.anthropic.com"
        case .openAI:
            apiKeyProviderLabel.stringValue = "OpenAI API Key"
            apiKeyField.placeholderString = "sk-..."
            apiKeyHintLabel.stringValue = "Get one at platform.openai.com"
        case .gemini:
            apiKeyProviderLabel.stringValue = "Google AI API Key"
            apiKeyField.placeholderString = "AIza..."
            apiKeyHintLabel.stringValue = "Get one free at aistudio.google.com"
        default:
            break
        }
    }

    private func refreshVoiceSection() {
        let whisperPath = Bundle.main.path(forResource: "whisper-cli", ofType: nil)
        let modelPath = Bundle.main.path(forResource: "ggml-base.en", ofType: "bin")
        let whisperAvailable = (whisperPath != nil && modelPath != nil)
            || FileManager.default.fileExists(atPath: "/opt/homebrew/bin/whisper-cli")

        if whisperAvailable {
            voiceStatusLabel.stringValue = "Voice input ready (hold character to talk)"
            voiceStatusLabel.textColor = NSColor(red: 0.3, green: 0.75, blue: 0.45, alpha: 1)
        } else {
            voiceStatusLabel.stringValue = "Voice unavailable — whisper model not found"
            voiceStatusLabel.textColor = NSColor(red: 0.85, green: 0.35, blue: 0.3, alpha: 1)
        }

        let hasPremium = AVSpeechSynthesisVoice(identifier: "com.apple.voice.premium.en-US.Zoe") != nil
            || AVSpeechSynthesisVoice(identifier: "com.apple.voice.enhanced.en-US.Samantha") != nil
        if hasPremium {
            voiceHintLabel.stringValue = "Premium voice detected — Buddy will sound great"
            voiceHintLabel.textColor = NSColor(red: 0.3, green: 0.75, blue: 0.45, alpha: 1)
            voiceSettingsBtn.isHidden = true
        } else {
            voiceHintLabel.stringValue =
                "Tip: download a premium voice in System Settings > Accessibility > Spoken Content for better output"
            voiceHintLabel.textColor = PetTheme.ink.withAlphaComponent(0.35)
            voiceSettingsBtn.isHidden = false
        }
    }

    /// Asks the local engines which models they serve.
    private func refreshDiscoveredModels() {
        let provider = activeProvider
        guard provider.hasDynamicModels else {
            discoveredModels = []
            return
        }

        let completion: (Result<[LocalModelInfo], Error>) -> Void = { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let models):
                self.discoveredModels = models
                // Adopt the first model when nothing valid is selected yet.
                let current = SettingsManager.shared.settings.activeModelId
                if models.isEmpty {
                    // Keep whatever was chosen; the engine is simply not running.
                } else if !models.contains(where: { $0.id == current }),
                    let first = models.first
                {
                    SettingsManager.shared.setModel(first.id)
                }
            case .failure:
                self.discoveredModels = []
            }
            self.refreshState()
        }

        switch provider {
        case .ollama:
            LocalModelDiscovery.listOllama(completion: completion)
        case .localServer:
            LocalModelDiscovery.listOpenAICompatible(completion: completion)
        default:
            break
        }
    }

    // MARK: - Actions

    @objc private func providerTapped(_ sender: NSButton) {
        guard let provider = providerButtons.first(where: { $0.value == sender })?.key else { return }
        apiKeyField.stringValue = ""
        SettingsManager.shared.setProvider(provider)
        discoveredModels = []
        refreshState()
        refreshDiscoveredModels()
    }

    @objc private func modelChanged(_ sender: NSPopUpButton) {
        guard let modelId = sender.selectedItem?.representedObject as? String, !modelId.isEmpty else { return }
        SettingsManager.shared.setModel(modelId)
        refreshState()
    }

    /// Download, cancel or refresh, depending on the selected engine.
    @objc private func localPrimaryTapped() {
        let provider = activeProvider
        let modelId = SettingsManager.shared.settings.activeModelId

        switch provider {
        case .appleFoundation:
            AppleIntelligence.openSystemSettings()
        case .ollama, .localServer:
            LocalModelDiscovery.invalidateCaches()
            refreshDiscoveredModels()
        default:
            break
        }
    }

    @objc private func saveEndpoint() {
        let provider = activeProvider
        let raw = endpointField.stringValue
        let fallback = provider == .ollama ? LocalAI.ollamaDefaultBaseURL : LocalAI.localServerDefaultBaseURL

        guard let url = LocalAI.normalizedBaseURL(raw, fallback: fallback) else {
            localDetailLabel.stringValue = LocalAI.nonLoopbackMessage
            localDetailLabel.textColor = NSColor(red: 0.85, green: 0.35, blue: 0.3, alpha: 1)
            return
        }
        localDetailLabel.textColor = PetTheme.ink.withAlphaComponent(0.4)

        switch provider {
        case .ollama:
            SettingsManager.shared.setOllamaBaseURL(url.absoluteString)
        case .localServer:
            SettingsManager.shared.setLocalServerBaseURL(url.absoluteString)
        default:
            break
        }
        LocalModelDiscovery.invalidateCaches()
        discoveredModels = []
        refreshState()
        refreshDiscoveredModels()
    }

    @objc private func saveAPIKey() {
        let key = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let provider = activeProvider
        guard KeychainHelper.saveAPIKey(key, for: provider) else {
            apiKeyHintLabel.stringValue = "Could not save the API key. Try again."
            return
        }
        apiKeyField.stringValue = ""
        refreshState()
        apiKeyHintLabel.stringValue = "API key saved."
        NotificationCenter.default.post(name: SettingsManager.modelConfigChanged, object: nil)
    }

    @objc private func deleteAPIKey() {
        let provider = activeProvider
        guard KeychainHelper.deleteAPIKey(for: provider) else {
            apiKeyHintLabel.stringValue = "Could not remove the API key. Try again."
            return
        }
        apiKeyField.stringValue = ""
        refreshState()
        apiKeyHintLabel.stringValue = "API key removed."
    }

    @objc private func openVoiceSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func closeTapped() {
        close()
    }

    override func close() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        Self.current = nil
        orderOut(nil)
    }

    // MARK: - Monitor

    private func installMonitor() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self else { return }
            let loc = NSEvent.mouseLocation
            if !self.frame.contains(loc) { self.close() }
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close(); return }
        super.keyDown(with: event)
    }

    // MARK: - Helpers

    private func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight, alignment: NSTextAlignment = .left) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = PetFonts.rounded(size: size, weight: weight)
        label.textColor = PetTheme.ink
        label.alignment = alignment
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        return label
    }

    private func makeSectionHeader(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = PetFonts.rounded(size: 10, weight: .bold)
        label.textColor = PetTheme.ink.withAlphaComponent(0.4)
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        return label
    }

    private func makeSmallButton(_ title: String, action: Selector) -> NSButton {
        let btn = NSButton(frame: .zero)
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 8
        btn.layer?.backgroundColor = PetTheme.milk.cgColor
        btn.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: PetFonts.rounded(size: 11, weight: .medium),
                .foregroundColor: PetTheme.ink,
            ]
        )
        btn.target = self
        btn.action = action
        return btn
    }

    deinit {
        if let m = monitor { NSEvent.removeMonitor(m) }
    }
}
