# Contributing to Buddy

Thanks for your interest in contributing to Buddy! Here's how to get started.

## Development Setup

1. **Clone the repo**
   ```bash
   git clone https://github.com/rahamanbinujit/buddy-app.git
   cd buddy-app
   ```

2. **Build and run**
   ```bash
   swift build
   .build/debug/Buddy
   ```

3. **Grant permissions** -- Buddy needs Accessibility permission for the global hotkey. Screen Recording is optional.

## Making Changes

### Before You Start

- Check [Issues](https://github.com/rahamanbinujit/buddy-app/issues) for existing discussions
- For large changes, open an issue first to discuss the approach
- For small fixes (typos, bugs), go ahead and submit a PR

### Code Style

- Follow existing patterns in the codebase
- Use Swift conventions (camelCase, etc.)
- Keep files focused -- one class/struct per file when possible
- No force unwraps (`!`) unless the value is guaranteed (e.g., static URLs)

### Pull Request Process

1. Fork the repo and create a branch from `main`
2. Make your changes
3. Test locally -- build and run the app, verify your changes work
4. Write clear commit messages
5. Submit a PR with:
   - What you changed and why
   - Screenshots/recordings if it's a visual change
   - Steps to test

### Architecture Overview

**App Lifecycle:** `BuddyApp.swift` (entry) -> `AppDelegate` -> `BuddyController` (manages character window) -> `BuddyCharacter` (rendering + interactions)

**AI Chat:** User message -> `AgentProvider.createAgentSession()` (picks the right session based on provider) -> `ClaudeSession` / `ClaudeAPISession` / `OpenAISession` / `GeminiSession` -> streaming response -> `ChatView`

**Settings:** `SettingsManager` (persists to `~/.buddy/settings.json`) + `KeychainHelper` (API keys in macOS Keychain)

**Character:** `CharacterRenderer` generates pixel art frames -> `CharacterPack` defines animation sequences -> `BuddyCharacter` handles window, positioning, interactions

### Adding a New AI Provider

1. Add a case to `ModelProvider` enum in `ModelProvider.swift`
2. Add models to `AvailableModels.all` in the same file
3. Create a new session class implementing `AgentSession` protocol (see `GeminiSession.swift` as a template)
4. Add the case to `createAgentSession()` in `AgentProvider.swift`
5. Add keychain support in `KeychainHelper.swift`
6. Add the provider button in `SettingsWindow.swift`

### Adding New Animations

1. Define frame data in `CharacterPack.swift`
2. Add a play method in `BuddyCharacter.swift`
3. Wire it up (menu bar, health reminders, focus events, etc.)

## Reporting Bugs

Open an issue with:
- macOS version
- What happened vs. what you expected
- Steps to reproduce
- Console logs if available (`Console.app`, filter by "Buddy")

## Feature Requests

Open an issue tagged with "enhancement". Describe:
- What the feature does
- Why it's useful
- How it might work (optional, but helpful)

## Code of Conduct

Be respectful and constructive. We're all here to build something cool.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
