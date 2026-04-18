import Foundation
import SwiftData

/// Primary persisted entity. One `Server` per monitored host.
///
/// Field conventions (per `docs/SSH_App_Architecture_Reference.md` §3):
/// - All additions made after the initial shipping schema are **optional-with-default**
///   so SwiftData lightweight migration handles them automatically. If you ever need
///   to add a non-optional field, ship it as optional-with-default first, then tighten
///   in a later version after the default has propagated.
/// - `serverIdentity` is stable across reinstalls (sourced from `/etc/machine-id` at
///   install time) — this is what we use to recognize the same host even after IP
///   changes.
/// - `sshHostKeyFingerprint` is the SHA-256 of the serialized `NIOSSHPublicKey`
///   captured on first connect and pinned thereafter.
/// - `certFingerprint` is the SHA-256 of the DER-encoded leaf cert (hex, lowercase,
///   64 chars) used by `CertPinningDelegate`.
/// - `authMethodRaw` discriminates between `"password"` and `"key"` auth paths.
///   Defaults to `"password"` so legacy V1 rows come through migration unchanged.
/// - `osFamily` defaults to `"linux"`. V2 will use `"windows"`, V3 `"macos"`. Declared
///   up-front so adding those OS families later does not trigger a schema migration.
@Model
final class Server {
    // MARK: - Identity

    var id: UUID
    /// `/etc/machine-id` (or `/var/lib/dbus/machine-id` fallback) — stable across
    /// reinstalls; lets us recognise the same host after IP changes.
    var serverIdentity: String
    /// Display name. Usually `==host` at setup time but user-editable later.
    var name: String

    // MARK: - Connection

    var host: String
    var sshPort: Int
    var sshUsername: String
    /// Always `443` for V1 — the install script pins the HTTPS port. Kept configurable
    /// for forward-compat.
    var httpsPort: Int

    /// `"linux" | "windows" | "macos"`. V1 only ships Linux; field exists so V2/V3
    /// can slot in without a schema change.
    var osFamily: String = "linux"

    // MARK: - Pinning

    /// SHA-256 of the DER-encoded leaf TLS certificate (hex, lowercase, 64 chars).
    /// Used by `CertPinningDelegate`.
    var certFingerprint: String
    /// SHA-256 of the serialized SSH host public key. Captured on first connect,
    /// pinned on all subsequent connects.
    var sshHostKeyFingerprint: String

    // MARK: - Install state

    var isInstalled: Bool
    var createdAt: Date
    var updatedAt: Date

    // MARK: - Auth (V2+ additions — optional with default)

    /// `"password"` or `"key"`. Default `"password"` matches legacy rows.
    var authMethodRaw: String = "password"
    /// `"ed25519"` or `"rsa"` when `authMethodRaw == "key"`; nil otherwise.
    var keyType: String?
    /// OpenSSH-style SHA-256 fingerprint of the public key (e.g. `SHA256:abc...`).
    /// Displayed in the UI so the user can confirm what's been registered on the
    /// server.
    var publicKeyFingerprint: String?
    /// Free-form comment the user/app attached to the key (typically the email or
    /// host identifier written into `authorized_keys`).
    var keyComment: String?
    /// Which Keychain account holds the SSH private key for this server:
    /// - `nil`: legacy per-server storage, key under `server.id.uuidString`.
    /// - `"app-shared-ssh-key"`: shared app-wide keypair (see
    ///   `KeychainService.sshAppKeyAccount`).
    ///
    /// Lookup order at connect time: try this account first, fall back to the
    /// per-server UUID account.
    var keychainKeyAccount: String?

    /// True if the user opted to save the sudo password to Keychain (guarded by
    /// biometry). False if the user chose to enter it every time.
    var sudoPasswordSaved: Bool = false

    // MARK: - Init

    init(
        id: UUID = UUID(),
        serverIdentity: String,
        name: String,
        host: String,
        sshPort: Int = 22,
        sshUsername: String,
        httpsPort: Int = 443,
        osFamily: String = "linux",
        certFingerprint: String = "",
        sshHostKeyFingerprint: String = "",
        isInstalled: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        authMethodRaw: String = "password",
        keyType: String? = nil,
        publicKeyFingerprint: String? = nil,
        keyComment: String? = nil,
        keychainKeyAccount: String? = nil,
        sudoPasswordSaved: Bool = false
    ) {
        self.id = id
        self.serverIdentity = serverIdentity
        self.name = name
        self.host = host
        self.sshPort = sshPort
        self.sshUsername = sshUsername
        self.httpsPort = httpsPort
        self.osFamily = osFamily
        self.certFingerprint = certFingerprint
        self.sshHostKeyFingerprint = sshHostKeyFingerprint
        self.isInstalled = isInstalled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.authMethodRaw = authMethodRaw
        self.keyType = keyType
        self.publicKeyFingerprint = publicKeyFingerprint
        self.keyComment = keyComment
        self.keychainKeyAccount = keychainKeyAccount
        self.sudoPasswordSaved = sudoPasswordSaved
    }
}

// MARK: - Convenience

extension Server {
    enum AuthMethod: String {
        case password
        case key
    }

    /// Typed accessor for `authMethodRaw`. Unknown raw values fall back to `.password`
    /// so migrations can't leave a row in an undecodable state.
    var authMethod: AuthMethod {
        get { AuthMethod(rawValue: authMethodRaw) ?? .password }
        set { authMethodRaw = newValue.rawValue }
    }

    enum OSFamily: String {
        case linux
        case windows
        case macos
    }

    var os: OSFamily {
        get { OSFamily(rawValue: osFamily) ?? .linux }
        set { osFamily = newValue.rawValue }
    }
}
