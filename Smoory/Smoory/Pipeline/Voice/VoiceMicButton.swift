import Speech
import SwiftUI

/// 4.11 — reusable mic button. Tapping starts dictation via the shared
/// `VoiceCaptureService`; tapping again stops and writes the final transcript into
/// the bound `draft` text. Live partials show inline by appending to draft as they
/// arrive (tracked via .onChange on the service's liveTranscript).
struct VoiceMicButton: View {
    @Bindable var service: VoiceCaptureService
    @Binding var draft: String

    /// Surface "couldn't start the mic" via the shared toast — replaces the
    /// previous `print()`-and-no-feedback path.
    @Environment(\.errorBus) private var errorBus

    /// Snapshot of the draft text taken at the moment capture starts. The live
    /// transcript is appended to this snapshot each frame so partial corrections
    /// from the recognizer (which can rewrite earlier words) don't cause flicker.
    @State private var snapshot: String = ""

    var body: some View {
        Button {
            // @MainActor-explicit so the captured @State mutation in toggle()
            // is guaranteed on main even if the Button hook doesn't inherit.
            Task { @MainActor in await toggle() }
        } label: {
            Image(systemName: service.isCapturing ? "mic.fill" : "mic")
                .foregroundStyle(service.isCapturing ? Color.red : Color.secondary)
                .font(.title3)
        }
        .buttonStyle(.plain)
        .help(service.isCapturing ? "Stop dictation" : "Start dictation")
        .onChange(of: service.liveTranscript) { _, new in
            guard service.isCapturing else { return }
            // Replace the post-snapshot tail with the new live transcript.
            let trailing = new.isEmpty ? "" : (snapshot.isEmpty || snapshot.last == " " ? new : " " + new)
            draft = snapshot + trailing
        }
    }

    private func toggle() async {
        if service.isCapturing {
            service.stop()
            // Final transcript already pushed into draft via .onChange. Clear the
            // service's buffer so the next session starts clean.
            service.reset()
        } else {
            snapshot = draft
            let started = await service.start()
            if !started {
                print("[voice] start failed — auth or recognizer unavailable")
                errorBus?.report(failureMessage())
            }
        }
    }

    /// Branches the toast message based on which permission tier failed so the
    /// user knows where to go next. Speech and mic are independent permissions
    /// on macOS — either can be the blocker.
    private func failureMessage() -> String {
        if service.speechAuth == .denied || service.speechAuth == .restricted {
            return "Speech recognition is denied. Enable it in System Settings → Privacy & Security → Speech Recognition, then try again."
        }
        if !service.micAuthGranted {
            return "Microphone access is required. Check System Settings → Privacy & Security → Microphone, then try again."
        }
        return "Mic unavailable. The recognizer didn't start — try again, or restart Smoory if it persists."
    }
}
