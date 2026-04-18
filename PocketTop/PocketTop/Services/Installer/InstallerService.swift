import Foundation

/// Values returned by the install script's final `{"result":"success",...}`
/// line. Re-read from the server files post-install for authority (ref doc §5
/// "Post-Install Verification"): the log stream is informational, the files are
/// the source of truth.
struct ConnectionDetails: Sendable {
    let apiKey: String
    let certFingerprint: String
    let httpsPort: Int
    let version: String
}

/// Progress events yielded by `InstallerService.install(sudoPassword:)`.
///
/// Each case is a discrete point in the install lifecycle the UI might render
/// (progress bar tick, log line, reconnect spinner). Opaque string fields
/// (`phase`, `name`, `status`, `message`) mirror the install script's JSON
/// contract — the UI layer decides how to localize / style them.
enum InstallProgress: Sendable {
    /// A file is being uploaded. `phase` is `"binary"` or `"script"`; `bytes`
    /// is the verified final size when known, `nil` mid-upload.
    case uploading(phase: String, bytes: Int?)
    /// Install script has been launched and we've captured its PID. Emitted
    /// once, right after launcher + `nohup setsid`.
    case started
    /// A single `{"step":...,"status":...,"message":...}` line from the script.
    /// Both `started` and `completed` status values come through here — the UI
    /// decides how to collapse matched pairs for a progress display.
    case step(name: String, status: String, message: String?)
    /// Any log line that wasn't a structured JSON step — MOTD, stderr leaks,
    /// raw tool output. The UI typically dumps these into a scrollable console.
    case log(String)
    /// SSH dropped and we're re-establishing to resume polling. `attempt` is
    /// 1-indexed. The install process on the server keeps running regardless.
    case reconnecting(attempt: Int)
    /// Install reported success and we re-read the authoritative
    /// `{api_key, cert_fingerprint, https_port, version}` from the server
    /// files. Emitted once, right before the stream finishes cleanly. The
    /// UI must persist `httpsPort` onto the `Server` row before it hands
    /// off to `ConnectionRecoveryService` — otherwise recovery calls the
    /// wrong port (443 when the agent actually bound 8443, etc.).
    case verified(ConnectionDetails)
}

/// Errors that can bubble out of the install stream.
///
/// Any `.installFailed` event means the server-side script emitted an
/// `{"error":"..."}` line or exited early; the log snippet (`reason`) is the
/// best we can give the UI. Every other case represents a local / transport
/// failure that prevented us from getting to a definitive server result.
enum InstallError: Error, Sendable {
    /// `uname -m` returned a recognized value but we don't ship a binary for it.
    /// Holds the resolved `"amd64"` / `"arm64"` name we looked up under.
    case binaryNotBundled(arch: String)
    /// `pockettop_install.sh` is missing from the app bundle. Build misconfig —
    /// the file should be in the Copy Bundle Resources build phase.
    case scriptNotBundled
    /// `SSHService.uploadFile` or the raw binary heredoc upload failed. The
    /// associated string is a short description (size mismatch, transport error).
    case uploadFailed(String)
    /// `uname -m` returned a value we don't recognize at all (not x86_64 /
    /// aarch64 / arm64). Holds the raw string for the error UI.
    case remoteArchUnknown(String)
    /// The detached launcher was invoked but never wrote its PID file within
    /// the retry window (~3s). Usually means sudo rejected the password or a
    /// path is wrong.
    case launcherFailed
    /// The install script emitted an error JSON line, or the process exited
    /// before producing a `"result":"success"` line. `reason` is the parsed
    /// error message when available, else a canned "process exited" string.
    case installFailed(reason: String)
    /// Lost the SSH connection and failed to restore it within the retry budget.
    case reconnectFailed(attempts: Int)
    /// Install script reported success but we couldn't re-read the
    /// `/opt/pockettop` authority files afterward. `String` names which read
    /// failed (e.g. `"api_key"`, `"cert_fingerprint"`).
    case postInstallReadFailed(String)
    /// Caller invoked `onTermination` (stream consumer went away) or the
    /// underlying task was cancelled before a terminal event arrived.
    case cancelled
}

