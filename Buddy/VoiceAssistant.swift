import Foundation
import AVFoundation
import NaturalLanguage

/// Voice assistant using bundled whisper.cpp for speech-to-text and AVSpeechSynthesizer for text-to-speech.
/// Whisper binary and model are packaged inside the app bundle — zero external installs needed.
final class VoiceAssistant: NSObject {

    enum State {
        case idle, listening, processing, speaking
    }

    private(set) var state: State = .idle {
        didSet { DispatchQueue.main.async { self.onStateChanged?(self.state) } }
    }

    var onStateChanged: ((State) -> Void)?
    var onTranscription: ((String) -> Void)?
    var onFinalText: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var levelTimer: Timer?
    private var silentSeconds: Double = 0
    private var hasHeardSpeech = false

    // Bundled whisper paths (inside the .app bundle)
    private static let whisperBinary: String = {
        if let path = Bundle.main.path(forResource: "whisper-cli", ofType: nil) {
            return path
        }
        // Fallback: check Resources directory directly
        let bundlePath = Bundle.main.bundlePath
        let resourcePath = bundlePath + "/Contents/Resources/whisper-cli"
        if FileManager.default.fileExists(atPath: resourcePath) {
            return resourcePath
        }
        return "/opt/homebrew/bin/whisper-cli"
    }()

    private static let modelPath: String = {
        if let path = Bundle.main.path(forResource: "ggml-base.en", ofType: "bin") {
            return path
        }
        // Fallback: check Resources directory directly
        let bundlePath = Bundle.main.bundlePath
        let resourcePath = bundlePath + "/Contents/Resources/ggml-base.en.bin"
        if FileManager.default.fileExists(atPath: resourcePath) {
            return resourcePath
        }
        return FileManager.default.homeDirectoryForCurrentUser.path + "/.buddy/models/ggml-base.en.bin"
    }()

