import Foundation
import Crypto
import NIO
import NIOSSH
import Citadel

/// Actor-wrapped Citadel `SSHClient`. One instance per logical connection.
///
/// Ported from `docs/SSH_App_Architecture_Reference.md` §4. This is PocketTop's
/// sole SSH entry point — used by the installer, upgrade flow, and connection
/// recovery. Steady-state metric polling does **not** go through here; it uses
/// the pinned HTTPS client against the `pockettopd` agent.
///
/// Design constraints (see ref doc §4 and §12 "Nuances"):
/// - **No SFTP.** Citadel's SFTP support has cross-version compatibility issues.
///   Uploads use a base64 heredoc over an exec channel instead (`uploadFile`).
/// - **Host-key pinning is mandatory.** `HostKeyCaptureValidator` captures the
///   SHA-256 of the serialized `NIOSSHPublicKey` on first connect and rejects
///   mismatches thereafter. Never connect without one — there's no
///   "accept anything" path.
/// - **Sudo transport is always base64-over-stdin.** See `sudoCommand(_:)`. This
///   sidesteps every shell-escape hazard the password could contain.
/// - **Liveness checks use `[ -d /proc/PID ]`, not `kill -0`** (see ref doc §5).
///   `kill -0` returns EPERM for root-owned processes when the SSH user isn't
///   root, which is indistinguishable from "process exited".
actor SSHService {

    // MARK: - Types

    /// Info about the host key captured at connect time. The caller is
    /// responsible for persisting `fingerprint` in `Server.sshHostKeyFingerprint`
    /// on first connect and rejecting future connects if it changes.
    struct HostKeyInfo: Sendable {
        /// `SHA256:<base64>` formatted fingerprint of the serialized host public
        /// key, matching `ssh-keygen -lf` output.
        let fingerprint: String
        /// True if the stored fingerprint was the pre-V2 legacy format (a hash
        /// of `host:port`) rather than a real SSH public key hash. Lets the UI
        /// upgrade the stored value silently instead of alarming the user with a
        /// "host key changed" warning.
        let isLegacyFingerprint: Bool
    }

    /// Errors originating from this actor. Citadel/NIO errors are wrapped as
    /// `.underlying` so call sites get a uniform type.
    enum SSHError: Error {
        /// Host key fingerprint did not match the expected value. This is a
        /// potential MITM — the UI should block further action and tell the user
        /// to verify the server's host key out-of-band.
        case hostKeyMismatch(expected: String, actual: String)
        /// The command exited with a non-zero status (or produced exit-sentinel
        /// information we can parse). Shell-style.
        case commandFailed(exitCode: Int, stdout: String, stderr: String)
        /// Upload verification (`wc -c`) disagreed with expected size.
        case uploadSizeMismatch(expected: Int, got: Int)
        /// Connect was attempted against a different host, or `connect` was
        /// called twice without an intervening `disconnect`.
        case alreadyConnected
        /// An API requiring an active connection was called before `connect`.
        case notConnected
        /// Wrapper for Citadel/NIO errors.
        case underlying(Error)
    }

    /// Discriminator for the cached `id -u` result used by `sudoCommand(_:)`.
    private enum PrivilegeMode {
        case root
        case nonRoot
    }

    // MARK: - State

    private var client: SSHClient?
    /// Cached result of `id -u` for this connection. `nil` until
    /// `detectPrivilegeMode()` runs. `connect*` methods call it automatically.
    private var privilegeMode: PrivilegeMode?
    /// The sudo password currently in use. Set by the installer/recovery flow via
    /// `setSudoPassword(_:)` after loading from the Keychain (possibly with
    /// biometry). Retained in the actor only as long as the connection is alive.
    private var sudoPassword: String?

    // MARK: - Lifecycle

    init() {}

    deinit {
        // We can't await `disconnect()` from deinit; the EventLoopGroup that
        // Citadel holds will be torn down by ARC on its own. Do _not_ force
        // `Task.init { ... }` here — that capture of self-after-deinit is UB.
    }

    // MARK: - Connect (password)

    /// Open a password-authenticated SSH connection.
    ///
    /// - Parameters:
    ///   - host: DNS name or literal IP.
    ///   - port: Typically 22.
    ///   - username: Remote login user.
    ///   - password: SSH password (distinct from the sudo password — they may
    ///     coincide but don't have to).
    ///   - expectedFingerprint: Previously-pinned host-key fingerprint
    ///     (`SHA256:…`), or `nil` on first connect. On first connect the returned
    ///     `HostKeyInfo.fingerprint` must be persisted and passed on future
    ///     connects.
    ///
    /// Returns the captured host-key info so the caller can persist or verify it.
    /// Throws `SSHError.hostKeyMismatch` if pinning fails.
    func connect(
        host: String,
        port: Int,
        username: String,
        password: String,
        expectedFingerprint: String?
    ) async throws -> HostKeyInfo {
        guard client == nil else { throw SSHError.alreadyConnected }

        let validator = HostKeyCaptureValidator(expectedFingerprint: expectedFingerprint)
        let algs = SSHAlgorithms()

        do {
            let c = try await SSHClient.connect(
                host: host,
                port: port,
                authenticationMethod: .passwordBased(username: username, password: password),
                hostKeyValidator: .custom(validator),
                reconnect: .never,
                algorithms: algs,
                protocolOptions: [],
                connectTimeout: .seconds(20)
            )
            self.client = c
        } catch {
            throw SSHError.underlying(error)
        }

        let info = try await validator.awaitCaptured()
        try verifyPin(info: info, expected: expectedFingerprint)
        try await detectPrivilegeMode()
        return info
    }

    // MARK: - Connect (Ed25519 key)

    /// Open an SSH connection authenticated by an Ed25519 private key.
    ///
    /// `privateKey` must be a Citadel `Curve25519.Signing.PrivateKey`-compatible
    /// value. Callers that only have a PEM on hand should go through
    /// `SSHKeyService.parsePrivateKey(pem:passphrase:)` to produce the key first.
    func connectWithEd25519Key(
        host: String,
        port: Int,
        username: String,
        privateKey: Curve25519.Signing.PrivateKey,
        expectedFingerprint: String?
    ) async throws -> HostKeyInfo {
        guard client == nil else { throw SSHError.alreadyConnected }

        let validator = HostKeyCaptureValidator(expectedFingerprint: expectedFingerprint)
        let algs = SSHAlgorithms()

        do {
            let c = try await SSHClient.connect(
                host: host,
                port: port,
                authenticationMethod: .ed25519(username: username, privateKey: privateKey),
                hostKeyValidator: .custom(validator),
                reconnect: .never,
                algorithms: algs,
                protocolOptions: [],
                connectTimeout: .seconds(20)
            )
            self.client = c
        } catch {
            throw SSHError.underlying(error)
        }

        let info = try await validator.awaitCaptured()
        try verifyPin(info: info, expected: expectedFingerprint)
        try await detectPrivilegeMode()
        return info
    }

    // MARK: - Connect (RSA key)

    /// Open an SSH connection authenticated by an RSA private key.
    ///
    /// Accepts Citadel's `Insecure.RSA.PrivateKey`. The name `insecure` is NIO's
    /// editorial about RSA-SHA1 signing — modern RSA (2048+ with SHA-256) remains
    /// practically fine and is still the most common imported key format.
    func connectWithRSAKey(
        host: String,
        port: Int,
        username: String,
        privateKey: Insecure.RSA.PrivateKey,
        expectedFingerprint: String?
    ) async throws -> HostKeyInfo {
        guard client == nil else { throw SSHError.alreadyConnected }

        let validator = HostKeyCaptureValidator(expectedFingerprint: expectedFingerprint)
        let algs = SSHAlgorithms()

        do {
            let c = try await SSHClient.connect(
                host: host,
                port: port,
                authenticationMethod: .rsa(username: username, privateKey: privateKey),
                hostKeyValidator: .custom(validator),
                reconnect: .never,
                algorithms: algs,
                protocolOptions: [],
                connectTimeout: .seconds(20)
            )
            self.client = c
        } catch {
            throw SSHError.underlying(error)
        }

        let info = try await validator.awaitCaptured()
        try verifyPin(info: info, expected: expectedFingerprint)
        try await detectPrivilegeMode()
        return info
    }

    // MARK: - Disconnect

    /// Close the connection. Safe to call multiple times; safe to call before
    /// connect (no-op).
    func disconnect() async {
        if let c = client {
            do {
                try await c.close()
            } catch {
                // Best effort — there's nothing useful the caller can do here.
                dbg("SSH close failed: \(error)")
            }
        }
        client = nil
        privilegeMode = nil
        sudoPassword = nil
    }

    // MARK: - Execute

    /// Execute a command, returning combined stdout as a UTF-8 string.
    ///
    /// This is deliberately not the `bash -lc` variant: callers compose their own
    /// shells via `sudoCommand(_:)` or plain strings. Empty output is a valid
    /// result.
    func execute(_ command: String) async throws -> String {
        guard let c = client else { throw SSHError.notConnected }
        do {
            let buffer = try await c.executeCommand(command)
            return buffer.getString(at: 0, length: buffer.readableBytes) ?? ""
        } catch {
            throw SSHError.underlying(error)
        }
    }

    // MARK: - Execute with stdin (binary-safe streaming)

    /// Execute `command` and stream `data` to its standard input over the
    /// SSH exec channel. The exec channel is 8-bit safe (RFC 4254), so no
    /// base64/heredoc wrapping is needed — raw binary goes over the wire.
    ///
    /// Use this for large uploads. The alternative — baking the payload
    /// into the ExecRequest string via a heredoc — makes the server close
    /// the connection ("Connection reset by peer") somewhere above a few
    /// MB because OpenSSH's per-packet / per-channel buffers can't
    /// accommodate multi-megabyte exec command strings. Streaming via
    /// stdin sidesteps the limit: each `outbound.write` becomes a bounded
    /// `CHANNEL_DATA` frame that NIOSSH chops to the negotiated packet
    /// size, and the server only sees a small command string on the
    /// ExecRequest itself.
    ///
    /// We don't collect stdout/stderr here. Iterating `inbound` inside the
    /// closure would deadlock: the remote side can't send EOF until it
    /// sees EOF on its stdin, which only happens when this closure returns
    /// and Citadel closes the channel. Callers that need verification
    /// should do it via a follow-up `execute(…)` (e.g. `wc -c`).
    func executeWithStdin(
        _ command: String,
        data: Data,
        chunkSize: Int = 32_768
    ) async throws {
        guard let c = client else { throw SSHError.notConnected }
        do {
            try await c.withExec(command) { _, outbound in
                var offset = 0
                while offset < data.count {
                    let end = Swift.min(offset + chunkSize, data.count)
                    var buf = ByteBuffer()
                    buf.writeBytes(data[offset..<end])
                    try await outbound.write(buf)
                    offset = end
                }
            }
        } catch {
            throw SSHError.underlying(error)
        }
    }

    // MARK: - Upload (base64 heredoc, NOT SFTP)

    /// Upload a UTF-8 string as a file at `remotePath`.
    ///
    /// **Does not use SFTP** — Citadel's SFTP support has historically been
    /// version-fragile. Instead we base64-encode the content and pipe it through
    /// `base64 -d` on the far end via a heredoc. After upload we verify the
    /// written size with `wc -c` and throw `SSHError.uploadSizeMismatch` if it
    /// doesn't match — this catches silent truncation (most commonly when a
    /// writable-path issue or a full disk causes partial writes).
    ///
    /// Sentinel `B64EOF` is quoted (`'B64EOF'`) so the shell doesn't expand any
    /// `$`/backtick sequences that might appear in the base64 alphabet. It can't,
    /// in practice, but belt-and-suspenders.
    func uploadFile(content: String, remotePath: String) async throws {
        guard let c = client else { throw SSHError.notConnected }
        let data = Data(content.utf8)
        let b64 = data.base64EncodedString()
        let expectedSize = data.count

        let command = """
        base64 -d > \(shellEscape(remotePath)) << 'B64EOF'
        \(b64)
        B64EOF
        """

        do {
            _ = try await c.executeCommand(command)
        } catch {
            throw SSHError.underlying(error)
        }

        // Verify write.
        let sizeRaw = try await execute("wc -c < \(shellEscape(remotePath))")
        let trimmed = sizeRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let got = Int(trimmed) else {
            throw SSHError.uploadSizeMismatch(expected: expectedSize, got: -1)
        }
        guard got == expectedSize else {
            throw SSHError.uploadSizeMismatch(expected: expectedSize, got: got)
        }
    }

    // MARK: - Privilege mode

    /// Runs `id -u` and caches whether the SSH user is already root. Called
    /// automatically by each `connect*` method; callers generally don't need to
    /// invoke it directly but it's public so the test harness / recovery flow
    /// can force a re-check.
    func detectPrivilegeMode() async throws {
        let uidRaw = try await execute("id -u")
        let trimmed = uidRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        privilegeMode = (trimmed == "0") ? .root : .nonRoot
    }

    /// True if this SSH login is root (uid 0). Useful for skipping sudo entirely.
    func sshUserIsRoot() -> Bool {
        privilegeMode == .root
    }

    // MARK: - Sudo

    /// Stash the sudo password for subsequent `sudoCommand`-wrapped executes.
    /// Cleared on `disconnect()`. Pass `nil` to clear explicitly.
    func setSudoPassword(_ password: String?) {
        self.sudoPassword = password
    }

    /// Probe the sudo password without doing anything. Emits `__EXIT:$?` as a
    /// trailer so we can parse the exit code even though the command's stderr is
    /// swallowed. Returns `true` iff sudo accepts the password.
    ///
    /// `sudo -k` clears any cached credential from a previous invocation so this
    /// always actually prompts (i.e., tests the password rather than the cache).
    /// `-S` reads the password from stdin; `-p ''` keeps the "[sudo] password for X:"
    /// prompt from contaminating stdout.
    func validateSudoPassword() async throws -> Bool {
        guard let pw = sudoPassword, !pw.isEmpty else { return false }
        if sshUserIsRoot() { return true }

        let b64 = Data(pw.utf8).base64EncodedString()
        let cmd = "echo \(b64) | base64 -d | sudo -k -S -p '' true 2>/dev/null; echo __EXIT:$?"
        let out = try await execute(cmd)
        // Find the marker.
        guard let marker = out.range(of: "__EXIT:") else { return false }
        let suffix = out[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        let exit = Int(suffix.split(separator: "\n").first.map(String.init) ?? "") ?? 1
        return exit == 0
    }

    /// Wrap a command in whatever privilege escalation this connection needs.
    ///
    /// - If the SSH user is root: just wraps in `bash -c`.
    /// - Otherwise: base64-encodes the sudo password and pipes it through
    ///   `sudo -S`. Always appends `2>/dev/null` to suppress the `[sudo] password…`
    ///   prompt that would otherwise leak into the command's output (ref doc §12).
    ///
    /// Assumes `setSudoPassword(_:)` has been called if escalation is needed;
    /// returns a command that will fail loudly if the password is nil/empty.
    func sudoCommand(_ cmd: String) -> String {
        if sshUserIsRoot() {
            return "bash -c \(singleQuote(cmd)) 2>/dev/null"
        }
        let pw = sudoPassword ?? ""
        let b64 = Data(pw.utf8).base64EncodedString()
        return "echo \(b64) | base64 -d | sudo -S bash -c \(singleQuote(cmd)) 2>/dev/null"
    }

    // MARK: - Internals

    private func verifyPin(info: HostKeyInfo, expected: String?) throws {
        guard let expected, !expected.isEmpty else {
            // First connect: caller persists `info.fingerprint`.
            return
        }
        if info.isLegacyFingerprint {
            // Pre-V2 stored a hash of `host:port` instead of the actual host key.
            // Treat as "upgrade silently" — caller replaces the stored value with
            // `info.fingerprint`. We succeed here rather than throwing.
            return
        }
        guard info.fingerprint == expected else {
            throw SSHError.hostKeyMismatch(expected: expected, actual: info.fingerprint)
        }
    }

    /// Quote a string for single-quoted shell context. Replaces embedded single
    /// quotes with the canonical `'\''` sequence.
    private func singleQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Escape a single path for inclusion in a shell command. Same scheme as
    /// `singleQuote` — paths with special characters get quoted safely.
    private func shellEscape(_ path: String) -> String {
        singleQuote(path)
    }
}
