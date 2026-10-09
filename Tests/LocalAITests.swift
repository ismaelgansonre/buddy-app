import XCTest
import CoreGraphics
import CoreText
import ImageIO

@testable import Buddy

final class LocalAITests: XCTestCase {

    // MARK: - Provider capabilities

    func testLocalProvidersAreMarkedLocal() {
        XCTAssertTrue(ModelProvider.appleFoundation.isLocal)
        XCTAssertTrue(ModelProvider.ollama.isLocal)
        XCTAssertTrue(ModelProvider.localServer.isLocal)
        XCTAssertFalse(ModelProvider.openAI.isLocal)
        XCTAssertFalse(ModelProvider.claudeCLI.isLocal)
    }

    func testOnlyRemoteProvidersRequireAPIKeys() {
        for provider in ModelProvider.allCases {
            let expectsKey =
                provider == .claudeAPI || provider == .openAI || provider == .gemini
            XCTAssertEqual(provider.requiresAPIKey, expectsKey, "unexpected key requirement for \(provider)")
        }
    }

    func testOnlyProcessBasedEnginesHaveDynamicModels() {
        XCTAssertTrue(ModelProvider.ollama.hasDynamicModels)
        XCTAssertTrue(ModelProvider.localServer.hasDynamicModels)
        XCTAssertFalse(ModelProvider.appleFoundation.hasDynamicModels)
    }

    // MARK: - Endpoint safety

    func testLoopbackAddressesAreAccepted() {
        for raw in ["http://127.0.0.1:11434", "http://localhost:1234/v1", "http://[::1]:8080"] {
            XCTAssertNotNil(LocalAI.normalizedBaseURL(raw, fallback: LocalAI.ollamaDefaultBaseURL), raw)
        }
    }

    func testRemoteAddressesAreRejected() {
        for raw in [
            "https://api.openai.com/v1",
            "http://192.168.1.20:11434",
            "http://example.com:11434",
            "ftp://127.0.0.1",
        ] {
            XCTAssertNil(LocalAI.normalizedBaseURL(raw, fallback: LocalAI.ollamaDefaultBaseURL), raw)
        }
    }

    func testEmptyEndpointFallsBackToDefault() {
        let url = LocalAI.normalizedBaseURL("   ", fallback: LocalAI.ollamaDefaultBaseURL)
        XCTAssertEqual(url?.absoluteString, LocalAI.ollamaDefaultBaseURL)
    }

    // MARK: - Settings

    func testSettingsFromOlderFileKeepWorking() throws {
        // A settings file written before the local engines existed.
        let legacy = """
            {
              "activeProvider": "gemini",
              "activeModelId": "gemini-2.5-flash",
              "preferredModels": { "gemini": "gemini-2.5-flash" }
            }
            """
        let settings = try JSONDecoder().decode(SettingsManager.Settings.self, from: Data(legacy.utf8))

        XCTAssertEqual(settings.activeProvider, .gemini)
        XCTAssertEqual(settings.activeModelId, "gemini-2.5-flash")
        XCTAssertEqual(settings.ollamaBaseURL, LocalAI.ollamaDefaultBaseURL)
        XCTAssertEqual(settings.localServerBaseURL, LocalAI.localServerDefaultBaseURL)
        XCTAssertEqual(settings.localContextTokens, 2048)
        XCTAssertEqual(settings.localMaxOutputTokens, 256)
        XCTAssertTrue(settings.localServerVision)
    }

    func testEmptySettingsUseTheOnDeviceModel() throws {
        let settings = try JSONDecoder().decode(SettingsManager.Settings.self, from: Data("{}".utf8))

        XCTAssertEqual(settings.activeProvider, .appleFoundation)
        XCTAssertEqual(settings.activeModelId, AvailableModels.appleOnDeviceId)
    }

    func testUnknownProviderFallsBackToTheDefault() throws {
        let json = #"{"activeProvider": "someRemovedEngine", "activeModelId": ""}"#
        let settings = try JSONDecoder().decode(SettingsManager.Settings.self, from: Data(json.utf8))

        XCTAssertEqual(settings.activeProvider, .appleFoundation)
        XCTAssertEqual(settings.activeModelId, AvailableModels.appleOnDeviceId)
    }

    func testModelFromAnotherProviderIsReplaced() throws {
        // A stored model that does not belong to the stored provider must not
        // survive: it would be sent to the wrong engine.
        let json = #"{"activeProvider": "openAI", "activeModelId": "gemini-2.5-pro"}"#
        let settings = try JSONDecoder().decode(SettingsManager.Settings.self, from: Data(json.utf8))

        XCTAssertEqual(settings.activeProvider, .openAI)
        XCTAssertEqual(settings.activeModelId, "gpt-4o")
    }

    func testDynamicProvidersStartWithoutAModel() {
        XCTAssertEqual(SettingsManager.Settings.defaultModelId(for: .ollama), "")
        XCTAssertEqual(SettingsManager.Settings.defaultModelId(for: .localServer), "")
        XCTAssertEqual(SettingsManager.Settings.defaultModelId(for: .appleFoundation), AvailableModels.appleOnDeviceId)
    }

    func testSettingsRoundTrip() throws {
        var settings = SettingsManager.Settings()
        settings.activeProvider = .localServer
        settings.activeModelId = "qwen3.5-2b"
        settings.localServerBaseURL = "http://127.0.0.1:8000/v1"
        settings.localContextTokens = 4096

        let data = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)

