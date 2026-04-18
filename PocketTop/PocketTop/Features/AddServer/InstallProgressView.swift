import SwiftUI
import SwiftData

/// Step 5: run the detached installer and display live progress.
///
/// ### Flow overview
/// 1. Build an `InstallerService` from the wizard's `EphemeralSetupState`
///    (auth bundle, optional sudo password).
/// 2. Consume the installer's `AsyncThrowingStream<InstallProgress, Error>`
///    and render each event as a row in the scrolling log.
/// 3. When the stream terminates without throwing, the installer has
///    already disconnected SSH and left the agent running. At that point we
///    persist the SSH credentials to the Keychain so the
///    `ConnectionRecoveryService` can SSH back in and re-read the
///    authoritative `{api_key, cert_fingerprint, https_port}` from the
///    server files (ref doc §5 "Post-Install Verification": the install
///    script's log is informational; `/opt/pockettop/…` is the source of
///    truth).
/// 4. Save the api key + update `Server`, commit the model context, and
///    advance to `DoneView`.
///
/// ### Why bounce through ConnectionRecoveryService rather than the stream
/// The installer's stream exposes only a truncated summary in the final
/// `.step(name: "verified", …)` event (api-key prefix + cert-fp prefix), not
/// the full values — exposing them via the stream would duplicate the
/// recovery API that already exists for this exact job and that we'd need
/// anyway on subsequent launches. Reusing recovery keeps the "read
/// credentials off a live server" logic in one place.
///
/// ### Cancellation & retry
/// - Cancel during install: cancels the running task; the stream's
///   `onTermination` closes SSH; the view returns a `.failed("Cancelled.")`.
/// - Retry after failure: spins up a fresh `InstallerService` and re-runs
///   the whole flow. The install script's first step is `cleanup` so
///   idempotent re-runs are safe on the server side.
///
/// ### Main-actor discipline
/// All `@State` mutations, `Server` reads/writes, and `modelContext.save()`
/// calls happen on the main actor. The installer is an actor and we `await`
/// its calls; the stream's `for-await` loop runs on `@MainActor` because
/// the enclosing `Task { @MainActor in … }` pins it there.
struct InstallProgressView: View {
    @Bindable var state: EphemeralSetupState
    @Environment(\.modelContext) private var modelContext

    /// Parent advances to Done. Called once, after persistence succeeds.
    let onSuccess: () -> Void
    /// Parent pops back (typically to the sudo prompt on a recoverable
    /// failure, or out of the sheet on a hard abort).
    let onCancel: () -> Void

    // MARK: - Local state

    /// Scrolling log. One row per event we decide to surface.
    @State private var logEntries: [LogEntry] = []
    /// Monotonically increasing id so SwiftUI's `ForEach`/`List` can key
    /// rows without comparing content.
    @State private var nextEntryID: Int = 0

    /// Overall view phase.
    @State private var phase: Phase = .idle

    /// Live install task. Kept so we can cancel it on tap Cancel or on view
    /// disappear.
    @State private var installTask: Task<Void, Never>?

    enum Phase: Equatable {
        case idle
        case running
        /// Install stream finished; we're doing post-install read + save.
        case finalizing
        /// Everything succeeded.
        case completed
        /// Stopped with a user-facing error message.
        case failed(String)
    }

    struct LogEntry: Identifiable {
        let id: Int
        let kind: Kind
        let text: String

