import AppKit
import Foundation
import Vision

// MARK: - Local endpoints

/// Helpers for talking to engines that run on this Mac.
///
/// Buddy only ever connects to loopback addresses for the "local server"
/// providers, so a mistyped or redirected endpoint can never silently send
/// screen content to another machine.
enum LocalAI {
    /// Ollama's default bind address.
    static let ollamaDefaultBaseURL = "http://127.0.0.1:11434"
    /// LM Studio / llama.cpp / any OpenAI-compatible server on this Mac.
    static let localServerDefaultBaseURL = "http://127.0.0.1:1234/v1"

    /// Hosts that are guaranteed to be on this machine.
    private static let loopbackHosts: Set<String> = [
        "127.0.0.1", "localhost", "::1", "[::1]",
    ]

    /// True when the URL points at loopback and uses a local scheme.
    static func isLoopback(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        guard let host = url.host?.lowercased() else { return false }
        return loopbackHosts.contains(host)
    }

    /// Normalize a user-entered base URL, falling back to the default.
    /// Returns nil when the value is not a loopback HTTP URL.
    static func normalizedBaseURL(_ raw: String, fallback: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty ? fallback : trimmed
        guard let url = URL(string: candidate), isLoopback(url) else { return nil }
        return url
    }

    static func ollamaBaseURL() -> URL {
        normalizedBaseURL(SettingsManager.shared.settings.ollamaBaseURL, fallback: ollamaDefaultBaseURL)
            ?? URL(string: ollamaDefaultBaseURL)!
    }

    static func localServerBaseURL() -> URL {
        normalizedBaseURL(SettingsManager.shared.settings.localServerBaseURL, fallback: localServerDefaultBaseURL)
            ?? URL(string: localServerDefaultBaseURL)!
    }

    /// Short message shown when an endpoint is rejected.
    static let nonLoopbackMessage =
        "Local engines must use an address on this Mac, like 127.0.0.1 or localhost."
}

// MARK: - Screenshot handling for local models

/// A screenshot that local engines can either look at directly or read as text.
struct ScreenshotPayload {
    /// Raw base64 JPEG, as produced by `ScreenContext.captureScreenshot`.
    let base64: String

    /// Downscaled image, or nil when the data could not be decoded.
    /// Local vision models get a smaller frame so memory stays bounded.
    func cgImage(maxDimension: CGFloat) -> CGImage? {
        guard let data = Data(base64Encoded: base64), let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return Self.downscale(image, maxDimension: maxDimension)
    }

    /// Text extracted on-device, used when the active model cannot see images.
    func recognizedText() -> String? {
        guard let data = Data(base64Encoded: base64), let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return Self.recognizeText(in: image)
    }

    /// A prompt that still carries screen context for text-only models.
    func contextForTextOnlyModel(maxCharacters: Int = 1200) -> String? {
        guard let text = recognizedText() else { return nil }
        let collapsed =
            text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        let clipped = collapsed.count > maxCharacters ? String(collapsed.prefix(maxCharacters)) : collapsed
        return clipped
    }

    static func downscale(_ image: CGImage, maxDimension: CGFloat) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let scale = min(maxDimension / max(width, height), 1.0)
        if scale >= 1.0 { return image }

        let newWidth = max(1, Int(width * scale))
        let newHeight = max(1, Int(height * scale))
        guard
            let context = CGContext(
                data: nil,
                width: newWidth,
                height: newHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage()
    }

    /// On-device OCR. Returns nil when nothing readable was found.
    ///
    /// The accurate recogniser needs model assets that are not always present,
    /// so the faster one is used as a fallback: a rougher reading of the screen
    /// is more useful than no context at all.
    static func recognizeText(in image: CGImage) -> String? {
        if let text = recognize(image, level: .accurate, detectsLanguage: true) {
            return text
        }
        let fallback = recognize(image, level: .fast, detectsLanguage: false)
        if fallback != nil {
            NSLog("[ScreenshotPayload] Accurate OCR unavailable, used the fast recogniser")
        }
        return fallback
    }

    private static func recognize(
        _ image: CGImage,
        level: VNRequestTextRecognitionLevel,
        detectsLanguage: Bool
    ) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = detectsLanguage

        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            NSLog("[ScreenshotPayload] OCR (%@) failed: %@",
                  level == .fast ? "fast" : "accurate", error.localizedDescription)
            return nil
        }

        guard let observations = request.results, !observations.isEmpty else { return nil }
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }
}

// MARK: - Prompt assembly

/// How a provider receives screen content.
enum VisionSupport {
    /// The model can be handed the image itself.
    case images
    /// The model only accepts text, so the screenshot is read on-device first.
    case textOnly
    /// No screen content at all.
    case none

    var acceptsImages: Bool { self == .images }
}

/// Build the prompt sent to a local engine, folding in screen context when the
/// model cannot see images.
func localPrompt(message: String, screenshotBase64: String?, vision: VisionSupport) -> String {
    guard vision == .textOnly, let base64 = screenshotBase64 else { return message }
    let payload = ScreenshotPayload(base64: base64)
    guard let context = payload.contextForTextOnlyModel() else { return message }
    return """
        \(message)

        [On-screen text, read locally by Buddy]
        \(context)
        """
}
