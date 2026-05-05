import AVFoundation
import Foundation
import Observation
import Speech

/// 4.11 — voice dictation service used by the day-review, week-review, and end-of-day
/// sheets (and the main chat input bar) so users can speak into the input field
/// instead of typing. Wraps `SFSpeechRecognizer` + `AVAudioEngine`. Single shared
/// instance per app lifetime; only one capture session can be active at a time.
///
/// Authorization is two-tier: speech recognition (`SFSpeechRecognizer`) and microphone
/// (`AVAudioApplication.requestRecordPermission` on macOS 14+, `AVCaptureDevice` on older
/// — we target macOS 14, so the unified permission API applies). Both are requested on
/// first `start()` if not already granted; `start()` returns false when either is denied.
@Observable
@MainActor
final class VoiceCaptureService {
    /// Live partial transcript. Updated as the recognizer emits results. Reset by
    /// `reset()` so callers can append the value to a draft and clear it.
    private(set) var liveTranscript: String = ""

    /// True between `start()` returning success and `stop()` being called.
    private(set) var isCapturing: Bool = false

    /// nil when authorization hasn't been resolved yet. Once resolved, mirrors the
    /// `SFSpeechRecognizerAuthorizationStatus` raw value so UI can branch on it.
    private(set) var speechAuth: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    private(set) var micAuthGranted: Bool = false

    private let recognizer: SFSpeechRecognizer? = SFSpeechRecognizer()
    private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    var isAvailable: Bool {
        recognizer?.isAvailable == true
    }

    /// Requests speech + mic permission. Returns true only when both are granted.
    /// Safe to call repeatedly — short-circuits when both are already granted.
    func ensureAuthorization() async -> Bool {
        if speechAuth != .authorized {
            speechAuth = await Self.requestSpeechAuthorization()
        }
        if !micAuthGranted {
            micAuthGranted = await Self.requestMicrophoneAuthorization()
        }
        return speechAuth == .authorized && micAuthGranted
    }

    /// Starts a recognition session. Returns false if authorization isn't granted, the
    /// recognizer is unavailable, or the audio engine fails to start. On success the
    /// receiver holds onto the engine + task until `stop()` is called.
    @discardableResult
    func start() async -> Bool {
        guard !isCapturing else { return true }
        guard await ensureAuthorization() else { return false }
        guard let recognizer, recognizer.isAvailable else { return false }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            print("[voice] audio engine start failed: \(error)")
            inputNode.removeTap(onBus: 0)
            self.request = nil
            return false
        }
        self.audioEngine = engine

        liveTranscript = ""
        self.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Inner task uses [weak self] for symmetry — outer closure is already
            // weak, but the inner Task strongly captured self via `guard let self`.
            // Each result emission would have spawned a new strong-self task that
            // outlived the closure. Now both layers let go cleanly on tear-down.
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    self.liveTranscript = result.bestTranscription.formattedString
                }
                if error != nil || result?.isFinal == true {
                    self.cleanupEngine()
                }
            }
        }
        isCapturing = true
        return true
    }

    /// Stops the active session. The current `liveTranscript` value is preserved so the
    /// caller can read and reset it.
    func stop() {
        guard isCapturing else { return }
        request?.endAudio()
        cleanupEngine()
    }

    /// Clears `liveTranscript`. Caller should invoke after consuming the value.
    func reset() {
        liveTranscript = ""
    }

    // MARK: - Internals

    private func cleanupEngine() {
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
        task?.cancel()
        task = nil
        request = nil
        isCapturing = false
    }

    private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private static func requestMicrophoneAuthorization() async -> Bool {
        if #available(macOS 14.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            // Fallback path — never hit at runtime since CLAUDE.md sets min OS to 14.
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }
}
