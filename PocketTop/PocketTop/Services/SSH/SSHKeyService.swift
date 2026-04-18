import Foundation
import Crypto
import Citadel

/// SSH key generation, storage, parsing, and fingerprinting.
///
/// All operations here are independent of any live SSH connection — think of
/// this as the crypto sibling to `SSHService`'s transport layer. Ported from
/// `docs/SSH_App_Architecture_Reference.md` §4, "SSH Key Generation & Storage".
///
/// Usage patterns:
/// - **App-wide shared key.** Call `loadOrGenerateAppKey(comment:)` — returns a
///   singleton Ed25519 keypair stored under Keychain account
///   `"app-shared-ssh-key"`. All servers set up via the in-app key-setup flow
///   share this one key.
/// - **BYO key import.** Call `parsePrivateKey(pem:passphrase:)` to decode a
///   user-supplied PEM. We validate it actually loads (catching wrong-passphrase
///   up front) before offering to save it.
/// - **Fingerprint display.** Call `makeFingerprint(fromOpenSSHPublicLine:)` to
///   produce the standard `SHA256:<base64>` string users recognise from
///   `ssh-keygen -lf`.
nonisolated enum SSHKeyService {

    // MARK: - Types

    /// Result of parsing a PEM. Only Ed25519 and RSA are supported at the SSH
    /// level by the V1 install path; DSA and ECDSA keys exist in the wild but
    /// Citadel's auth helpers don't accept them.
    enum ParsedKey {
        case ed25519(Curve25519.Signing.PrivateKey)
        case rsa(Insecure.RSA.PrivateKey)
    }

    /// A freshly-generated keypair plus its serialised forms.
    struct GeneratedKey {
        /// The private key object itself.
        let privateKey: Curve25519.Signing.PrivateKey
        /// OpenSSH-format private key PEM (begins with
        /// `-----BEGIN OPENSSH PRIVATE KEY-----`). Suitable for writing to
        /// `~/.ssh/id_ed25519` on another box, or stashing in the Keychain.
        let privatePEM: String
        /// OpenSSH public-key line (`ssh-ed25519 AAAA… comment`). This is what
        /// gets appended to `authorized_keys` on the server.
        let publicLine: String
        /// `SHA256:…` fingerprint of the public key. Used in the UI so the user
        /// can verify the key they see on the server matches.
        let publicFingerprint: String
        /// The comment baked into `publicLine`.
        let comment: String
    }

    enum KeyError: Error {
        /// PEM is encrypted but no passphrase was supplied.
        case passphraseRequired
        /// Passphrase did not decrypt the PEM.
        case wrongPassphrase
        /// The PEM parsed but the contained key is neither Ed25519 nor RSA.
        case unsupportedKeyType
        /// Couldn't parse the PEM at all — malformed input.
        case malformedPEM
        /// Generic Keychain save/load failure bubbled up from `KeychainService`.
        case keychain(KeychainError)
    }

    // MARK: - Generation

    /// Generate a fresh Ed25519 keypair and serialise it to OpenSSH formats.
    ///
    /// `comment` shows up as the trailing token in the `authorized_keys` line
    /// and in `ssh -v` diagnostics. We default callers to something
    /// identifiable like `"pockettop@<device-name>"`.
    static func generateEd25519(comment: String) throws -> GeneratedKey {
        let priv = Curve25519.Signing.PrivateKey()

        // Citadel ships a `.makeSSHRepresentation(comment:)` helper on this
        // CryptoKit type — it emits the OpenSSH private-key PEM format.
        let pem = priv.makeSSHRepresentation(comment: comment)

        // Public-line construction happens in `makeOpenSSHPublicLine` so the
        // wire format is in one place and can be reused by fingerprint-only
        // paths (e.g., displaying the FP before we've committed the key).
        let pubRaw = Data(priv.publicKey.rawRepresentation)
        let publicLine = makeOpenSSHPublicLine(
            ed25519PublicKeyRaw: pubRaw,
            comment: comment
        )
        let fp = makeFingerprint(fromOpenSSHPublicLine: publicLine)

        return GeneratedKey(
            privateKey: priv,
            privatePEM: pem,
            publicLine: publicLine,
            publicFingerprint: fp,
            comment: comment
        )
    }

    // MARK: - App-wide singleton key

    /// Load the app-wide SSH key from the Keychain, or generate & save one if
    /// it's missing.
    ///
    /// All servers set up via the key-setup wizard share this single keypair —
    /// the user only has to add one public key to each new machine. See ref
    /// doc §8 for rationale (reduces Keychain fragmentation, avoids every
    /// server having a distinct "which key file did I use" answer).
    ///
    /// The key is saved **without biometry** (ref doc §8): Face ID prompts on
    /// every SSH reconnect would be unusable for a glance-in-your-pocket app.
    static func loadOrGenerateAppKey(comment: String) throws -> GeneratedKey {
        // First try the Keychain.
        if let existingPEM = KeychainService.load(
            key: .sshPrivateKey,
            account: KeychainService.sshAppKeyAccount
        ) {
            let parsed = try parsePrivateKey(pem: existingPEM, passphrase: nil)
            guard case let .ed25519(priv) = parsed else {
                // Someone stuffed an RSA key in here. Back up and regenerate.
                throw KeyError.unsupportedKeyType
            }
            let pubRaw = Data(priv.publicKey.rawRepresentation)
            let publicLine = makeOpenSSHPublicLine(
                ed25519PublicKeyRaw: pubRaw,
                comment: comment
            )
            let fp = makeFingerprint(fromOpenSSHPublicLine: publicLine)
            return GeneratedKey(
                privateKey: priv,
                privatePEM: existingPEM,
                publicLine: publicLine,
                publicFingerprint: fp,
                comment: comment
            )
        }

        // Generate + save.
        let fresh = try generateEd25519(comment: comment)
        do {
            try KeychainService.save(
                key: .sshPrivateKey,
                value: fresh.privatePEM,
                account: KeychainService.sshAppKeyAccount,
                requiresBiometry: false
            )
        } catch let e as KeychainError {
            throw KeyError.keychain(e)
        }
        return fresh
    }

    // MARK: - Parsing

    /// Parse an OpenSSH-format PEM into a `ParsedKey`.
    ///
    /// Detects encrypted keys and wrong passphrases and surfaces them as
    /// `KeyError.passphraseRequired` / `.wrongPassphrase` so the UI can prompt
    /// the user appropriately. Ref doc §4.
    static func parsePrivateKey(pem: String, passphrase: String?) throws -> ParsedKey {
        // Normalise line endings — iOS pasteboard sometimes has \r\n or mixed.
        let normalized = pem
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // Surface-level "is this encrypted?" check. The OpenSSH private-key
        // format encodes `kdfname` in the body; if it's anything other than
        // `none` we need a passphrase. We look for the PEM header for RSA/EC
        // keys and for the OpenSSH `bcrypt` marker for encrypted Ed25519/RSA.
        let isEncrypted = normalized.contains("ENCRYPTED")
            || normalized.contains("bcrypt")
        if isEncrypted && (passphrase == nil || passphrase!.isEmpty) {
            throw KeyError.passphraseRequired
        }

        // Try Ed25519 first — that's what we generate ourselves, so the fast
        // path.
        do {
            let priv = try Curve25519.Signing.PrivateKey(sshEd25519: normalized)
            return .ed25519(priv)
        } catch {
            // Fall through to RSA.
        }

        // Try RSA.
        do {
            let priv = try Insecure.RSA.PrivateKey(sshRsa: normalized)
            return .rsa(priv)
        } catch {
            // Distinguish "wrong passphrase on an encrypted key" from
            // "genuinely bad PEM". Citadel doesn't expose a typed error here
            // so we fall back to the heuristic: if the string looks encrypted,
            // assume wrong passphrase; otherwise it's malformed.
            if isEncrypted {
                throw KeyError.wrongPassphrase
            }
            throw KeyError.malformedPEM
        }
    }

    // MARK: - OpenSSH wire format

    /// Build the `ssh-ed25519 AAAA… <comment>` line from a raw public key.
    ///
    /// Wire format of the base64 blob:
    /// ```
    /// uint32  name_length = 11
    /// string  "ssh-ed25519"
    /// uint32  pubkey_length = 32
    /// string  <32 bytes of the Ed25519 public key>
    /// ```
    ///
    /// We construct this manually rather than relying on any Citadel helper so
    /// the path is identical whether the caller has a freshly-generated key or
    /// a pubkey recovered from storage.
    static func makeOpenSSHPublicLine(
        ed25519PublicKeyRaw: Data,
        comment: String
    ) -> String {
        precondition(ed25519PublicKeyRaw.count == 32, "Ed25519 public key must be 32 bytes")
        let typeName = "ssh-ed25519"
        var buf = Data()
        buf.append(uint32BE(UInt32(typeName.utf8.count)))
        buf.append(Data(typeName.utf8))
        buf.append(uint32BE(UInt32(ed25519PublicKeyRaw.count)))
        buf.append(ed25519PublicKeyRaw)
        let b64 = buf.base64EncodedString()
        if comment.isEmpty {
            return "\(typeName) \(b64)"
        }
        return "\(typeName) \(b64) \(comment)"
    }

    /// Compute the `SHA256:<base64>` fingerprint from a single OpenSSH public
    /// key line. Strips trailing `=` padding to match `ssh-keygen -lf` output.
    static func makeFingerprint(fromOpenSSHPublicLine line: String) -> String {
        // Standard line: "<type> <base64-blob> [comment]". We want the blob.
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2,
              let blob = Data(base64Encoded: String(parts[1])) else {
            // Malformed — return a sentinel rather than crashing. Should never
            // happen with our own output but the parser must be robust.
            return "SHA256:invalid"
        }
        let hash = SHA256.hash(data: blob)
        let b64 = Data(hash).base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:\(b64)"
    }

    // MARK: - Byte helpers

    private static func uint32BE(_ value: UInt32) -> Data {
        var be = value.bigEndian
        return withUnsafeBytes(of: &be) { Data($0) }
    }
}
