import SwiftUI
import SwiftData

/// Root sheet view for the "Add Machine" onboarding wizard.
///
/// Shown via `.sheet(isPresented:)` from `RootView`. Builds a
/// `NavigationStack` around a typed `Destination` enum, owns the
/// `EphemeralSetupState` reference, and drives the initial SSH handshake
/// that transitions from the connection form to the fingerprint-confirm
/// step.
///
/// ### Navigation model
///
/// A `@State var path: [Destination]` holds the stack. Push by appending;
/// pop via `path.removeLast()`. The root `ConnectionFormView` isn't on the
/// path — it's the `NavigationStack`'s root content. Every subsequent step
/// is a `Destination` case.
///
/// Choosing `[Destination]` over `NavigationPath` makes `path.last` and
/// `removeLast()` straightforward, and keeps the type we're working with
/// visible at every call site. `NavigationPath` would erase the enum.
///
/// ### EphemeralSetupState (ref doc §11)
///
/// All cross-step state lives on the `@State private var state = EphemeralSetupState()`
/// reference. Mutations are visible synchronously to every view we push,
/// which sidesteps the `@State` value-type race the ref doc calls out.
/// The state is `@Observable` so views that `@Bindable` into it re-render
/// on field updates without plumbing.
///
/// ### Initial handshake
///
/// `ConnectionFormView`'s "Continue" calls us back via `advanceFromForm`:
/// we build the SSH auth, open a connection, capture the host-key
/// fingerprint, store it on `state.pendingHostFingerprint` +
/// `state.sshUserIsRoot`, disconnect, and push `.fingerprint`. We do not
/// retain the `SSHService` past this point — installer + recovery each
/// manage their own connections.
struct AddServerFlow: View {
    @Environment(\.dismiss) private var dismiss

    /// The wizard's cross-step data bucket. Reference-typed so navigation
    /// closures see writes synchronously (ref doc §11).
    @State private var state = EphemeralSetupState()

    /// Typed navigation stack. Each case is a step beyond the form.
    @State private var path: [Destination] = []

    /// Error message from the initial handshake, shown inline above the
    /// form's toolbar so the user knows why Continue stopped working.
    @State private var handshakeError: String?
    /// Spinner flag while the initial SSH connect is in flight.
    @State private var handshakeInFlight: Bool = false

    /// Destinations beyond the root form. Hashable so
    /// `navigationDestination(for:)` can discriminate, Equatable for
    /// `onChange` diffing where needed.
    enum Destination: Hashable {
        /// Enter password or import/select SSH key.
        case authDetail
        /// Post-handshake host-key confirmation.
        case fingerprint
        /// Drive the installer stream.
        case install
        /// Success summary.
        case done
    }

