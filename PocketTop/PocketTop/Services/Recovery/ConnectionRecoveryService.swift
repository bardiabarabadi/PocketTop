import Foundation

/// Errors surfaced to callers of `ConnectionRecoveryService`. These map to
/// distinct UI affordances:
///
/// - `sudoPasswordRequired` — the UI should pop a sudo-password prompt for the
///   user; once provided it can be saved to Keychain (biometry-gated) and
///   recovery retried.
/// - `credentialsUnreachable` — something prevented us from reading the api-key
///   or cert fingerprint off the server (usually SSH / shell error). Surface as
///   "can't reach" on the tile; don't block the rest of the app.
/// - `verificationFailed` — SSH credential read succeeded but the HTTPS agent
///   never answered authenticated requests. Usually transient (agent
///   restarting, firewall blip) — the tile shows "can't reach" but the cached
///   credentials remain valid; next app-launch retries.
/// - `cancelled` — user cancelled a biometry prompt. Caller should not retry
///   automatically; wait for a user gesture.
nonisolated enum RecoveryError: Error, Sendable {
    /// Key-auth server, user-readable cache miss, and no sudo password saved in
    /// Keychain. The UI must prompt the user (typically with biometry) before
    /// recovery can proceed.
    case sudoPasswordRequired
    /// SSH connected but reading `/opt/pockettop/.api_key` or computing the
    /// cert fingerprint failed. `message` carries a short operator-facing
    /// description (already sanitised of shell output noise).
    case credentialsUnreachable(String)
    /// SSH credential read succeeded but HTTPS `/version`/`/snapshot` never
    /// answered within the retry budget. `message` carries the last underlying
    /// error's description for diagnostics.
    case verificationFailed(String)
    /// User dismissed the biometry prompt for the sudo password. Caller
    /// shouldn't retry without a fresh user gesture.
    case cancelled
}

/// Successful recovery result for a single server.
///
/// Design note: `certFingerprint` is always the value we just freshly read off
/// the server — NOT `Server.certFingerprint`. Certs rotate (e.g. reinstall),
/// and the recovery flow is the canonical rediscovery path. `wroteBackToServer`
/// tells the caller whether the stored fingerprint should be updated +
/// persisted; the recovery service deliberately does not mutate SwiftData
/// itself beyond a transient in-memory write needed to pin HTTPS during
/// verification.
///
/// The caller is expected to:
/// 1. If `wroteBackToServer == true`, set `server.certFingerprint =
///    result.certFingerprint` and save the model context.
/// 2. Store `apiKey` wherever the session layer expects it (Keychain under
///    `.apiKey` keyed by `server.id.uuidString`, or in-memory for the life of
///    the view model).
///
/// `server` is returned unchanged as a convenience so
/// `recoverAll`-style callers can correlate a result back to its input.
@MainActor
struct RecoveryResult {
    /// The same Server passed in. Returned for caller convenience; the service
    /// does not retain this reference.
    let server: Server
    /// Freshly-read Bearer token for authenticated HTTPS calls. Valid until
    /// the operator rotates `/opt/pockettop/.api_key` on the server.
    let apiKey: String
    /// Freshly-computed SHA-256 DER fingerprint of the live TLS cert, lowercase
    /// hex, 64 chars. May differ from `server.certFingerprint` if the cert was
    /// rotated (reinstall). Check `wroteBackToServer` to know whether an
    /// update is needed.
    let certFingerprint: String
    /// `true` iff the freshly-read fingerprint does not match the value
    /// previously stored on `server`. Callers should persist the new value
    /// when this is true.
    let wroteBackToServer: Bool
}

