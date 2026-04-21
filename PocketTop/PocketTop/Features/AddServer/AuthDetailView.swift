import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

/// Step 2: gather the actual auth material (password or public-key copy), then
/// kick off the initial SSH handshake.
///
/// Branches:
/// 1. **Password** — user types a password, toggles "save to Keychain", taps
///    Continue. No verification here; the next step is the SSH handshake
///    which is the real test.
/// 2. **SSH Key (default: PocketTop's key)** — the app-wide Ed25519 keypair is
///    loaded (or generated on first use) and its public half displayed for the
///    user to copy into `~/.ssh/authorized_keys` on the server. Once added,
///    the user taps Continue and we attempt the handshake with the private
///    half.
/// 3. **SSH Key (alternative: import my own)** — user pastes a PEM or picks
///    one from Files, optionally supplies a passphrase, taps Verify, then
///    Continue.
///
/// ### Secure Input on macOS
/// `SecureField` can leave macOS in "Secure Input Mode" after the view is
/// dismissed, which disables some system-level keystrokes until the app quits.
/// We use `@FocusState` to explicitly release focus on `.onDisappear` and
/// right before the handshake fires, which lets AppKit tear down the secure
/// editor cleanly.
struct AuthDetailView: View {
    @Bindable var state: EphemeralSetupState

    /// Parent-owned handler. Runs the first SSH connect using whatever auth
    /// is now on `state` and pushes to the fingerprint step on success. We
    /// delegate rather than doing it here because the connection task
    /// depends on main-actor things the parent controls (loading spinner,
    /// navigation, Server row creation).
    let onContinue: () -> Void

    // MARK: - Local state

    /// UI state for PEM parsing. Collapses "waiting for user", "parsing",
    /// and "error displayed" into a single source of truth so the button and
    /// error message stay in sync.
    enum ParseState: Equatable {
        case idle
        case parsing
        case parsed
        case error(String)
    }

    /// Focus targets for `@FocusState`. Explicit cases keep us honest about
    /// which field currently owns focus so we can release Secure Input Mode
    /// on view disappearance (macOS regression workaround).
    enum Field: Hashable {
        case password
        case pem
        case passphrase
    }

    @State private var parseState: ParseState = .idle
    @State private var showingFileImporter = false
    @State private var showingAppKeyLoadError: String?
    @State private var isPasswordRevealed = false
    @FocusState private var focus: Field?

