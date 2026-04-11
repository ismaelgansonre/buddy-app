import AppKit
import CoreGraphics
import ScreenCaptureKit

class ScreenContext {
    private static let chatEnabledKey = "screenContextChatEnabled"
    private static let commentsEnabledKey = "screenContextCommentsEnabled"

    /// Track if we've had a successful capture (permission is working)
    private static var hasSuccessfulCapture = false
    /// Track consecutive failures to avoid spamming
    private static var consecutiveFailures = 0

    static var chatEnabled: Bool {
        get { UserDefaults.standard.object(forKey: chatEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: chatEnabledKey) }
    }

    static var commentsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: commentsEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: commentsEnabledKey) }
    }

    static var enabled: Bool {
        get { chatEnabled || commentsEnabled }
        set { chatEnabled = newValue; commentsEnabled = newValue }
    }

    static var hasPermission: Bool {
        // On macOS 14+, CGPreflight may not reflect SCK permission state.
        // We optimistically return true and let the capture handle errors.
        if CGPreflightScreenCaptureAccess() { return true }
        if #available(macOS 14.0, *) {
            // If we've had a successful capture before, permission is good
            if hasSuccessfulCapture { return true }
            // Otherwise optimistically try — SCK will tell us if denied
            return true
        }
        return false
    }

    static func requestPermission() {
        NSLog("[ScreenContext] Requesting screen recording permission")
        // CGRequestScreenCaptureAccess triggers the system permission dialog
        // and registers the app in System Settings > Privacy > Screen Recording
        if !CGRequestScreenCaptureAccess() {
            NSLog("[ScreenContext] CGRequestScreenCaptureAccess returned false, opening settings")
            openScreenRecordingSettings()
        }
    }

    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Capture screenshot — uses ScreenCaptureKit on macOS 14+, legacy CGWindowList on older
    static func captureScreenshot(completion: @escaping (String?) -> Void) {
        // If we've had too many consecutive failures, skip to avoid spamming
        if consecutiveFailures >= 5 {
            NSLog("[ScreenContext] Too many consecutive failures (%d), skipping capture", consecutiveFailures)
            DispatchQueue.main.async { completion(nil) }
            return
        }

        if #available(macOS 14.0, *) {
            captureWithScreenCaptureKit(completion: completion)
        } else {
            captureWithLegacy(completion: completion)
        }
    }

    /// Reset failure counter (call when user re-enables screen context or grants permission)
    static func resetFailures() {
        consecutiveFailures = 0
    }

    // MARK: - ScreenCaptureKit (macOS 14+)

    @available(macOS 14.0, *)
    private static func captureWithScreenCaptureKit(completion: @escaping (String?) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            if let error = error {
                NSLog("[ScreenContext] SCShareableContent error: %@", error.localizedDescription)
                consecutiveFailures += 1
                // If permission denied, try opening settings on first failure
                if consecutiveFailures == 1 {
                    DispatchQueue.main.async {
                        openScreenRecordingSettings()
                    }
                }
                DispatchQueue.main.async { completion(nil) }
                return
            }

            guard let content = content, let display = content.displays.first else {
                NSLog("[ScreenContext] No display found")
                DispatchQueue.main.async { completion(nil) }
                return
            }

            // Exclude Buddy's own windows so it doesn't see itself
            let buddyPID = ProcessInfo.processInfo.processIdentifier
            let excludedWindows = content.windows.filter { $0.owningApplication?.processID == buddyPID }

            let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)

            let config = SCStreamConfiguration()
            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
            config.width = Int(CGFloat(display.width) * scale)
            config.height = Int(CGFloat(display.height) * scale)
            config.showsCursor = false

            SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, captureError in
                if let captureError = captureError {
                    NSLog("[ScreenContext] SCScreenshotManager error: %@", captureError.localizedDescription)
                    consecutiveFailures += 1
                    DispatchQueue.main.async { completion(nil) }
                    return
                }

                guard let image = image else {
                    NSLog("[ScreenContext] SCScreenshotManager returned nil image")
                    DispatchQueue.main.async { completion(nil) }
                    return
                }

                NSLog("[ScreenContext] ScreenCaptureKit capture OK: %dx%d", image.width, image.height)
                hasSuccessfulCapture = true
                consecutiveFailures = 0
                processImage(image, completion: completion)
            }
        }
    }

    // MARK: - Legacy (macOS 13)

    private static func captureWithLegacy(completion: @escaping (String?) -> Void) {
        guard CGPreflightScreenCaptureAccess() else {
            NSLog("[ScreenContext] No legacy permission")
            DispatchQueue.main.async { completion(nil) }
            return
        }

        DispatchQueue.global(qos: .utility).async {
            guard let cgImage = CGWindowListCreateImage(
                CGRect.null, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution]
            ) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            processImage(cgImage, completion: completion)
        }
    }

    // MARK: - Image Processing

    private static func processImage(_ cgImage: CGImage, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let maxDim: CGFloat = 1024
            let w = CGFloat(cgImage.width)
            let h = CGFloat(cgImage.height)
            let scale = min(maxDim / w, maxDim / h, 1.0)
            let newW = Int(w * scale)
            let newH = Int(h * scale)

            guard let ctx = CGContext(
                data: nil, width: newW, height: newH,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            ctx.interpolationQuality = .high
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: newW, height: newH))

            guard let resized = ctx.makeImage() else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let rep = NSBitmapImageRep(cgImage: resized)
            guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.6]) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let base64 = jpeg.base64EncodedString()
            NSLog("[ScreenContext] Screenshot: %dx%d, %d bytes", newW, newH, base64.count)

            // Debug: save to disk so we can verify content
            let debugPath = "/tmp/buddy_last_screenshot.jpg"
            try? jpeg.write(to: URL(fileURLWithPath: debugPath))

            DispatchQueue.main.async { completion(base64) }
        }
    }
}