        XCTAssertEqual(restored.activeProvider, .localServer)
        XCTAssertEqual(restored.activeModelId, "qwen3.5-2b")
        XCTAssertEqual(restored.localServerBaseURL, "http://127.0.0.1:8000/v1")
        XCTAssertEqual(restored.localContextTokens, 4096)
    }

    // MARK: - Model catalogue

    func testAppleModelIsKnownForTheAppleProvider() {
        XCTAssertTrue(AvailableModels.isKnown(AvailableModels.appleOnDeviceId, for: .appleFoundation))
        XCTAssertFalse(AvailableModels.isKnown("gpt-4o", for: .appleFoundation))
    }

    func testDynamicProvidersAcceptReportedModels() {
        XCTAssertTrue(AvailableModels.isKnown("llama3.2:latest", for: .ollama))
        XCTAssertFalse(AvailableModels.isKnown("", for: .ollama))
    }

    func testDisplayNameFallsBackToTheIdentifier() {
        XCTAssertEqual(
            AvailableModels.displayName(for: AvailableModels.appleOnDeviceId, provider: .appleFoundation),
            "Apple Intelligence (on-device)")
        XCTAssertEqual(AvailableModels.displayName(for: "my-custom-model", provider: .ollama), "my-custom-model")
        XCTAssertEqual(AvailableModels.displayName(for: "", provider: .ollama), "No model selected")
    }

    // MARK: - Local engine errors

    func testImageRejectionIsRecognised() {
        let rejection = #"{"error":"this model does not support images"}"#
        XCTAssertTrue(OllamaStreamDelegate.looksLikeImageRejection(rejection))
        XCTAssertFalse(OllamaStreamDelegate.looksLikeImageRejection(#"{"error":"model not found"}"#))
    }

    func testShortMessageIsExtractedFromAnErrorBody() {
        let body = #"{"error":"model 'nope' not found, try pulling it first"}"#
        XCTAssertEqual(
            OllamaStreamDelegate.shortMessage(from: body),
            "model 'nope' not found, try pulling it first")
    }

    func testShortMessageTruncatesUnparsableBodies() {
        let body = String(repeating: "x", count: 500)
        XCTAssertEqual(OllamaStreamDelegate.shortMessage(from: body).count, 160)
    }

    // MARK: - Screenshots

    func testScreenshotIsDownscaledForLocalModels() {
        let image = makeImage(width: 1600, height: 1000)
        let resized = ScreenshotPayload.downscale(image, maxDimension: 768)

        XCTAssertNotNil(resized)
        XCTAssertEqual(resized?.width, 768)
        XCTAssertEqual(resized?.height, 480)
    }

    func testSmallScreenshotsAreLeftAlone() {
        let image = makeImage(width: 320, height: 200)
        let resized = ScreenshotPayload.downscale(image, maxDimension: 768)

        XCTAssertEqual(resized?.width, 320)
        XCTAssertEqual(resized?.height, 200)
    }

    func testUnreadableScreenshotDataYieldsNothing() {
        let payload = ScreenshotPayload(base64: "not-an-image")

        XCTAssertNil(payload.cgImage(maxDimension: 768))
        XCTAssertNil(payload.contextForTextOnlyModel())
    }

    func testTextOnlyPromptLeavesMessagesAloneWithoutScreenContext() {
        let prompt = localPrompt(message: "hello", screenshotBase64: nil, vision: .textOnly)
        XCTAssertEqual(prompt, "hello")
    }

    func testImageCapableProvidersDoNotFoldTextIntoThePrompt() {
        let prompt = localPrompt(message: "hello", screenshotBase64: "not-an-image", vision: .images)
        XCTAssertEqual(prompt, "hello")
    }

    // MARK: - On-device reading of the screen

    func testScreenshotTextIsReadOnDevice() throws {
        let image = try makeTextImage("export PATH monthly report budget")
        let text = try XCTUnwrap(ScreenshotPayload.recognizeText(in: image))
        XCTAssertTrue(
            text.lowercased().contains("monthly"),
            "the screen text was not read back: \(text)")
    }

    func testTextOnlyModelsReceiveTheScreenTextInThePrompt() throws {
        let jpeg = try jpegData(from: makeTextImage("export PATH monthly report budget"))
        let payload = ScreenshotPayload(base64: jpeg.base64EncodedString())

        let prompt = localPrompt(
            message: "what is on my screen?",
            screenshotBase64: payload.base64,
            vision: .textOnly)

        XCTAssertTrue(prompt.contains("[On-screen text"), prompt)
        XCTAssertTrue(prompt.lowercased().contains("monthly"), prompt)
    }

    /// Text rendered with Core Text, so this works without a window server.
    private func makeTextImage(_ string: String) throws -> CGImage {
        let width = 900
        let height = 200
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let attributes = [
            kCTFontAttributeName: CTFontCreateWithName("Helvetica" as CFString, 44, nil),
            kCTForegroundColorAttributeName: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ] as CFDictionary
        let text = try XCTUnwrap(
            CFAttributedStringCreate(nil, string as CFString, attributes))
        context.textPosition = CGPoint(x: 40, y: 90)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)

        return try XCTUnwrap(context.makeImage())
    }

    private func jpegData(from image: CGImage) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func makeImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }
}
