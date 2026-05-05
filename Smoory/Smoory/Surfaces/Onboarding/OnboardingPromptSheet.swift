import SwiftUI

struct OnboardingPromptSheet: View {
    let onStart: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)

            Text("Welcome to Smoory")
                .font(.largeTitle.bold())

            Text("Spend 20–30 minutes getting Smoory to know you. We'll go through your roles, goals, projects, key people, and the tools you use. Or skip and chat freely.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)

            HStack(spacing: 12) {
                Button("Skip for now", action: onSkip)
                    .buttonStyle(.bordered)
                Button("Start onboarding", action: onStart)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(40)
        // F-21 audit fix: hard `minWidth: 460` clipped the sheet on narrower app windows.
        // Drop the min and let the text reflow; ideal/max keep the comfortable reading
        // width when there's room.
        .frame(idealWidth: 520, maxWidth: 600)
    }
}
