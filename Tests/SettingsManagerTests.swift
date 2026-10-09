import XCTest
@testable import Buddy

final class SettingsManagerTests: XCTestCase {
    private var directory: URL!
    private var manager: SettingsManager!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        manager = SettingsManager(settingsURL: directory.appendingPathComponent("settings.json"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testProviderSwitchDiscardsCrossProviderPreference() {
        manager.update { $0.preferredModels[ModelProvider.gemini.rawValue] = "gpt-4o" }
        manager.setProvider(.gemini)
        XCTAssertEqual(manager.settings.activeModelId, "gemini-2.5-pro")
        manager.setProvider(.buddyProxy)
        XCTAssertTrue(AvailableModels.models(for: .buddyProxy).contains { $0.id == manager.settings.activeModelId })
    }

    func testProviderSwitchRestoresValidPreference() {
        manager.setProvider(.gemini)
        manager.setModel("gemini-2.5-flash")
        manager.setProvider(.openAI)
        manager.setProvider(.gemini)
        XCTAssertEqual(manager.settings.activeModelId, "gemini-2.5-flash")
    }

    func testInvalidModelCannotBecomeActive() {
        manager.setProvider(.gemini)
        manager.setModel("gpt-4o")
        XCTAssertEqual(manager.settings.activeModelId, "gemini-2.5-pro")
    }

    func testLoadingRepairsMismatchedModelWithoutChangingProvider() {
        manager.update { $0.activeProvider = .gemini; $0.activeModelId = "gpt-4o" }
        let loaded = SettingsManager(settingsURL: directory.appendingPathComponent("settings.json"))
        XCTAssertEqual(loaded.settings.activeProvider, .gemini)
        XCTAssertEqual(loaded.settings.activeModelId, "gemini-2.5-pro")
    }

}
