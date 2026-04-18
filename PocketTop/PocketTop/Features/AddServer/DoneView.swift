import SwiftUI

/// Step 6: success confirmation.
///
/// Rendered after `InstallProgressView` persisted the `Server`, saved the
/// API key, and populated `state.server`. Pure summary + dismiss — no
/// business logic. The "Go to Home" button triggers the parent's dismiss
/// handler, which is also responsible for posting
/// `Notification.Name.serverSetupComplete` (defined in
/// `Notifications.swift`) so the rest of the app can react (e.g., auto-
/// navigate to the new server's detail screen).
struct DoneView: View {
    @Bindable var state: EphemeralSetupState

    /// Called when the user taps "Go to Home". The parent (`AddServerFlow`)
    /// dismisses the sheet and posts the `.serverSetupComplete`
    /// notification.
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 72))
                .foregroundStyle(.green)

            Text("Ready to roll")
                .font(.title.weight(.semibold))

            VStack(spacing: 4) {
                if let server = state.server {
                    Text(server.name)
                        .font(.headline)
                    Text(server.host)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    // Defensive — should never be reached because we only
                    // navigate here after `state.server` is set. Degrade
                    // gracefully with the form data rather than crashing.
                    Text(state.effectiveName)
                        .font(.headline)
                    Text(state.host)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)

            Text("PocketTop will now poll this machine over HTTPS. Pull the sheet down or tap Go to Home to start watching it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()

            Button {
                onDismiss()
            } label: {
                Text("Go to Home")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .navigationTitle("Done")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
    }
}
