import Foundation
import Observation
import SwiftUI

/// F-6/F-7/F-23 audit fix: cross-surface error toast for mutation failures.
/// Pre-fix, dozens of `do { … } catch { print(…) }` paths swallowed errors
/// silently — defer / archive / save / sync / etc. all reported nothing to
/// the user when they failed. Each handler now does `errorBus.report("…")`
/// instead of `print("…")` and the user sees a transient banner over the
/// detail pane.
///
/// The bus is intentionally a single shared instance per window (held as
/// `@State` on `SmooryApp` and injected via `\.errorBus`). It owns one
/// active toast at a time; a new report replaces the old one (latest wins).
/// Toasts auto-dismiss after `Self.autoDismissSeconds`.
@Observable
@MainActor
final class ErrorBus {
    struct Toast: Identifiable, Equatable {
        let id: UUID = UUID()
        let message: String
        let createdAt: Date = Date()

        static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }
    }

    private(set) var current: Toast?

    static let autoDismissSeconds: UInt64 = 4

    func report(_ message: String) {
        let toast = Toast(message: message)
        current = toast
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.autoDismissSeconds * 1_000_000_000)
            // Only auto-clear if the same toast is still showing — a newer
            // report may have replaced it in the meantime.
            if self?.current?.id == toast.id {
                self?.current = nil
            }
        }
    }

    func dismiss() {
        current = nil
    }
}

/// Top-anchored banner. Slides down from the title-bar area, dismisses with the
/// red `xmark` button or auto-clears after 4 seconds.
struct ErrorBannerOverlay: View {
    @Bindable var bus: ErrorBus

    var body: some View {
        Group {
            if let toast = bus.current {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .padding(.top, 1)
                    Text(toast.message)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                    Spacer(minLength: 8)
                    Button {
                        bus.dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.thickMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(color: Color.black.opacity(0.18), radius: 8, y: 3)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .frame(maxWidth: 560)
                .transition(.move(edge: .top).combined(with: .opacity))
                .id(toast.id)
            }
        }
        .animation(.spring(duration: 0.25), value: bus.current?.id)
    }
}
