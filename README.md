# Buddy

<p align="center">
  <strong>An AI companion that lives on your macOS desktop.</strong><br>
  Walks on your dock, chats with you, tracks your focus, and reminds you to take care of yourself.
</p>

<p align="center">
  <a href="#install">Install</a> &bull;
  <a href="#features">Features</a> &bull;
  <a href="#ai-providers">AI Providers</a> &bull;
  <a href="#build-from-source">Build from Source</a> &bull;
  <a href="#contributing">Contributing</a> &bull;
  <a href="#license">License</a>
</p>

---

## Install

**Download the latest release:**

1. Go to [Releases](https://github.com/rahamanbinujit/buddy-app/releases)
2. Download `Buddy.dmg`
3. Open the DMG and drag Buddy to your Applications folder
4. Launch Buddy from Applications or Spotlight

Auto-updates are built in. Once installed, Buddy will notify you when new versions are available.

## Features

**AI Chat**
- Click the character or press `Cmd+Shift+Space` to open chat
- Bring your own API key (Anthropic, OpenAI, or Google Gemini)
- Works with Claude CLI if you have it installed
- Voice conversations (hold the character to talk)
- Screenshot context -- Buddy can see what you're looking at when answering questions

**Desktop Companion**
- Pixel art Spider-Man character walks along your dock
- Tap to pet -- emotions escalate the more you tap (happy, love, surprised, scared, angry, dead)
- Proactive screen comments with emoji reactions (configurable interval)
- Tamagotchi-style animations: bounce, shake, tremble, squash

**Productivity**
- Focus sessions with distraction detection and progress tracking
- Health reminders: water, breaks, posture, eye rest, movement
- Stuck detector -- notices when you've been on the same thing too long

**Privacy**
- All API keys are stored in your macOS Keychain -- never sent anywhere
- No accounts, no sign-ups, no telemetry
- Direct API calls to your chosen provider -- no middleman server
- Screen captures are processed locally and immediately discarded

## AI Providers

Buddy supports multiple AI providers. Choose one in Settings:

| Provider | Setup | Models |
|----------|-------|--------|
| **Claude CLI** | Install [Claude CLI](https://docs.anthropic.com/en/docs/claude-cli) | Uses your CLI config |
| **Claude API** | Add your API key from [console.anthropic.com](https://console.anthropic.com) | Sonnet 4, Haiku 4.5 |
| **OpenAI** | Add your API key from [platform.openai.com](https://platform.openai.com) | GPT-4o, GPT-4.1, and Mini variants |
| **Gemini** | Add your free API key from [aistudio.google.com](https://aistudio.google.com) | Gemini 2.5 Pro, Gemini 2.5 Flash |

If Claude CLI is detected on your system, Buddy uses it automatically. Otherwise, it defaults to Gemini (free API keys available from Google AI Studio).

## Requirements

- macOS 13+
- One of: Claude CLI installed, or an API key from Anthropic / OpenAI / Google

## Permissions

- **Accessibility** -- required for the `Cmd+Shift+Space` global hotkey
- **Screen Recording** -- optional, enables screenshot context for chat and proactive screen comments
- **Microphone** -- optional, enables voice conversations

## Build from Source

```bash
git clone https://github.com/rahamanbinujit/buddy-app.git
cd buddy-app
swift build
```

Run directly:
```bash
.build/debug/Buddy
```

Build a release `.app` bundle and DMG:
```bash
./scripts/build-app.sh
```

### Project Structure

```
buddy-app/
  Buddy/                    # Swift source code
    BuddyApp.swift          # App entry point and AppDelegate
    BuddyCharacter.swift    # Character rendering and animations
    BuddyController.swift   # Character window and dock positioning
    ChatView.swift           # Chat UI
    SettingsWindow.swift     # Settings panel
    ModelProvider.swift      # AI provider definitions
    AgentProvider.swift      # Session factory (CLI, API, Gemini, OpenAI)
    ClaudeSession.swift      # Claude CLI integration
    ClaudeAPISession.swift   # Anthropic API (streaming)
    OpenAISession.swift      # OpenAI API (streaming)
    GeminiSession.swift      # Google Gemini API (streaming)
    SSEParser.swift          # Server-Sent Events parser
    KeychainHelper.swift     # Secure API key storage
    SettingsManager.swift    # User preferences
    PersonalContext.swift    # User profile and context
    FocusGuardian.swift      # Focus session tracking
    HealthReminders.swift    # Health reminder system
    StuckDetector.swift      # Stuck detection
    ScreenContext.swift      # Screenshot capture
    VoiceAssistant.swift     # Voice input/output
    CharacterRenderer.swift  # Pixel art rendering
    CharacterPack.swift      # Animation frames
    MemoryStore.swift        # Conversation memory
    Assets.xcassets/         # App icon and assets
  scripts/
    build-app.sh             # Build, sign, notarize, and package DMG
    publish-release.sh       # Automate releases (build + sign + GitHub release)
    gen-icon.py              # Generate app icon from pixel art
  Tests/                     # Test suite
  appcast.xml                # Sparkle update feed
  Package.swift              # Swift Package Manager config
```

### Dependencies

- [Sparkle](https://github.com/sparkle-project/Sparkle) (2.6.0+) -- auto-updates framework

## Contributing

Contributions are welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

**Quick start:**

1. Fork the repo
2. Create a feature branch (`git checkout -b feature/your-feature`)
3. Make your changes
4. Test locally (`swift build && .build/debug/Buddy`)
5. Submit a pull request

### Ideas for Contributions

- New character packs and animations
- Additional AI provider integrations
- Accessibility improvements
- Localization / i18n
- New productivity features (Pomodoro, habit tracking, etc.)
- UI themes and customization options

## License

MIT -- see [LICENSE](LICENSE) for details.

## Credits

Built by [Rahaman Bin Ujit](https://github.com/rahamanbinujit) under [Artiphik](https://artiphik.com).
