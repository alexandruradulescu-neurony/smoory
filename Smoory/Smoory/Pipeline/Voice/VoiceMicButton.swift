import SwiftUI

/// 4.11 — reusable mic button. Tapping starts dictation via the shared
/// `VoiceCaptureService`; tapping again stops and writes the final transcript into
/// the bound `draft` text. Live partials show inline by appending to draft as they
/// arrive (tracked via .onChange on the service's liveTranscript).
struct VoiceMicButton: View {
    @Bindable var service: VoiceCaptureService
    @Binding var draft: String

    /// Snapshot of the draft text taken at the moment capture starts. The live
    /// transcript is appended to this snapshot each frame so partial corrections
    /// from the recognizer (which can rewrite earlier words) don't cause flicker.
    @State private var snapshot: String = ""

    var body: some View {
        Button {
            Task { await toggle() }
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
                // Permission denied or recognizer unavailable. Surface in UI later
                // (e.g., a toast); for now, no-op so the button doesn't get stuck.
                print("[voice] start failed — auth or recognizer unavailable")
            }
        }
    }
}