    var body: some View {
        Form {
            if state.authMethod == .password {
                passwordSection
            }

            if state.authMethod == .key {
                if state.useAppWideKey {
                    publicKeySection
                } else {
                    importKeySection
                }
            }
        }
        .navigationTitle(state.authMethod == .password ? "Password" : "SSH Key")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Continue") {
                    // Release Secure Input before handing off to the parent.
                    focus = nil
                    onContinue()
                }
                .disabled(!canContinue)
            }
        }
        .task(id: taskKey) {
            if state.authMethod == .key && state.useAppWideKey {
                await loadAppWideKey()
            }
        }
        .onDisappear {
            // Critical on macOS: dropping focus tells AppKit to exit Secure
            // Input Mode. Without this, keystrokes stay intercepted after the
            // user leaves this screen, until the app is quit.
            focus = nil
        }
        .alert(
            "Couldn't load saved key",
            isPresented: .init(
                get: { showingAppKeyLoadError != nil },
                set: { if !$0 { showingAppKeyLoadError = nil } }
            ),
            presenting: showingAppKeyLoadError
        ) { _ in
            Button("OK", role: .cancel) { showingAppKeyLoadError = nil }
        } message: { msg in
            Text(msg)
        }
    }

    /// Re-key the `.task` so it re-fires when the user toggles between
    /// generated-key and imported-key modes.
    private var taskKey: String {
        "\(state.authMethod.rawValue):\(state.useAppWideKey)"
    }

    // MARK: - Password section

    @ViewBuilder
    private var passwordSection: some View {
        Section {
            HStack {
                Group {
                    if isPasswordRevealed {
                        TextField("SSH Password", text: $state.sshPassword)
                    } else {
                        SecureField("SSH Password", text: $state.sshPassword)
                    }
                }
                .textContentType(.password)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focus, equals: .password)
                .submitLabel(.continue)
                .onSubmit {
                    if canContinue {
                        focus = nil
                        onContinue()
                    }
                }

                Button {
                    isPasswordRevealed.toggle()
                } label: {
                    Image(systemName: isPasswordRevealed ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isPasswordRevealed ? "Hide password" : "Show password")
            }
        } header: {
            Text("Password")
        } footer: {
            Text("Used for the initial SSH login. On non-root users this same password is reused for sudo to install the agent. After install, PocketTop switches to pinned HTTPS and won't use this password again unless you reinstall or upgrade.")
        }

        Section {
            Toggle("Save to Keychain", isOn: $state.savePasswordToKeychain)
        } footer: {
            Text("Stored with device-unlock protection. Doesn't require Face ID on read.")
        }
    }

    // MARK: - Public key section (default)

    @ViewBuilder
    private var publicKeySection: some View {
        Section {
            if let publicLine = state.generatedPublicLine {
                Text(publicLine)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else if case .error(let msg) = parseState {
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.footnote)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Preparing key…").font(.footnote)
                }
            }
        } header: {
            Text("Public Key")
        } footer: {
            Text("Add this line to `~/.ssh/authorized_keys` on the server, then tap Continue. PocketTop keeps the matching private key in the iOS Keychain — it never leaves your device.")
        }

        if state.generatedPublicLine != nil {
            Section {
                Button {
                    copyPublicKey()
                } label: {
                    Label("Copy Public Key", systemImage: "doc.on.doc")
                }

                ShareLink(
                    item: state.generatedPublicLine ?? "",
                    preview: SharePreview("PocketTop Public Key")
                ) {
                    Label("Share as File", systemImage: "square.and.arrow.up")
                }
            }

            if let fp = state.generatedPublicFingerprint {
                Section("Fingerprint") {
                    Text(fp)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            }
        }

        Section {
            Button("I have my own private key instead") {
                state.useAppWideKey = false
                parseState = .idle
                state.parsedKey = nil
            }
        }
    }

    // MARK: - Import-key section (opt-in alternative)

    @ViewBuilder
    private var importKeySection: some View {
        Section {
            TextEditor(text: $state.importedPEM)
                .font(.system(.footnote, design: .monospaced))
                .frame(minHeight: 140)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focus, equals: .pem)
                .overlay(alignment: .topLeading) {
                    if state.importedPEM.isEmpty {
                        Text("-----BEGIN OPENSSH PRIVATE KEY-----\n...")
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 4)
                            .allowsHitTesting(false)
                    }
                }
        } header: {
            Text("Private Key (PEM)")
        } footer: {
            Text("Paste an OpenSSH Ed25519 or RSA private key. The matching public key must already be in `~/.ssh/authorized_keys` on the server.")
        }

        Section {
            Button {
                showingFileImporter = true
            } label: {
                Label("Pick from Files", systemImage: "doc.badge.plus")
            }
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.data, .plainText],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }

        Section("Passphrase (optional)") {
            SecureField("Passphrase", text: $state.keyPassphrase)
                .textContentType(.password)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focus, equals: .passphrase)
        }

        Section {
            Toggle("Save as app-wide key", isOn: $state.saveKeyAsAppWide)
        } footer: {
            Text("Store this key once and reuse it when adding future machines.")
        }

        Section {
            Button {
                focus = nil
                verifyKey()
            } label: {
                HStack {
                    if parseState == .parsing {
                        ProgressView().controlSize(.small)
                    }
                    Text(parseState == .parsed ? "Re-verify" : "Verify Key")
                }
            }
            .disabled(state.importedPEM.trimmingCharacters(in: .whitespaces).isEmpty || parseState == .parsing)

            if case .error(let msg) = parseState {
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.footnote)
            } else if parseState == .parsed {
                Label("Key parsed successfully", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.footnote)
            }
        }

        Section {
            Button("Use PocketTop's generated key instead") {
                state.useAppWideKey = true
                state.importedPEM = ""
                state.keyPassphrase = ""
                state.parsedKey = nil
                parseState = .idle
            }
        }
    }

    // MARK: - Actions

    /// Whether the Continue button is enabled. Differs per branch:
    /// - Password: non-empty password.
    /// - Generated key mode: `state.parsedKey` populated (loaded lazily in `.task`).
    /// - Imported key mode: `state.parsedKey` populated (user must Verify first).
    private var canContinue: Bool {
        switch state.authMethod {
        case .password:
            return !state.sshPassword.isEmpty
        case .key:
            return state.parsedKey != nil
        }
    }

    private func verifyKey() {
        let pem = state.importedPEM
        let pass = state.keyPassphrase.isEmpty ? nil : state.keyPassphrase
        parseState = .parsing
        do {
            let parsed = try SSHKeyService.parsePrivateKey(pem: pem, passphrase: pass)
            state.parsedKey = parsed
            parseState = .parsed
        } catch SSHKeyService.KeyError.passphraseRequired {
            state.parsedKey = nil
            parseState = .error("This key is encrypted. Enter its passphrase above.")
        } catch SSHKeyService.KeyError.wrongPassphrase {
            state.parsedKey = nil
            parseState = .error("Wrong passphrase.")
        } catch SSHKeyService.KeyError.unsupportedKeyType {
            state.parsedKey = nil
            parseState = .error("Unsupported key type. PocketTop accepts Ed25519 or RSA keys.")
        } catch SSHKeyService.KeyError.malformedPEM {
            state.parsedKey = nil
            parseState = .error("That doesn't look like a valid private key.")
        } catch {
            state.parsedKey = nil
            parseState = .error("Couldn't read the key: \(error.localizedDescription)")
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let err):
            parseState = .error("Couldn't open file: \(err.localizedDescription)")
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                state.importedPEM = text
                parseState = .idle
            } catch {
                parseState = .error("Couldn't read file: \(error.localizedDescription)")
            }
        }
    }

    /// Load the app-wide key from the Keychain — generating one on first use.
    /// On success, populate `state.generatedPublicLine`, `.generatedPublicFingerprint`,
    /// `.importedPEM`, and `.parsedKey` so Continue is enabled.
    @MainActor
    private func loadAppWideKey() async {
        parseState = .parsing
        do {
            let generated = try SSHKeyService.loadOrGenerateAppKey(
                comment: defaultKeyComment()
            )
            state.parsedKey = .ed25519(generated.privateKey)
            state.importedPEM = generated.privatePEM
            state.generatedPublicLine = generated.publicLine
            state.generatedPublicFingerprint = generated.publicFingerprint
            state.keyComment = generated.comment
            parseState = .parsed
        } catch {
            showingAppKeyLoadError = "Couldn't prepare the app-wide key: \(error)"
            parseState = .error("Couldn't load app-wide key")
        }
    }

    private func copyPublicKey() {
        guard let line = state.generatedPublicLine else { return }
        #if canImport(UIKit)
        UIPasteboard.general.string = line
        #endif
    }

    private func defaultKeyComment() -> String {
        #if canImport(UIKit)
        let device = UIDevice.current.name
        return "pockettop@\(device)"
        #else
        return "pockettop"
        #endif
    }
}