/// Reconnects to every `isInstalled` server at app launch. Re-derives the live
/// `{api_key, cert_fingerprint}` pair (by briefly SSH-ing in) and verifies the
/// HTTPS agent is reachable with the resulting credentials, so the home tile
/// reflects a real "can/can't-reach" state rather than a stale cache.
///
/// Per ref doc §9:
/// - Password-auth: SSH → sudo-read `/opt/pockettop/.api_key` + fingerprint
///   the cert with openssl → disconnect.
/// - Key-auth: SSH → try the user-readable cache first
///   (`~/.pockettop/{api_key,cert_fp}`, no sudo needed) → only fall back to
///   sudo + root-only files if the cache is missing.
///
/// Failures surface to the UI as a "can't reach" state; they do NOT block the
/// app from launching or other servers from being recovered. Callers should
/// run `recoverAll(servers:)` and render per-server progress/result.
actor ConnectionRecoveryService {
    static let shared = ConnectionRecoveryService()

    private init() {}

    // MARK: - Public API

    /// Recover credentials for a single server and verify HTTPS reachability.
    ///
    /// Must be called on the main actor — `Server` is a SwiftData `@Model`
    /// whose properties are MainActor-isolated. The heavy lifting delegates
    /// to actor-isolated helpers (`SSHService`, URLSession) but the entry
    /// extracts primitives on the main actor first, per the Sendability rule
    /// called out in ref doc §3.
    ///
    /// On success returns a `RecoveryResult`; on failure throws a
    /// `RecoveryError`. In all cases SSH is disconnected before returning.
    @MainActor
    func recover(server: Server) async throws -> RecoveryResult {
        // Extract everything we need from the MainActor-bound `Server` before
        // any actor hops. We read these once here and never re-touch `server`
        // from non-MainActor code.
        let serverHost = server.host
        let serverHTTPSPort = server.httpsPort
        let serverUUID = server.id.uuidString
        let serverName = server.name
        let authMethod = server.authMethod
        let priorCertFingerprint = server.certFingerprint

        // SSH connect + credential read. Branches on auth method.
        let read: CredentialsReadResult
        switch authMethod {
        case .password:
            read = try await readCredentialsWithPasswordAuth(
                server: server,
                uuidString: serverUUID
            )
        case .key:
            read = try await readCredentialsWithKeyAuth(
                server: server,
                uuidString: serverUUID,
                serverDisplayName: serverName
            )
        }

        let freshApiKey = read.apiKey
        let freshFingerprint = read.certFingerprint

        // Mutate `server.certFingerprint` in-memory **before** we construct
        // the pinning HTTPS client below. The MetricsService snapshot-in-init
        // pattern captures the fingerprint once, so if we leave the stale
        // value in place the TLS pin will fail against a rotated cert.
        //
        // We do NOT save the model context here — the caller owns persistence
        // (see `wroteBackToServer` in `RecoveryResult`). The in-memory write
        // is enough for `MetricsService` to pick up the right pin.
        let wroteBack = (freshFingerprint != priorCertFingerprint)
        if wroteBack {
            server.certFingerprint = freshFingerprint
        }

        // Verify HTTPS reachability. Uses the primitives path so we don't
        // capture `server` across the await.
        do {
            try await verifyConnection(
                host: serverHost,
                port: serverHTTPSPort,
                apiKey: freshApiKey,
                certFingerprint: freshFingerprint
            )
        } catch {
            // Roll the in-memory mutation back on failure so we don't leave
            // the model in a half-updated state. The caller can retry later
            // and get a clean starting point.
            if wroteBack {
                server.certFingerprint = priorCertFingerprint
            }
            throw error
        }

        return RecoveryResult(
            server: server,
            apiKey: freshApiKey,
            certFingerprint: freshFingerprint,
            wroteBackToServer: wroteBack
        )
    }

    /// Concurrently recovers all servers. Each server's result is yielded into
    /// the returned stream as it completes — callers can drive per-tile UI
    /// updates live without waiting for the slowest host.
    ///
    /// Ordering is unspecified: a slow host won't hold up a fast one. The
    /// stream finishes once every server has reported exactly once.
    ///
    /// MainActor-isolated because the `Server` array elements are not
    /// Sendable; the TaskGroup workers hop into MainActor for the `recover`
    /// call per server.
    @MainActor
    func recoverAll(
        servers: [Server]
    ) -> AsyncStream<(Server, Result<RecoveryResult, Error>)> {
        AsyncStream { continuation in
            // We don't gate the fan-out because SSH concurrency is bounded by
            // the number of installed servers (typically < 10) and each
            // connection uses its own Citadel client. If this ever becomes a
            // problem we can cap it with a semaphore.
            let driver = Task { @MainActor in
                await withTaskGroup(of: Void.self) { group in
                    for server in servers {
                        group.addTask { @MainActor in
                            let outcome: Result<RecoveryResult, Error>
                            do {
                                let result = try await self.recover(server: server)
                                outcome = .success(result)
                            } catch {
                                outcome = .failure(error)
                            }
                            continuation.yield((server, outcome))
                        }
                    }
                    await group.waitForAll()
                }
                continuation.finish()
            }

            // If the consumer stops iterating early, tear down the whole
            // fan-out. Each individual `recover` call will still disconnect
            // its SSH session via the defer in the helpers below.
            continuation.onTermination = { _ in
                driver.cancel()
            }
        }
    }

    /// Polls `GET /version` then an authenticated `GET /snapshot` up to
    /// `attempts` times, sleeping `delay` between attempts. Returns as soon as
    /// both succeed in the same iteration; throws `RecoveryError.verificationFailed`
    /// on exhaustion.
    ///
    /// Uses `MetricsSessionPool` directly with the supplied fingerprint,
    /// deliberately bypassing `MetricsService` so that callers who are NOT
    /// inside `recover` (i.e. don't have a `Server` handy) can still verify a
    /// freshly-rotated fingerprint without mutating any model. See the class-
    /// level docs on why `MetricsService.init(server:apiKey:)` snapshots the
    /// fingerprint once and therefore needs a correctly-seeded `Server`.
    ///
    /// Defaults match ref doc §9: 10 attempts × 300ms ≈ 3s worst case. Plenty
    /// for a systemd unit that just came up.
    nonisolated func verifyConnection(
        host: String,
        port: Int,
        apiKey: String,
        certFingerprint: String,
        attempts: Int = 10,
        delay: Duration = .milliseconds(300)
    ) async throws {
        var lastError: Error?

        for attempt in 1...max(attempts, 1) {
            do {
                try await probeVersion(host: host, port: port, certFingerprint: certFingerprint)
                try await probeSnapshot(
                    host: host,
                    port: port,
                    apiKey: apiKey,
                    certFingerprint: certFingerprint
                )
                return
            } catch {
                lastError = error
                if attempt == attempts { break }
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    // Task cancelled during sleep — report what we had.
                    throw RecoveryError.verificationFailed(
                        "cancelled during verify: \(String(describing: error))"
                    )
                }
            }
        }

        throw RecoveryError.verificationFailed(
            String(describing: lastError ?? RecoveryError.verificationFailed("unknown"))
        )
    }

    // MARK: - Credential-read branches

    /// Package of freshly-read credentials from the server.
    private struct CredentialsReadResult {
        let apiKey: String
        let certFingerprint: String
    }

    /// Password auth — both SSH login and sudo use the SSH password. Reads
    /// the api-key + cert fingerprint in one composite command to minimise
    /// round-trips.
    @MainActor
    private func readCredentialsWithPasswordAuth(
        server: Server,
        uuidString: String
    ) async throws -> CredentialsReadResult {
        guard let sshPassword = KeychainService.load(
            key: .sshPassword,
            account: uuidString
        ), !sshPassword.isEmpty else {
            throw RecoveryError.credentialsUnreachable("no saved ssh password")
        }

        let ssh: SSHService
        do {
            ssh = try await SSHConnectionHelper.connect(to: server)
        } catch {
            throw RecoveryError.credentialsUnreachable(
                "ssh connect failed: \(String(describing: error))"
            )
        }

        // Password-auth path re-uses the SSH password as the sudo password.
        // If the user happens to be root, `sudoCommand` is a no-op wrapper
        // so this remains cheap.
        await ssh.setSudoPassword(sshPassword)

        do {
            let result = try await readCredentialsOverSSH(ssh: ssh, preferUserCache: false)
            await ssh.disconnect()
            return result
        } catch {
            await ssh.disconnect()
            throw error
        }
    }

    /// Key auth — tries the user-readable cache first (no sudo needed). Falls
    /// back to `/opt/pockettop/.api_key` via sudo only if the cache is missing
    /// or unreadable.
    @MainActor
    private func readCredentialsWithKeyAuth(
        server: Server,
        uuidString: String,
        serverDisplayName: String
    ) async throws -> CredentialsReadResult {
        // Capture the flag now on MainActor so the actor-hop below doesn't
        // need to re-read a non-Sendable Server.
        let sudoPasswordSaved = server.sudoPasswordSaved

        let ssh: SSHService
        do {
            ssh = try await SSHConnectionHelper.connect(to: server)
        } catch {
            throw RecoveryError.credentialsUnreachable(
                "ssh connect failed: \(String(describing: error))"
            )
        }

        // 1) User-readable cache attempt — no sudo, runs as the SSH login user.
        let cacheResult = await readUserReadableCache(ssh: ssh)
        if let cached = cacheResult {
            await ssh.disconnect()
            return cached
        }

        // 2) Cache miss — sudo path. Short-circuit if we know the user never
        //    opted to save a sudo password: avoids triggering the biometry
        //    prompt just to fail with `.notFound`. The Server's own flag is
        //    the source of truth — even if an orphan Keychain item exists
        //    from a prior install, without consent we shouldn't use it.
        guard sudoPasswordSaved else {
            await ssh.disconnect()
            throw RecoveryError.sudoPasswordRequired
        }

        //    Biometry-gated Keychain load. `loadWithBiometry` returns a
        //    `Result` so we can distinguish user cancel (propagate as
        //    `.cancelled`) from not-found (propagate as
        //    `.sudoPasswordRequired`, which the UI handles by prompting).
        let sudoLoad = KeychainService.loadWithBiometry(
            key: .sudoPassword,
            account: uuidString,
            reason: "Refresh credentials for \(serverDisplayName)"
        )
        switch sudoLoad {
        case .success(let sudoPassword):
            await ssh.setSudoPassword(sudoPassword)
            do {
                let result = try await readCredentialsOverSSH(ssh: ssh, preferUserCache: false)
                await ssh.disconnect()
                return result
            } catch {
                await ssh.disconnect()
                throw error
            }
        case .failure(.notFound):
            await ssh.disconnect()
            throw RecoveryError.sudoPasswordRequired
        case .failure(.userCancelled):
            await ssh.disconnect()
            throw RecoveryError.cancelled
        case .failure(.authenticationFailed):
            // Biometry hard-failed (lockout etc). Treat like cancellation so
            // the UI doesn't immediately re-prompt; user can retry manually.
            await ssh.disconnect()
            throw RecoveryError.cancelled
        case .failure(.unknown(let status)):
            await ssh.disconnect()
            throw RecoveryError.credentialsUnreachable(
                "keychain error \(status) loading sudo password"
            )
        }
    }

    // MARK: - SSH command plumbing

    /// Composite one-shot read of api-key + cert fingerprint from the
    /// canonical root-owned locations. Runs under sudo if the SSH user isn't
    /// root (`SSHService.sudoCommand` no-ops for root).
    ///
    /// The `cert_fp` pipeline mirrors what the install script writes into
    /// `~/.pockettop/cert_fp`: `openssl x509 -fingerprint -sha256` → strip
    /// `SHA256 Fingerprint=` prefix → strip colons → lowercase. Matches the
    /// 64-char hex format `CertPinningDelegate` compares against.
    ///
    /// Returns the parsed pair; throws `RecoveryError.credentialsUnreachable`
    /// if either half is missing / malformed.
    private func readCredentialsOverSSH(
        ssh: SSHService,
        preferUserCache: Bool
    ) async throws -> CredentialsReadResult {
        // Composite read: print api-key, a sentinel, then fingerprint.
        // Sentinel `---` is a safe delimiter because neither a hex api-key
        // nor a hex fingerprint contains `-`.
        let rootRead =
            "cat /opt/pockettop/.api_key; " +
            "echo '---'; " +
            "openssl x509 -fingerprint -sha256 -noout -in /opt/pockettop/certs/server.crt " +
            "| sed 's/^.*=//' | tr -d ':' | tr '[:upper:]' '[:lower:]'"

        let wrapped = await ssh.sudoCommand(rootRead)

        let output: String
        do {
            output = try await ssh.execute(wrapped)
        } catch {
            throw RecoveryError.credentialsUnreachable(
                "ssh exec failed: \(String(describing: error))"
            )
        }

        return try parseCompositeRead(output: output, source: "root files")
    }

    /// User-readable cache attempt. Returns `nil` (not throws) on any read
    /// failure so the caller can fall through to the sudo path. We only bind
    /// a full result when BOTH halves parse cleanly.
    private func readUserReadableCache(ssh: SSHService) async -> CredentialsReadResult? {
        // Note: no sudo. Runs as the SSH login user. Both files are mode 600
        // owned by that user per the install script (ref doc §5 step 9).
        //
        // `2>/dev/null` on each cat so a missing file produces an empty line
        // rather than an error-prefixed output we'd have to strip.
        let cmd =
            "cat ~/.pockettop/api_key 2>/dev/null; " +
            "echo '---'; " +
            "cat ~/.pockettop/cert_fp 2>/dev/null"

        let output: String
        do {
            output = try await ssh.execute(cmd)
        } catch {
            // Any exec error — treat as cache miss and let the caller fall
            // back to sudo. We deliberately do not surface this.
            return nil
        }

        do {
            return try parseCompositeRead(output: output, source: "user cache")
        } catch {
            return nil
        }
    }

    /// Splits an `apikey\n---\nfingerprint` blob into its two halves and
    /// validates both are non-empty after trim. Throws
    /// `RecoveryError.credentialsUnreachable` with `source` in the message on
    /// malformed input — callers can include `source` in logs to distinguish
    /// the sudo-backed read from the user-cache read.
    private func parseCompositeRead(
        output: String,
        source: String
    ) throws -> CredentialsReadResult {
        // Trim surrounding whitespace; preserve internal structure.
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.components(separatedBy: "---")
        guard parts.count >= 2 else {
            throw RecoveryError.credentialsUnreachable(
                "\(source): missing separator in output"
            )
        }

        let apiKey = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        // Join the rest with `---` back together in case a fingerprint somehow
        // contained literal `---` (it can't — hex only — but being defensive
        // keeps the parser future-proof if we ever ship a different format).
        let fingerprintRaw = parts[1...]
            .joined(separator: "---")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !apiKey.isEmpty else {
            throw RecoveryError.credentialsUnreachable("\(source): empty api key")
        }
        guard !fingerprintRaw.isEmpty else {
            throw RecoveryError.credentialsUnreachable("\(source): empty fingerprint")
        }

        // Normalise to lowercase hex without colons. The openssl pipeline
        // already does this, but the user cache might have been written by
        // an older installer version — the extra normalise is cheap.
        let fingerprint = fingerprintRaw
            .replacingOccurrences(of: ":", with: "")
            .lowercased()

        // Minimal sanity check: SHA-256 hex is 64 chars. Reject obvious
        // garbage so we don't hand an unusable pin to the HTTPS layer.
        guard fingerprint.count == 64,
              fingerprint.allSatisfy({ $0.isHexDigit }) else {
            throw RecoveryError.credentialsUnreachable(
                "\(source): malformed fingerprint (len=\(fingerprint.count))"
            )
        }

        return CredentialsReadResult(apiKey: apiKey, certFingerprint: fingerprint)
    }

    // MARK: - HTTPS probes (used by verifyConnection)

    /// Hits `GET /version` — unauthenticated. Confirms the TLS pin and the
    /// agent's HTTP handler are both functional. Throws on any non-2xx or
    /// transport error.
    private nonisolated func probeVersion(
        host: String,
        port: Int,
        certFingerprint: String
    ) async throws {
        let data = try await performGet(
            host: host,
            port: port,
            path: "/version",
            apiKey: nil,
            certFingerprint: certFingerprint
        )
        // Body must decode as `VersionResponse`. If it doesn't, the server
        // is almost certainly not pockettopd (wrong service on this port).
        do {
            _ = try JSONDecoder().decode(VersionResponse.self, from: data)
        } catch {
            throw RecoveryError.verificationFailed(
                "version decode failed: \(String(describing: error))"
            )
        }
    }

    /// Hits `GET /history` — authenticated. Confirms the api-key is accepted
    /// by the agent in addition to TLS/auth being intact. We don't decode
    /// the response body here (a successful HTTP 200 is sufficient signal
    /// for this health-check) — full history decoding happens in the
    /// detail view.
    private nonisolated func probeSnapshot(
        host: String,
        port: Int,
        apiKey: String,
        certFingerprint: String
    ) async throws {
        _ = try await performGet(
            host: host,
            port: port,
            path: "/history",
            apiKey: apiKey,
            certFingerprint: certFingerprint
        )
    }

    /// Shared request plumbing used by both probes. Uses the pooled pinning
    /// session keyed by `(host, port, fp.prefix(16))`, so a recovery cycle
    /// against a freshly-rotated cert gets a fresh session automatically
    /// (the key differs from any cached session bound to the old fp).
    private nonisolated func performGet(
        host: String,
        port: Int,
        path: String,
        apiKey: String?,
        certFingerprint: String
    ) async throws -> Data {
        guard let url = URL(string: "https://\(host):\(port)\(path)") else {
            throw RecoveryError.verificationFailed("bad url for \(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        // Keep the probe timeouts conservative. The pool already applies 5s
        // request / 10s resource, which dominates; our own attempt loop
        // handles longer-horizon retries.
        request.timeoutInterval = 5

        let session = MetricsSessionPool.shared.session(
            host: host,
            port: port,
            certFingerprint: certFingerprint
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RecoveryError.verificationFailed(
                "transport \(path): \(String(describing: error))"
            )
        }

        guard let http = response as? HTTPURLResponse else {
            throw RecoveryError.verificationFailed("non-HTTP response for \(path)")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw RecoveryError.verificationFailed(
                "http \(http.statusCode) for \(path)"
            )
        }
        return data
    }
}