    var isAvailable: Bool {
        FileManager.default.fileExists(atPath: Self.whisperBinary) &&
        FileManager.default.fileExists(atPath: Self.modelPath)
    }

    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
    }

    // MARK: - Start Listening

    func startListening() {
        if state == .listening { stopListening(); return }

        guard isAvailable else {
            NSLog("[Voice] whisper-cli: %@, model: %@", Self.whisperBinary, Self.modelPath)
            onError?("Voice not available. Whisper model missing from app bundle.")
            return
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("buddy_\(Int(Date().timeIntervalSince1970)).wav")
        recordingURL = url

        // 16kHz mono 16-bit PCM -- exactly what whisper wants
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.record()
            state = .listening
            silentSeconds = 0
            hasHeardSpeech = false
            NSLog("[Voice] Recording started → %@", url.path)

            // Poll audio levels for silence detection
            levelTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
                self?.checkAudioLevel()
            }
        } catch {
            NSLog("[Voice] Record failed: %@", error.localizedDescription)
            onError?("mic not available")
        }
    }

    private func checkAudioLevel() {
        guard let recorder = audioRecorder, recorder.isRecording else { return }
        recorder.updateMeters()
        let level = recorder.averagePower(forChannel: 0) // dB, silence ~ -160, speech ~ -30 to -10

        if level > -40 {
            hasHeardSpeech = true
            silentSeconds = 0
        } else {
            silentSeconds += 0.3
        }

        // Auto-stop: 2s silence after hearing speech, or 5s if never heard speech
        let timeout = hasHeardSpeech ? 2.0 : 5.0
        if silentSeconds >= timeout && hasHeardSpeech {
            stopListening()
        }

        // Hard timeout: 30 seconds
        if recorder.currentTime > 30 {
            stopListening()
        }
    }

    // MARK: - Stop & Transcribe

    func stopListening() {
        guard state == .listening else { return }
        levelTimer?.invalidate()
        levelTimer = nil
        audioRecorder?.stop()
        audioRecorder = nil

        state = .processing

        guard let url = recordingURL, FileManager.default.fileExists(atPath: url.path) else {
            NSLog("[Voice] No recording file")
            state = .idle
            return
        }

        // Check file size -- too small means no real audio
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        NSLog("[Voice] Recording size: %d bytes", size)
        if size < 5000 {
            NSLog("[Voice] Recording too short, skipping")
            try? FileManager.default.removeItem(at: url)
            state = .idle
            return
        }

        transcribe(fileURL: url)
    }

    private func transcribe(fileURL: URL) {
        NSLog("[Voice] Transcribing %@", fileURL.path)
        DispatchQueue.main.async { self.onTranscription?("transcribing...") }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: Self.whisperBinary)
            proc.arguments = [
                "-m", Self.modelPath,
                "-f", fileURL.path,
                "-np",
                "-nt",
                "-l", "en",
            ]

            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            do {
                try proc.run()
                proc.waitUntilExit()
            } catch {
                NSLog("[Voice] whisper failed: %@", error.localizedDescription)
                DispatchQueue.main.async {
                    self?.onError?("whisper failed")
                    self?.state = .idle
                }
                return
            }

            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let rawOut = String(data: outData, encoding: .utf8) ?? ""
            let rawErr = String(data: errData, encoding: .utf8) ?? ""

            NSLog("[Voice] whisper stdout: %@", rawOut)
            if !rawErr.isEmpty { NSLog("[Voice] whisper stderr (last 200): %@", String(rawErr.suffix(200))) }

            // Clean whisper output -- remove [BLANK_AUDIO], brackets, extra whitespace
            let text = rawOut
                .replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
                .replacingOccurrences(of: "(BLANK_AUDIO)", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            try? FileManager.default.removeItem(at: fileURL)

            DispatchQueue.main.async {
                guard let self = self else { return }
                if text.isEmpty {
                    NSLog("[Voice] Empty transcription")
                    self.onTranscription?("")
                    self.state = .idle
                } else {
                    NSLog("[Voice] Final text: %@", text)
                    self.onFinalText?(text)
                    // DON'T set state to idle here -- caller handles it after AI responds
                }
            }
        }
    }

    // MARK: - Text-to-Speech (Apple built-in)

    private var playProcess: Process?
    private(set) var isSpeakingQueue = false
    private(set) var sayProcess: Process?

    func speak(_ text: String) {
        stopSpeaking()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isSpeakingQueue = true
        state = .speaking

        // Pick the best available voice
        let voice: AVSpeechSynthesisVoice? = {
            // Try premium voices first (best quality, user must download)
            let premiumIds = [
                "com.apple.voice.premium.en-US.Zoe",
                "com.apple.voice.premium.en-US.Ava",
                "com.apple.voice.premium.en-US.Samantha",
            ]
            for id in premiumIds {
                if let v = AVSpeechSynthesisVoice(identifier: id) { return v }
            }
            // Then enhanced voices
            let enhancedIds = [
                "com.apple.voice.enhanced.en-US.Samantha",
                "com.apple.voice.enhanced.en-US.Ava",
            ]
            for id in enhancedIds {
                if let v = AVSpeechSynthesisVoice(identifier: id) { return v }
            }
            return AVSpeechSynthesisVoice(language: "en-US")
        }()

        // Split into sentences for natural pauses
        let sentences = splitIntoSentences(trimmed)

        for (index, sentence) in sentences.enumerated() {
            let utterance = AVSpeechUtterance(string: sentence)
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92 // slightly slower for clarity
            utterance.pitchMultiplier = 1.0
            utterance.volume = 1.0
            utterance.voice = voice

            // Add pause between sentences (not after the last one)
            if index < sentences.count - 1 {
                utterance.postUtteranceDelay = 0.35
            }

            synthesizer.speak(utterance)
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while self?.synthesizer.isSpeaking == true {
                Thread.sleep(forTimeInterval: 0.1)
            }
            DispatchQueue.main.async {
                self?.isSpeakingQueue = false
                if self?.state == .speaking { self?.state = .idle }
            }
        }
    }

    /// Split text into sentences preserving punctuation
    private func splitIntoSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                sentences.append(sentence)
            }
            return true
        }
        // Fallback if tokenizer returns nothing
        if sentences.isEmpty { sentences = [text] }
        return sentences
    }

    // Legacy compat stubs
    func queueSentence(_ sentence: String) { speak(sentence) }
    func startSpeaking() {}
    func streamText(_ text: String) {}
    func finishSpeaking() {}

    func stopSpeaking() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        if let p = playProcess, p.isRunning { p.terminate() }
        playProcess = nil
        sayProcess = nil
        isSpeakingQueue = false
        if state == .speaking { state = .idle }
    }
}
