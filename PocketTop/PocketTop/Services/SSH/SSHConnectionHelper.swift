import Foundation

/// Single place where a `Server` row becomes a live `SSHService`.
///
/// Used by the installer, upgrade flow, connection-recovery service, and anything
/// else that needs SSH. Centralising this logic means the password-vs-key branch,
/// the Keychain lookup order, and host-key pinning all live in one place rather
/// than being reinvented per caller.
///
/// Ref doc §9.
enum SSHConnectionHelper {

    /// Errors raised by the helper before or during the attempt to reach a
    /// connected state. Once `connect` returns, subsequent failures are raised
    /// from `SSHService` itself.
    enum HelperError: Error {
        /// Password auth requested but no password was in the Keychain.
        case sshPasswordNotFound
        /// Key auth requested but no key was in the Keychain at either the
        /// `keychainKeyAccount` or per-server location.
        case sshPrivateKeyNotFound
        /// The key parsed successfully but is neither Ed25519 nor RSA.
        case unsupportedKeyType
        /// Decrypting the PEM failed (wrong / missing passphrase). Rare in V1
        /// because we generate unencrypted keys, but imported BYO-keys can hit
        /// this.
        case privateKeyDecryptFailed
    }

    /// Open a connection for `server`, using whichever auth method the `Server`
    /// row specifies.
    ///
    /// Contract:
    /// - Loads the SSH secret from the Keychain — password if
    ///   `server.authMethodRaw == "password"`, PEM otherwise.
    /// - For keys: tries `server.keychainKeyAccount` first (the app-wide shared
    ///   key account, typically `"app-shared-ssh-key"`), then falls back to
    ///   `server.id.uuidString` for legacy per-server storage.
    /// - Pins against `server.sshHostKeyFingerprint`. If that string is empty
    ///   (first-ever connect for this row) we let the handshake succeed and
    ///   return the captured fingerprint so the caller can persist it.
    /// - Caller is responsible for storing a newly-captured fingerprint back on
    ///   `server.sshHostKeyFingerprint` and saving the model context. The helper
    ///   does not touch SwiftData — it's deliberately a pure connect utility.
    static func connect(to server: Server) async throws -> SSHService {
        let ssh = SSHService()

        let expected: String? = server.sshHostKeyFingerprint.isEmpty
            ? nil
            : server.sshHostKeyFingerprint

        switch server.authMethod {
        case .password:
            // Password can live under either the per-server UUID account (normal
            // case) or the saved-connection account (`host:port:user`) used by
            // the setup form's "recent connections" list. Installers only ever
            // deal with the UUID account, so we try that first.
            let account = server.id.uuidString
            guard let password = KeychainService.load(key: .sshPassword, account: account) else {
                throw HelperError.sshPasswordNotFound
            }
            _ = try await ssh.connect(
                host: server.host,
                port: server.sshPort,
                username: server.sshUsername,
                password: password,
                expectedFingerprint: expected
            )

        case .key:
            // Lookup order per ref doc §8:
            //   1. The account recorded on the server row (usually the shared
            //      `"app-shared-ssh-key"` account).
            //   2. Fallback to the per-server UUID for legacy rows that never
            //      set `keychainKeyAccount`.
            let pem = loadPrivateKeyPEM(for: server)
            guard let pem else { throw HelperError.sshPrivateKeyNotFound }

            let parsed: SSHKeyService.ParsedKey
            do {
                // We don't carry passphrases for stored keys (we generate
                // unencrypted app keys; BYO keys were decrypted before saving).
                parsed = try SSHKeyService.parsePrivateKey(pem: pem, passphrase: nil)
            } catch SSHKeyService.KeyError.passphraseRequired,
                    SSHKeyService.KeyError.wrongPassphrase {
                throw HelperError.privateKeyDecryptFailed
            } catch {
                throw error
            }

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

    // MARK: - Internals

    /// Try `keychainKeyAccount` then fall back to the per-server UUID. Returns
    /// `nil` if neither has an entry.
    private static func loadPrivateKeyPEM(for server: Server) -> String? {
        if let acct = server.keychainKeyAccount, !acct.isEmpty,
           let pem = KeychainService.load(key: .sshPrivateKey, account: acct) {
            return pem
        }
        return KeychainService.load(key: .sshPrivateKey, account: server.id.uuidString)
    }
}