    var body: some View {
        NavigationStack(path: $path) {
            ConnectionFormView(
                state: state,
                onContinue: { path.append(.authDetail) }
            )
            .overlay(alignment: .bottom) { handshakeOverlay }
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .authDetail:
                    AuthDetailView(
                        state: state,
                        onContinue: advanceFromAuthDetail
                    )
                    .overlay(alignment: .bottom) { handshakeOverlay }
                case .fingerprint:
                    HostFingerprintView(
                        state: state,
                        onTrust: advanceFromFingerprint,
                        onCancel: { path.removeLast() }
                    )
                    .overlay(alignment: .bottom) { handshakeOverlay }
                case .install:
                    InstallProgressView(
                        state: state,
                        onSuccess: advanceFromInstall,
                        onCancel: { path.removeLast() }
                    )
                case .done:
                    DoneView(state: state, onDismiss: finishAndDismiss)
                }
            }
        }
        .interactiveDismissDisabled(isSheetBusy)
    }

    // MARK: - Handshake overlay (shown over the form while we connect)

    @ViewBuilder
    private var handshakeOverlay: some View {
        if handshakeInFlight {
            HStack(spacing: 10) {
                ProgressView()
                Text("Connecting to \(state.host)…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(.bottom, 20)
            .transition(.opacity)
        } else if let msg = handshakeError {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(msg)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.leading)
                Spacer()
                Button("Dismiss") { handshakeError = nil }
                    .font(.footnote)
            }
            .padding(10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
            .transition(.opacity)
        }
    }

    /// True whenever we're in a step the user can't safely interactive-
    /// dismiss out of. Mid-install we especially don't want a swipe to
    /// cancel: the server-side install keeps running, but we'd lose the
    /// ability to complete persistence.
    private var isSheetBusy: Bool {
        handshakeInFlight || path.contains(.install)
    }

    // MARK: - Step transitions

    /// Called by `AuthDetailView` when the user taps Continue.
    ///
    /// - Build the SSH auth from state.
    /// - Do the initial SSH handshake.
    /// - Capture the host fingerprint + root flag.
    /// - Disconnect.
    /// - Push `.fingerprint`.
    private func advanceFromAuthDetail() {
        // Clear any prior error so the spinner alone is visible.
        handshakeError = nil
        handshakeInFlight = true

        Task { @MainActor in
            defer { handshakeInFlight = false }

            // Inputs: pulled now so we don't close over the state object
            // mutably (it IS a reference type but we only need scalars).
            guard let port = state.port else {
                handshakeError = "Invalid port."
                return
            }
            let host = state.host
            let username = state.sshUsername

            // Branch on auth. For the key path, the user must have Verified
            // the key already (ConnectionFormView disables Continue
            // otherwise for the key branch).
            let ssh = SSHService()
            do {
                switch state.authMethod {
                case .password:
                    guard !state.sshPassword.isEmpty else {
                        handshakeError = "Enter a password first."
                        return
                    }
                    let info = try await ssh.connect(
                        host: host,
                        port: port,
                        username: username,
                        password: state.sshPassword,
                        expectedFingerprint: nil
                    )
                    state.pendingHostFingerprint = info.fingerprint
                case .key:
                    // If the key branch was taken but the user hasn't
                    // verified yet (e.g. they skipped straight to form
                    // Continue), re-parse. We already disable Continue on
                    // an empty PEM so this is rare.
                    guard let parsed = state.parsedKey else {
                        handshakeError = "Verify the SSH key on the previous step first."
                        return
                    }
                    switch parsed {
                    case .ed25519(let priv):
                        let info = try await ssh.connectWithEd25519Key(
                            host: host,
                            port: port,
                            username: username,
                            privateKey: priv,
                            expectedFingerprint: nil
                        )
                        state.pendingHostFingerprint = info.fingerprint
                    case .rsa(let priv):
                        let info = try await ssh.connectWithRSAKey(
                            host: host,
                            port: port,
                            username: username,
                            privateKey: priv,
                            expectedFingerprint: nil
                        )
                        state.pendingHostFingerprint = info.fingerprint
                    }
                }

                // Cache the root flag for later step-skipping. Doing it
                // here (right after connect) means we only pay for one
                // `id -u` round-trip.
                state.sshUserIsRoot = await ssh.sshUserIsRoot()

                // Disconnect — the installer and recovery layers each open
                // their own connection. Keeping this one around would
                // contend with them (ref doc §12 #12).
                await ssh.disconnect()

                path.append(.fingerprint)
            } catch let err as SSHService.SSHError {
                await ssh.disconnect()
                handshakeError = describe(err)
            } catch {
                await ssh.disconnect()
                handshakeError = error.localizedDescription
            }
        }
    }

    /// Called by `HostFingerprintView` when the user taps Trust.
    ///
    /// Install requires sudo. Three sub-cases:
    /// - SSH user is root → no sudo password needed.
    /// - Non-root + password auth → reuse the SSH password for sudo (one
    ///   prompt, not two). The installer validates it as its first step and
    ///   a bad password fails fast and loudly.
    /// - Non-root + key auth → we have no password to use for sudo. Rather
    ///   than prompting for a second secret and confusing the mental model,
    ///   error out and ask the user to SSH as root (or a user with
    ///   passwordless sudo).
    private func advanceFromFingerprint() {
        if state.sshUserIsRoot {
            state.sudoPassword = ""
            path.append(.install)
            return
        }
        switch state.authMethod {
        case .password:
            state.sudoPassword = state.sshPassword
            path.append(.install)
        case .key:
            // Can't run sudo without a password, and won't prompt for a second
            // secret. Pop back to the form so the user can change username.
            handshakeError = "Installing on a non-root user requires password auth so PocketTop can run sudo. Sign in with a root-capable user (or one with passwordless sudo) to use an SSH key."
            path.removeAll()
        }
    }

    /// Called by `InstallProgressView` after install + persistence
    /// succeeded. `state.server` is now populated.
    private func advanceFromInstall() {
        path.append(.done)
    }

    /// Called by `DoneView`'s "Go to Home" button. Post the notification
    /// and dismiss the sheet.
    private func finishAndDismiss() {
        if let server = state.server {
            NotificationCenter.default.post(
                name: .serverSetupComplete,
                object: server
            )
        }
        dismiss()
    }

    // MARK: - Error shaping

    /// Turn an `SSHService.SSHError` into a user-readable line. Host-key
    /// mismatches get their own callout because they're a security-
    /// sensitive event rather than a generic connect failure.
    private func describe(_ err: SSHService.SSHError) -> String {
        switch err {
        case .hostKeyMismatch(let expected, let actual):
            return "Host key mismatch (expected \(expected.prefix(20))…, got \(actual.prefix(20))…). Refusing to connect."
        case .commandFailed(let code, _, _):
            return "Remote command failed (exit \(code))."
        case .uploadSizeMismatch(let expected, let got):
            return "Upload verification failed (\(got)/\(expected) bytes)."
        case .alreadyConnected:
            return "SSH already connected."
        case .notConnected:
            return "SSH not connected."
        case .underlying(let e):
            return "Connect failed: \(e.localizedDescription)"
        }
    }
}