/// Credentials used to (re)open the SSH connection during install.
///
/// The installer keeps this around because the connection can drop mid-install
/// (phone lock, network switch) and we need to re-authenticate using exactly
/// the credentials the setup flow prepared — not via `SSHConnectionHelper`
/// (which reads from the Keychain; the setup flow hasn't persisted anything
/// yet at this stage).
enum SSHAuthBundle: Sendable {
    case password(String)
    case key(pem: String, passphrase: String?)
}

/// Orchestrates the server-side install. One-shot: construct, consume the
/// `install(...)` stream to completion, then discard.
///
/// Responsibilities (ref doc §5 end-to-end):
/// 1. Upload the arch-appropriate `pockettopd` binary and the install script.
/// 2. Write a small launcher, kick it off detached via `nohup setsid` so the
///    install survives an SSH drop.
/// 3. Tail `/tmp/pockettop_install.log` over SSH, yielding structured progress.
/// 4. Reconnect transparently if the SSH channel dies during tailing.
/// 5. After the success line, re-read the API key + cert fingerprint from the
///    server files — never trust values from the log stream.
/// 6. Disconnect SSH cleanly before the stream finishes so the steady-state
///    HTTPS client doesn't race the lingering SSH session (ref doc §12).
///
/// Concurrency notes:
/// - Actor-isolated because we mutate an SSH handle and a launch PID across
///   many `await` points.
/// - `Bundle.main` is read **synchronously in `init`** (on the MainActor-ish
///   construction context) and the resolved URLs are stored. The async install
///   stream must not touch `Bundle.main` itself from actor isolation.
actor InstallerService {

    // MARK: - Config constants

    /// Remote paths used throughout. Kept together so the shell command
    /// strings below read like one coherent protocol rather than scattered
    /// magic strings. These must match the install script's expectations.
    private enum RemotePath {
        static let binary = "/tmp/pockettopd"
        static let script = "/tmp/pockettop_install.sh"
        static let launcher = "/tmp/pockettop_launcher.sh"
        static let pidFile = "/tmp/pockettop_install.pid"
        static let logFile = "/tmp/pockettop_install.log"
        static let apiKeyFile = "/opt/pockettop/.api_key"
        static let certFile = "/opt/pockettop/certs/server.crt"
    }

    /// Poll cadences. The 2s log cadence matches the ref doc's advice — faster
    /// than that and we drown the SSH channel in `tail` calls; slower and the
    /// UI feels laggy during install.
    private static let logPollInterval: Duration = .seconds(2)
    /// PID file retry window after launch. The launcher races to `echo $$`; a
    /// slow system can take a handful of ms to commit the write.
    private static let pidRetryInterval: Duration = .milliseconds(200)
    private static let pidRetryCount = 15  // ~3 seconds
    /// Max consecutive reconnect attempts before giving up on the whole install
    /// (ref doc §5 "SSH Reconnection During Install").
    private static let maxReconnectAttempts = 5

    // MARK: - Dependencies & state

    private let server: Server
    private let auth: SSHAuthBundle
    /// Bundled binary URLs, resolved eagerly in `init` so the install task
    /// never has to touch `Bundle.main` from actor isolation. Nil means the
    /// binary for that arch isn't in the bundle — resolved lazily in `install`
    /// against the detected arch so we can raise `.binaryNotBundled` with the
    /// right name.
    private let amd64BinaryURL: URL?
    private let arm64BinaryURL: URL?
    private let scriptURL: URL?

    /// Live SSH handle. Recreated on reconnect. Cleared on `disconnect()`.
    private var ssh: SSHService?
    /// PID of the detached install process on the server. Captured once after
    /// launch. Used for `[ -d /proc/<PID> ]` liveness checks.
    private var installPID: String?
    /// Cached so we can tell how to invoke the liveness check (root SSH users
    /// can read `/proc/PID` directly; non-root users must `sudo cat` because
    /// the install is running as root).
    private var sshUserIsRoot: Bool = false

    // MARK: - Init

    init(server: Server, auth: SSHAuthBundle) {
        self.server = server
        self.auth = auth
        // Resolve bundle URLs eagerly. These calls are synchronous and side-
        // effect free; doing them here means the actor body doesn't have to
        // reach out of isolation later.
        self.amd64BinaryURL = Bundle.main.url(forResource: "pockettopd-linux-amd64", withExtension: nil)
        self.arm64BinaryURL = Bundle.main.url(forResource: "pockettopd-linux-arm64", withExtension: nil)
        self.scriptURL = Bundle.main.url(forResource: "pockettop_install", withExtension: "sh")
    }

    // MARK: - Public API

    /// Drive the full install and stream progress.
    ///
    /// The returned `AsyncThrowingStream` is a hot stream: consume it promptly.
    /// It yields one `.started`, many `.step`/`.log`/`.uploading` events, and
    /// then finishes (either via `finish(throwing:)` on error or plain
    /// `finish()` on the success JSON line).
    ///
    /// - Parameter sudoPassword: Required when the SSH user is non-root.
    ///   Ignored when the SSH user is root (the installer detects this on
    ///   first connect via `SSHService.sshUserIsRoot`).
    ///
    /// Cancellation: if the consumer drops the stream before completion,
    /// `onTermination` tears down the spawned task and closes the SSH
    /// connection. The server-side install keeps running — we deliberately do
    /// not try to kill the remote process; the next connect can pick up
    /// tailing if desired.
    nonisolated func install(sudoPassword: String?) -> AsyncThrowingStream<InstallProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish(throwing: InstallError.cancelled)
                    return
                }
                do {
                    try await self.runInstall(
                        sudoPassword: sudoPassword,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: InstallError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
                // Fire-and-forget disconnect. If the install finished
                // successfully we've already disconnected; if the consumer
                // bailed early, this cleans up.
                Task { [weak self] in
                    await self?.disconnect()
                }
            }
        }
    }

    /// Close the SSH connection. Safe to call multiple times.
    ///
    /// Called automatically on success right before the stream terminates (ref
    /// doc §12: SSH must be closed before the UI pushes into the HTTPS
    /// dashboard, or the two connections contend). Consumers can also call it
    /// manually in error paths as belt-and-suspenders.
    func disconnect() async {
        if let ssh {
            await ssh.disconnect()
        }
        ssh = nil
        installPID = nil
    }

    // MARK: - Install flow (actor-isolated)

    /// End-to-end orchestration. Split out so `install(...)` can wrap it in a
    /// single do/catch that maps cancellations appropriately.
    ///
    /// Steps roughly correspond to the §5 lifecycle. We bail on the first
    /// error rather than trying to recover mid-step — the detached install on
    /// the server is one atomic unit from the client's POV.
    private func runInstall(
        sudoPassword: String?,
        continuation: AsyncThrowingStream<InstallProgress, Error>.Continuation
    ) async throws {
        // 1. Connect and set sudo state.
        let ssh = try await ensureConnected()
        if let sudoPassword {
            await ssh.setSudoPassword(sudoPassword)
        }
        sshUserIsRoot = await ssh.sshUserIsRoot()

        try Task.checkCancellation()

        // 2. Detect arch + resolve bundled binary URL.
        let arch = try await detectRemoteArch(ssh: ssh)
        let binaryURL = try resolveBinaryURL(for: arch)

        // 3. Upload binary (raw bytes, NOT uploadFile — uploadFile is UTF-8 only).
        let binarySize = try await uploadBinary(ssh: ssh, from: binaryURL)
        continuation.yield(.uploading(phase: "binary", bytes: binarySize))
        try Task.checkCancellation()

        // 4. Upload install script via uploadFile (text, so heredoc-decoded
        //    size == utf8 byte count; the built-in verify catches truncation).
        let scriptSize = try await uploadScript(ssh: ssh)
        continuation.yield(.uploading(phase: "script", bytes: scriptSize))
        try Task.checkCancellation()

        // 5. Write launcher, kick off detached, capture PID.
        try await launchDetached(ssh: ssh)
        let pid = try await capturePID(ssh: ssh)
        self.installPID = pid
        continuation.yield(.started)
        try Task.checkCancellation()

        // 6. Poll log + liveness until success or fatal error.
        let connectionDetails = try await pollInstall(
            pid: pid,
            continuation: continuation
        )

        // 7. Post-install verification: re-read from the server files as
        //    source of truth (ref doc §5 "Post-Install Verification"). The
        //    log's values are informational.
        let verified = try await verifyConnectionDetails(
            liveSSH: try await ensureConnected(),
            fromLog: connectionDetails
        )

        // 8. Emit a final `.step` with the verified details encoded in the
        //    message, then a typed `.verified` event carrying the full
        //    `ConnectionDetails` so the UI can persist the real port before
        //    invoking recovery.
        continuation.yield(.step(
            name: "verified",
            status: "completed",
            message: "api_key=\(verified.apiKey.prefix(8))… cert_fp=\(verified.certFingerprint.prefix(16))… port=\(verified.httpsPort)"
        ))
        continuation.yield(.verified(verified))

        // 9. Disconnect BEFORE the stream finishes. Ref doc §12 specifically
        //    calls this out — otherwise the SSH handle races the HTTPS client
        //    in the immediately-following navigation.
        await disconnect()
    }

    // MARK: - Connect / reconnect

    /// Return a live SSH handle, opening one if we don't already have it.
    /// Re-auths using `auth` (not the Keychain) because during first-time
    /// install the credentials may not yet be persisted.
    private func ensureConnected() async throws -> SSHService {
        if let ssh {
            return ssh
        }
        let fresh = try await openSSH()
        self.ssh = fresh
        return fresh
    }

    /// Build a fresh `SSHService` from the bundled auth. Mirrors the branching
    /// that `SSHConnectionHelper` does, but without the Keychain step (the
    /// setup flow hasn't persisted a `Server` row yet at install time, so the
    /// helper's lookups would fail).
    private func openSSH() async throws -> SSHService {
        let ssh = SSHService()
        let expected: String? = server.sshHostKeyFingerprint.isEmpty
            ? nil
            : server.sshHostKeyFingerprint

        switch auth {
        case .password(let pw):
            _ = try await ssh.connect(
                host: server.host,
                port: server.sshPort,
                username: server.sshUsername,
                password: pw,
                expectedFingerprint: expected
            )
        case .key(let pem, let passphrase):
            let parsed = try SSHKeyService.parsePrivateKey(pem: pem, passphrase: passphrase)
            switch parsed {
            case .ed25519(let priv):
                _ = try await ssh.connectWithEd25519Key(
                    host: server.host,
                    port: server.sshPort,
                    username: server.sshUsername,
                    privateKey: priv,
                    expectedFingerprint: expected
                )
            case .rsa(let priv):
                _ = try await ssh.connectWithRSAKey(
                    host: server.host,
                    port: server.sshPort,
                    username: server.sshUsername,
                    privateKey: priv,
                    expectedFingerprint: expected
                )
            }
        }
        return ssh
    }

    // MARK: - Arch detection

    /// Run `uname -m` on the remote and map to our binary naming. `amd64` and
    /// `arm64` are the only two we ship; everything else is a hard stop.
    private func detectRemoteArch(ssh: SSHService) async throws -> String {
        let raw: String
        do {
            raw = try await ssh.execute("uname -m")
        } catch {
            throw InstallError.uploadFailed("uname failed: \(error)")
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed {
        case "x86_64":
            return "amd64"
        case "aarch64", "arm64":
            return "arm64"
        default:
            throw InstallError.remoteArchUnknown(trimmed)
        }
    }

    /// Pick the right bundled binary URL for the resolved arch. Throws
    /// `.binaryNotBundled` if the build misconfigured Resources.
    private func resolveBinaryURL(for arch: String) throws -> URL {
        switch arch {
        case "amd64":
            guard let url = amd64BinaryURL else { throw InstallError.binaryNotBundled(arch: arch) }
            return url
        case "arm64":
            guard let url = arm64BinaryURL else { throw InstallError.binaryNotBundled(arch: arch) }
            return url
        default:
            // Should never hit — detectRemoteArch already filters.
            throw InstallError.binaryNotBundled(arch: arch)
        }
    }

    // MARK: - Uploads

    /// Upload the raw binary bytes by streaming them to `cat` over the SSH
    /// exec channel's stdin. The exec channel is 8-bit safe (RFC 4254) so
    /// binary goes over as-is — no base64 expansion, no heredoc size trap.
    ///
    /// Earlier versions baked the base64-encoded binary into a single
    /// `ssh.execute(heredoc)` call. That works for small payloads (the ~16KB
    /// install script) but the 6–7 MB agent binary tripped OpenSSH's exec
    /// command buffer limit and the server closed the channel with
    /// "Connection reset by peer" (errno 54). Streaming via `executeWithStdin`
    /// sends each chunk as a small `CHANNEL_DATA` frame that the server
    /// accepts without complaint.
    ///
    /// Size is returned so the UI can display "uploaded N bytes".
    private func uploadBinary(ssh: SSHService, from localURL: URL) async throws -> Int {
        let data: Data
        do {
            data = try Data(contentsOf: localURL)
        } catch {
            throw InstallError.uploadFailed("read local binary: \(error)")
        }
        let expectedSize = data.count

        do {
            try await ssh.executeWithStdin(
                "cat > \(Self.singleQuote(RemotePath.binary))",
                data: data
            )
        } catch {
            throw InstallError.uploadFailed("transport: \(error)")
        }

        // Chmod + verify size in one round-trip. The last line of stdout is
        // the `wc -c` count.
        let out: String
        do {
            out = try await ssh.execute(
                "chmod +x \(Self.singleQuote(RemotePath.binary)) && wc -c < \(Self.singleQuote(RemotePath.binary))"
            )
        } catch {
            throw InstallError.uploadFailed("verify: \(error)")
        }
        let sizeStr = out
            .split(separator: "\n", omittingEmptySubsequences: true)
            .last
            .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        guard let got = Int(sizeStr) else {
            throw InstallError.uploadFailed("size verification parse failed: \(sizeStr)")
        }
        guard got == expectedSize else {
            throw InstallError.uploadFailed("size mismatch: expected \(expectedSize), got \(got)")
        }
        return got
    }

    /// Upload the install script using the generic `uploadFile` path. The
    /// script is text, so the existing UTF-8-based upload + `wc -c` check is
    /// correct. After upload we chmod +x so the launcher can exec it.
    private func uploadScript(ssh: SSHService) async throws -> Int {
        guard let url = scriptURL else { throw InstallError.scriptNotBundled }
        let contents: String
        do {
            contents = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw InstallError.uploadFailed("read local script: \(error)")
        }
        do {
            try await ssh.uploadFile(content: contents, remotePath: RemotePath.script)
        } catch {
            throw InstallError.uploadFailed("script upload: \(error)")
        }
        do {
            _ = try await ssh.execute("chmod +x \(Self.singleQuote(RemotePath.script))")
        } catch {
            throw InstallError.uploadFailed("script chmod: \(error)")
        }
        return contents.utf8.count
    }

    // MARK: - Launch

    /// Write the launcher script and kick off the detached install.
    ///
    /// The launcher indirection (ref doc §5) exists so we have a stable place
    /// to capture `$$` (the launcher's own PID) before `exec` replaces the
    /// process image with the install script. Without it, the PID we can read
    /// races the fork. `setsid` ensures the process gets its own session so an
    /// SSH exit can't signal it.
    private func launchDetached(ssh: SSHService) async throws {
        // Launcher is a small text file — fine to go through the text upload
        // helper, which also verifies the size.
        let launcher = """
        #!/bin/bash
        echo $$ > \(RemotePath.pidFile)
        exec bash \(RemotePath.script) install > \(RemotePath.logFile) 2>&1
        """
        do {
            try await ssh.uploadFile(content: launcher, remotePath: RemotePath.launcher)
        } catch {
            throw InstallError.uploadFailed("launcher upload: \(error)")
        }
        do {
            _ = try await ssh.execute("chmod +x \(Self.singleQuote(RemotePath.launcher))")
        } catch {
            throw InstallError.uploadFailed("launcher chmod: \(error)")
        }

        // Pre-create the pid + log files so (a) tail has something to point at
        // on the first poll iteration, and (b) the `cat pid` retry below can
        // distinguish "file not yet written" from "permission denied".
        _ = try? await ssh.execute(
            "rm -f \(RemotePath.pidFile) \(RemotePath.logFile) && touch \(RemotePath.logFile)"
        )

        // Launch the installer as a transient systemd unit rather than
        // `nohup setsid bash ... &`.
        //
        // Why: Ubuntu 22.04+ ships sudoers with `Defaults use_pty`, which
        // makes sudo allocate a PTY for its command. When sudo returns, the
        // PTY is torn down and ALL processes that shared it — including
        // anything we backgrounded via `&` — get killed, `nohup`/`setsid`
        // notwithstanding. The symptom: `/tmp/pockettop_install.pid` has
        // the launcher's PID (it wrote it right before the kill) but the
        // install log is empty because bash was killed mid-`exec`.
        //
        // `systemd-run` sidesteps this: the transient service runs in
        // `system.slice` under PID 1, not under the calling session.
        // `--collect` tells systemd to auto-reap the unit after it exits so
        // a retry doesn't hit "unit already exists".
        //
        // The `systemctl stop / reset-failed` prelude covers the case
        // where a previous install left the unit in an active-or-failed
        // state (typical on user-initiated retries). Both are idempotent
        // and `|| true` keeps the chain moving when the unit doesn't
        // exist.
        let detach = "systemctl stop \(Self.transientUnitName) 2>/dev/null || true; " +
                     "systemctl reset-failed \(Self.transientUnitName) 2>/dev/null || true; " +
                     "systemd-run --unit=\(Self.transientUnitName) --collect --quiet bash \(RemotePath.launcher)"
        let wrapped = await ssh.sudoCommand(detach)
        do {
            _ = try await ssh.execute(wrapped)
        } catch {
            throw InstallError.launcherFailed
        }
    }

    /// Name of the transient systemd unit created by `systemd-run`. Stable
    /// so a failed install can be cleaned up with `systemctl reset-failed
    /// pockettop-install.service` before the next attempt.
    private static let transientUnitName = "pockettop-install.service"

    /// Read `/tmp/pockettop_install.pid` with a short retry loop. The launcher
    /// writes the PID race-close to `exec`-ing the install; on slow machines
    /// we can see up to a few hundred ms of delay. Cap the wait at ~3s before
    /// calling it a launch failure.
    private func capturePID(ssh: SSHService) async throws -> String {
        for attempt in 0..<Self.pidRetryCount {
            do {
                let raw = try await ssh.execute("cat \(RemotePath.pidFile) 2>/dev/null || true")
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, Int(trimmed) != nil {
                    return trimmed
                }
            } catch {
                // Transient; retry. Don't propagate yet — the `cat` could have
                // raced the file creation on a slow disk.
                dbg("pid cat attempt \(attempt) failed: \(error)")
            }
            try await Task.sleep(for: Self.pidRetryInterval)
        }
        throw InstallError.launcherFailed
    }

    // MARK: - Polling

    /// Tail the install log every `logPollInterval`, handle each new line,
    /// check liveness periodically, and transparently reconnect on SSH drop.
    ///
    /// Returns the `ConnectionDetails` parsed from the success JSON line. The
    /// caller follows up with server-side re-reads for authority.
    private func pollInstall(
        pid: String,
        continuation: AsyncThrowingStream<InstallProgress, Error>.Continuation
    ) async throws -> ConnectionDetails {
        var lineCount = 0
        var iteration = 0
        var reconnectFailures = 0

        while true {
            try Task.checkCancellation()

            // Pull new log lines. Any SSH error here triggers reconnect.
            let newLines: [String]
            do {
                let ssh = try await ensureConnected()
                newLines = try await tailNewLines(ssh: ssh, fromLine: lineCount + 1)
                reconnectFailures = 0
            } catch {
                // Connection probably died. Try to bring it back.
                reconnectFailures += 1
                if reconnectFailures > Self.maxReconnectAttempts {
                    throw InstallError.reconnectFailed(attempts: reconnectFailures - 1)
                }
                continuation.yield(.reconnecting(attempt: reconnectFailures))
                await forceReconnect()
                // Brief pause before retrying — avoid hammering in a tight loop
                // when the network is flaky.
                try await Task.sleep(for: .seconds(1))
                continue
            }

            if !newLines.isEmpty {
                lineCount += newLines.count
                if let details = try handleNewLines(newLines, continuation: continuation) {
                    return details
                }
            }

            // Liveness check every other tick (roughly every 4s). Rationale
            // (ref doc §5): too-frequent checks waste SSH round-trips; too-
            // infrequent and we can't distinguish "installing slowly" from
            // "crashed silently with no error line".
            if iteration % 2 == 1 {
                let alive: Bool
                do {
                    let ssh = try await ensureConnected()
                    alive = try await isRunning(ssh: ssh, pid: pid)
                } catch {
                    // Treat as transient — let the next tail round handle the
                    // reconnect via its own error path.
                    iteration += 1
                    try await Task.sleep(for: Self.logPollInterval)
                    continue
                }
                if !alive {
                    // Process is gone but we never saw the success line.
                    // Check the tail of the log for a trailing error, then bail.
                    let reason = try await scanLogTailForError()
                    throw InstallError.installFailed(
                        reason: reason ?? "process exited without success"
                    )
                }
            }

            iteration += 1
            try await Task.sleep(for: Self.logPollInterval)
        }
    }

    /// `tail -n +N` gives us lines from line N onward. We ask for `lineCount+1`
    /// so each call returns only the lines we haven't seen yet. Empty string
    /// output → no new lines (not an error).
    private func tailNewLines(ssh: SSHService, fromLine: Int) async throws -> [String] {
        let cmd = "tail -n +\(fromLine) \(RemotePath.logFile) 2>/dev/null || true"
        let out = try await ssh.execute(cmd)
        if out.isEmpty { return [] }
        // `split` with `omittingEmptySubsequences: true` drops the trailing
        // empty from the final newline but also drops any intentional blanks
        // inside the log. Log lines are JSON (no embedded blanks that matter)
        // or MOTD text — a lost blank is invisible in the UI.
        return out
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    /// Interpret a batch of freshly-tailed log lines. Yields appropriate
    /// progress events; returns a `ConnectionDetails` if we hit the success
    /// JSON line; throws `InstallError.installFailed` on an error JSON line.
    private func handleNewLines(
        _ lines: [String],
        continuation: AsyncThrowingStream<InstallProgress, Error>.Continuation
    ) throws -> ConnectionDetails? {
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            guard let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                // Not JSON — a MOTD line, stderr leak, or curl output. Pass
                // through as raw log so the UI can surface it if it wants.
                continuation.yield(.log(trimmed))
                continue
            }

            // Error line: {"error":"..."} — terminal.
            if let errMsg = obj["error"] as? String {
                continuation.yield(.step(name: "error", status: "failed", message: errMsg))
                throw InstallError.installFailed(reason: errMsg)
            }

            // Success line: {"result":"success","api_key":...,"cert_fingerprint":...,"https_port":...,"version":...}
            if let result = obj["result"] as? String, result == "success" {
                let apiKey = (obj["api_key"] as? String) ?? ""
                let fp = (obj["cert_fingerprint"] as? String) ?? ""
                let port = (obj["https_port"] as? Int) ?? ((obj["https_port"] as? NSNumber)?.intValue ?? 443)
                let version = (obj["version"] as? String) ?? ""
                continuation.yield(.step(
                    name: "success",
                    status: "completed",
                    message: "install script reported success"
                ))
                return ConnectionDetails(
                    apiKey: apiKey,
                    certFingerprint: fp,
                    httpsPort: port,
                    version: version
                )
            }

            // Structured step: {"step":"...","status":"started|completed","message":"..."}
            if let step = obj["step"] as? String,
               let status = obj["status"] as? String {
                let message = obj["message"] as? String
                continuation.yield(.step(name: step, status: status, message: message))
                continue
            }

            // Unknown JSON shape — pass through as log.
            continuation.yield(.log(trimmed))
        }
        return nil
    }

    /// Liveness probe. `[ -d /proc/<pid> ]` is the correct form here — NOT
    /// `kill -0` (ref doc §5): `kill -0` returns EPERM for root-owned PIDs
    /// when the SSH user is non-root, indistinguishable from "dead".
    ///
    /// Non-root SSH users still can't `stat(/proc/<root-pid>)` in some
    /// hardening configurations, so we route the test through `sudo` when the
    /// SSH user isn't root — the sudo password has already been set on the
    /// ssh actor at this point.
    private func isRunning(ssh: SSHService, pid: String) async throws -> Bool {
        // Only accept PID strings that look safe to interpolate; the retry
        // loop that captured them already validated Int-parse, but defense in
        // depth.
        guard Int(pid) != nil else { return false }
        let probe = "[ -d /proc/\(pid) ] && echo RUNNING || echo EXITED"
        let cmd: String
        if sshUserIsRoot {
            cmd = probe
        } else {
            cmd = await ssh.sudoCommand(probe)
        }
        let out = try await ssh.execute(cmd)
        return out.contains("RUNNING")
    }

    /// Fetch the last ~50 lines of the log and scan for an `{"error":"..."}`
    /// JSON object. Used when the install process exits without us seeing the
    /// success line — the error line may have been written after our last
    /// `tail -n +N` call or lost in an SSH drop window.
    private func scanLogTailForError() async throws -> String? {
        let ssh = try? await ensureConnected()
        guard let ssh else { return nil }
        let out = try await ssh.execute("tail -n 50 \(RemotePath.logFile) 2>/dev/null || true")
        for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
            let s = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = s.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if let e = obj["error"] as? String {
                return e
            }
        }
        return nil
    }

    // MARK: - Reconnect

    /// Discard the current SSH handle and try to open a fresh one. Called
    /// from `pollInstall` when a command fails mid-tail. Doesn't throw — the
    /// next call to `ensureConnected` will surface the connect error.
    private func forceReconnect() async {
        if let ssh {
            await ssh.disconnect()
        }
        self.ssh = nil
        // Don't re-open eagerly — the caller's next `ensureConnected()` will,
        // and it's simpler to let that error surface naturally rather than
        // juggling an extra swallow-and-retry here.
    }

    // MARK: - Post-install verification

    /// Re-read authoritative values from the server's install artifacts.
    ///
    /// Per ref doc §5 ("Post-Install Verification"): the log stream is
    /// informational. What ends up under `/opt/pockettop` is what the service
    /// is actually running with. We trust the files, not the stream.
    ///
    /// If either read fails, raise `.postInstallReadFailed` so the UI can
    /// distinguish "install succeeded but we can't verify" (which may be a
    /// transient SSH blip) from "install failed".
    private func verifyConnectionDetails(
        liveSSH: SSHService,
        fromLog: ConnectionDetails
    ) async throws -> ConnectionDetails {
        // API key. Non-root SSH users need sudo; root users can read directly.
        let apiKeyCmd: String
        if sshUserIsRoot {
            apiKeyCmd = "cat \(RemotePath.apiKeyFile)"
        } else {
            apiKeyCmd = await liveSSH.sudoCommand("cat \(RemotePath.apiKeyFile)")
        }
        let apiKey: String
        do {
            let raw = try await liveSSH.execute(apiKeyCmd)
            apiKey = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !apiKey.isEmpty else {
                throw InstallError.postInstallReadFailed("api_key")
            }
        } catch let err as InstallError {
            throw err
        } catch {
            throw InstallError.postInstallReadFailed("api_key")
        }

        // Cert fingerprint. install.sh chmods the cert 0644 (public info) so
        // a non-root SSH user can openssl-read it directly. But older
        // installs (before the chmod-split) left it 0600, so as
        // belt-and-suspenders route through `sudoCommand` on non-root —
        // `sudoCommand` degenerates to `bash -c` when sshUserIsRoot is true.
        let fpRawCmd = "openssl x509 -fingerprint -sha256 -noout -in \(RemotePath.certFile) 2>/dev/null"
        let fpCmd: String
        if sshUserIsRoot {
            fpCmd = fpRawCmd
        } else {
            fpCmd = await liveSSH.sudoCommand(fpRawCmd)
        }
        let fpRaw: String
        do {
            fpRaw = try await liveSSH.execute(fpCmd)
        } catch {
            throw InstallError.postInstallReadFailed("cert_fingerprint")
        }
        // The raw output looks like:
        //   sha256 Fingerprint=AB:CD:EF:...
        // Normalize by slicing after the '=' and stripping delimiters.
        let fingerprint = fpRaw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .components(separatedBy: "=")
            .last?
            .replacingOccurrences(of: ":", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard !fingerprint.isEmpty else {
            throw InstallError.postInstallReadFailed("cert_fingerprint")
        }

        return ConnectionDetails(
            apiKey: apiKey,
            certFingerprint: fingerprint,
            httpsPort: fromLog.httpsPort,
            version: fromLog.version
        )
    }

    // MARK: - Shell helpers

    /// Single-quote a shell word. Kept private to the installer so we don't
    /// have to reach into `SSHService`'s internals; the escaping rule is the
    /// canonical `'\''` swap.
    private static func singleQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