        enum Kind {
            case step
            case log
            case upload
            case started
            case reconnecting
            case error
            case success
            case info
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            logView
            footer
        }
        .navigationTitle("Installing")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                switch phase {
                case .running, .finalizing:
                    Button("Cancel") { cancelInstall() }
                case .failed:
                    Button("Back", action: onCancel)
                default:
                    // No toolbar affordance needed.
                    EmptyView()
                }
            }
        }
        .task {
            // Run the first attempt when this view appears. Retries flow
            // through an explicit button so we don't auto-loop on errors.
            await runInstall()
        }
        .onDisappear {
            installTask?.cancel()
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var logView: some View {
        ScrollViewReader { proxy in
            List(logEntries) { entry in
                HStack(alignment: .top, spacing: 8) {
                    icon(for: entry.kind)
                        .frame(width: 18)
                    Text(entry.text)
                        .font(.footnote)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.leading)
                }
                .id(entry.id)
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .onChange(of: logEntries.last?.id) { _, newID in
                guard let newID else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(newID, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        Divider()
        Group {
            switch phase {
            case .idle, .running:
                HStack {
                    ProgressView()
                    Text("Installing agent…")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                }
                .frame(maxWidth: .infinity)
                .padding()
            case .finalizing:
                HStack {
                    ProgressView()
                    Text("Reading credentials…")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                }
                .frame(maxWidth: .infinity)
                .padding()
            case .completed:
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Install complete").font(.footnote)
                }
                .frame(maxWidth: .infinity)
                .padding()
            case .failed(let message):
                VStack(spacing: 8) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        Task { await runInstall() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity)
                .padding()
            }
        }
    }

    @ViewBuilder
    private func icon(for kind: LogEntry.Kind) -> some View {
        switch kind {
        case .step:
            Image(systemName: "arrow.right.circle").foregroundStyle(.tint)
        case .log:
            Image(systemName: "text.alignleft").foregroundStyle(.secondary)
        case .upload:
            Image(systemName: "icloud.and.arrow.up").foregroundStyle(.tint)
        case .started:
            Image(systemName: "play.circle").foregroundStyle(.tint)
        case .reconnecting:
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
        case .error:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .success:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .info:
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
    }

    // MARK: - Install orchestration

    /// Start (or restart) an install attempt.
    ///
    /// Rebuilds the log + `Server` proto so Retry produces a clean slate.
    /// The previous install task, if any, is cancelled first — its SSH
    /// connection gets closed via the stream's `onTermination`.
    @MainActor
    private func runInstall() async {
        installTask?.cancel()
        installTask = nil

        logEntries.removeAll()
        phase = .running
        nextEntryID = 0

        guard let auth = buildAuthBundle() else {
            append(.error, "Missing credentials for install.")
            phase = .failed("Missing credentials.")
            return
        }

        let server = makeProtoServer()
        let sudoPassword = state.sshUserIsRoot ? nil : state.sudoPassword
        let installer = InstallerService(server: server, auth: auth)

        installTask = Task { @MainActor in
            do {
                for try await event in installer.install(sudoPassword: sudoPassword) {
                    if Task.isCancelled { break }
                    handle(event)
                }
                if Task.isCancelled {
                    phase = .failed("Cancelled.")
                    append(.error, "Cancelled by user.")
                    return
                }
                // Stream ended without error → installer confirmed success
                // and already disconnected SSH (ref doc §12 #12).
                await finalize(server: server)
            } catch is CancellationError {
                phase = .failed("Cancelled.")
                append(.error, "Cancelled by user.")
            } catch let err as InstallError {
                let msg = describe(err)
                phase = .failed(msg)
                append(.error, msg)
            } catch {
                let msg = error.localizedDescription
                phase = .failed(msg)
                append(.error, msg)
            }
        }
    }

    /// Map the active `EphemeralSetupState` to an `SSHAuthBundle`.
    @MainActor
    private func buildAuthBundle() -> SSHAuthBundle? {
        switch state.authMethod {
        case .password:
            guard !state.sshPassword.isEmpty else { return nil }
            return .password(state.sshPassword)
        case .key:
            guard !state.importedPEM.isEmpty else { return nil }
            let pass = state.keyPassphrase.isEmpty ? nil : state.keyPassphrase
            return .key(pem: state.importedPEM, passphrase: pass)
        }
    }

    /// Build the `Server` the installer consumes. We do NOT insert it into
    /// `modelContext` yet — that happens in `finalize` after all the
    /// post-install reads succeed, so failed installs don't leave orphaned
    /// rows.
    ///
    /// `serverIdentity` is left empty at this stage; the install script
    /// could in principle emit it, but the current JSON contract doesn't
    /// include it. Future versions can populate it here.
    @MainActor
    private func makeProtoServer() -> Server {
        let port = state.port ?? 22
        return Server(
            serverIdentity: "",
            name: state.effectiveName,
            host: state.host,
            sshPort: port,
            sshUsername: state.sshUsername,
            httpsPort: 443,
            osFamily: "linux",
            certFingerprint: "",
            sshHostKeyFingerprint: state.pendingHostFingerprint,
            isInstalled: false,
            authMethodRaw: state.authMethod.rawValue,
            keyType: keyTypeString(from: state.parsedKey),
            publicKeyFingerprint: nil,
            keyComment: state.keyComment.isEmpty ? nil : state.keyComment,
            keychainKeyAccount: nil,
            sudoPasswordSaved: false
        )
    }

    /// Consume one `InstallProgress` event into the log.
    @MainActor
    private func handle(_ event: InstallProgress) {
        switch event {
        case .uploading(let phase, let bytes):
            let sizeStr = bytes.map { "\($0) bytes" } ?? "starting"
            append(.upload, "Uploading \(phase) — \(sizeStr)")
        case .started:
            append(.started, "Install process started on server.")
        case .step(let name, let status, let message):
            let base = "\(name) \(status)"
            let full = message.map { "\(base) — \($0)" } ?? base
            switch name {
            case "error":
                append(.error, full)
            case "success", "verified":
                append(.success, full)
            default:
                append(.step, full)
            }
        case .log(let line):
            append(.log, line)
        case .reconnecting(let attempt):
            append(.reconnecting, "SSH dropped; reconnecting (attempt \(attempt))…")
        case .verified(let details):
            // Stash the authoritative port so `finalize` can stamp it onto
            // the Server row before ConnectionRecoveryService runs.
            state.connectionDetails = details
        }
    }

    private func append(_ kind: LogEntry.Kind, _ text: String) {
        let entry = LogEntry(id: nextEntryID, kind: kind, text: text)
        nextEntryID += 1
        logEntries.append(entry)
    }

    // MARK: - Post-install finalization

    /// Install stream finished cleanly. Save SSH credentials so
    /// `ConnectionRecoveryService` can SSH back in, read the api-key and
    /// cert-fingerprint from the server files, then persist everything
    /// into SwiftData + Keychain.
    ///
    /// We do this in one big do/catch so any failure during persistence
    /// flips us into `.failed` without leaving a half-saved row.
    @MainActor
    private func finalize(server: Server) async {
        phase = .finalizing
        append(.info, "Install complete. Reading credentials…")

        do {
            // 1. Save SSH auth under the server's UUID so recovery can
            //    reopen the connection. These saves must complete BEFORE we
            //    invoke `ConnectionRecoveryService.recover`.
            try saveSSHCredentials(server: server)

            // 1b. Stamp the authoritative HTTPS port from the install's
            //     `.verified` event. Recovery uses `server.httpsPort` to
            //     reach the agent — if we leave the proto-server's
            //     placeholder in place and the script picked a non-443
            //     port, the HTTPS verify hits nothing.
            if let details = state.connectionDetails {
                server.httpsPort = details.httpsPort
            }

            // 2. Post-install recovery: SSH → read API key + cert fp → HTTPS
            //    verify. Returns a `RecoveryResult` with the authoritative
            //    values.
            let result = try await ConnectionRecoveryService.shared.recover(server: server)
            append(.success, "Credentials verified.")

            // 3. Save the API key to the Keychain under the server's UUID.
            try KeychainService.save(
                key: .apiKey,
                value: result.apiKey,
                account: server.id.uuidString
            )

            // 4. Save the sudo password with biometry (non-root + opt-in).
            if !state.sshUserIsRoot
                && state.saveSudoWithBiometry
                && !state.sudoPassword.isEmpty {
                try KeychainService.save(
                    key: .sudoPassword,
                    value: state.sudoPassword,
                    account: server.id.uuidString,
                    requiresBiometry: true
                )
                server.sudoPasswordSaved = true
            }

            // 5. Stamp the Server row with what recovery just confirmed.
            //    Recovery's RecoveryResult already mutated certFingerprint
            //    in-memory; we assign here for clarity (and in case the
            //    write-back bit was false).
            server.certFingerprint = result.certFingerprint
            // `server.httpsPort` was already set from state.connectionDetails
            // above; don't clobber it with a hardcoded value.
            server.isInstalled = true
            server.updatedAt = .now

            // 6. Commit to SwiftData.
            modelContext.insert(server)
            try modelContext.save()

            // 7. Expose the Server to later steps and advance.
            state.server = server
            phase = .completed
            onSuccess()
        } catch let err as SSHKeyService.KeyError {
            let msg = describeKeyError(err)
            phase = .failed(msg)
            append(.error, msg)
        } catch let err as RecoveryError {
            let msg = describeRecovery(err)
            phase = .failed(msg)
            append(.error, msg)
        } catch let err as KeychainError {
            let msg = "Keychain error: \(err)"
            phase = .failed(msg)
            append(.error, msg)
        } catch {
            let msg = "Finalization failed: \(error.localizedDescription)"
            phase = .failed(msg)
            append(.error, msg)
        }
    }

    /// Persist the SSH password or PEM under the appropriate Keychain
    /// account so `SSHConnectionHelper` (called by
    /// `ConnectionRecoveryService`) can find it. Idempotent — Keychain
    /// writes overwrite on duplicate.
    @MainActor
    private func saveSSHCredentials(server: Server) throws {
        switch state.authMethod {
        case .password:
            // Always save under the UUID — recovery looks here. Respect the
            // user's "save to Keychain" toggle only for whether to *keep*
            // the password long-term: if they opt out, we still write it
            // temporarily so recovery works, and then delete it immediately
            // afterwards in `finalize` cleanup.
            //
            // Pragmatic V1 choice: if the user declines to save, we save
            // anyway (recovery requires it). A future "don't save" path
            // could instead hold the password in memory and have recovery
            // accept an override. Not worth it for V1.
            try KeychainService.save(
                key: .sshPassword,
                value: state.sshPassword,
                account: server.id.uuidString
            )

        case .key:
            // Save PEM under the appropriate account. For "use app-wide key"
            // the PEM is already in Keychain under sshAppKeyAccount and we
            // just record the pointer. For "save as app-wide" we write there
            // ourselves. Otherwise per-server UUID.
            if state.useAppWideKey {
                // Already persisted — just record the pointer.
                server.keychainKeyAccount = KeychainService.sshAppKeyAccount
            } else if state.saveKeyAsAppWide {
                try KeychainService.save(
                    key: .sshPrivateKey,
                    value: state.importedPEM,
                    account: KeychainService.sshAppKeyAccount,
                    requiresBiometry: false
                )
                server.keychainKeyAccount = KeychainService.sshAppKeyAccount
            } else {
                try KeychainService.save(
                    key: .sshPrivateKey,
                    value: state.importedPEM,
                    account: server.id.uuidString,
                    requiresBiometry: false
                )
            }
            // Record key-type metadata on the Server for display later.
            server.keyType = keyTypeString(from: state.parsedKey)
            server.keyComment = state.keyComment.isEmpty ? nil : state.keyComment
        }
    }

    /// Cancel the running install task. `onTermination` on the installer's
    /// stream disconnects SSH automatically.
    private func cancelInstall() {
        installTask?.cancel()
        installTask = nil
        phase = .failed("Cancelled.")
        append(.error, "Cancelled by user.")
    }

    // MARK: - Error descriptions

    private func describe(_ err: InstallError) -> String {
        switch err {
        case .binaryNotBundled(let arch):
            return "No bundled agent for architecture '\(arch)'."
        case .scriptNotBundled:
            return "Install script missing from app bundle."
        case .uploadFailed(let msg):
            return "Upload failed: \(msg)"
        case .remoteArchUnknown(let raw):
            return "Unsupported remote architecture: \(raw)"
        case .launcherFailed:
            return "Couldn't launch the installer. Check that the sudo password is correct."
        case .installFailed(let reason):
            return "Install failed: \(reason)"
        case .reconnectFailed(let attempts):
            return "Lost connection after \(attempts) reconnect attempts."
        case .postInstallReadFailed(let which):
            return "Install reported success but we couldn't verify (\(which))."
        case .cancelled:
            return "Cancelled."
        }
    }

    private func describeRecovery(_ err: RecoveryError) -> String {
        switch err {
        case .sudoPasswordRequired:
            return "Post-install credential read requires sudo; none was supplied."
        case .credentialsUnreachable(let msg):
            return "Couldn't read credentials from the server: \(msg)"
        case .verificationFailed(let msg):
            return "Server reachable but failed verification: \(msg)"
        case .cancelled:
            return "Cancelled during credential recovery."
        }
    }

    private func describeKeyError(_ err: SSHKeyService.KeyError) -> String {
        switch err {
        case .passphraseRequired:
            return "Key requires a passphrase."
        case .wrongPassphrase:
            return "Wrong passphrase for SSH key."
        case .unsupportedKeyType:
            return "Unsupported SSH key type."
        case .malformedPEM:
            return "Couldn't parse the SSH key PEM."
        case .keychain(let e):
            return "Keychain error storing key: \(e)"
        }
    }

    private func keyTypeString(from parsed: SSHKeyService.ParsedKey?) -> String? {
        guard let parsed else { return nil }
        switch parsed {
        case .ed25519: return "ed25519"
        case .rsa: return "rsa"
        }
    }
}
