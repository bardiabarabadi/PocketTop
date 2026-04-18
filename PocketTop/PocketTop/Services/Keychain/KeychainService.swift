import Foundation
import Security
import LocalAuthentication

/// Secret categories persisted in the iOS Keychain.
///
/// Each raw value is appended to `KeychainService.service` so the actual Keychain
/// service string becomes `"com.bardiabarabadi.PocketTop.<key>"`. The `account`
/// argument differentiates secrets of the same category across servers (typically
/// the server UUID, but see `savedConnectionPassword` which uses `host:port:user`).
enum KeychainKey: String {
    /// SSH password. Access: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, no
    /// biometry (prompting for Face ID on every SSH reconnect is unacceptable UX).
    case sshPassword
    /// SSH private key in PEM/OpenSSH format. No biometry (intentional — see ref
    /// doc §8). Either stored per-server (`account == server.id.uuidString`) or
    /// app-wide (`account == sshAppKeyAccount`).
    case sshPrivateKey
    /// Sudo password. Protected with biometry — only prompted for admin tasks
    /// (install, upgrade, credential recovery), not on every connect.
    case sudoPassword
    /// Backend API key (Bearer token). Standard accessibility.
    case apiKey
    /// Password for a saved SSH connection entry (keyed by `host:port:username`)
    /// so the add-server form can pre-fill.
    case savedConnectionPassword
}

/// Distinguishes "user cancelled Face ID" from "secret not found" from "some other
/// Keychain error" for biometry-gated reads. Non-biometry reads just return `String?`.
enum KeychainError: Error {
    /// No item at this service/account.
    case notFound
    /// User cancelled the biometry prompt, or policy evaluation was otherwise
    /// aborted before succeeding.
    case userCancelled
    /// Biometry failed (too many attempts, hardware disabled, etc.).
    case authenticationFailed
    /// Any other OSStatus failure from `SecItem*`.
    case unknown(OSStatus)
}

/// Thin wrapper around `SecItem*` APIs. Stateless — all methods are `static`.
///
/// Design notes (per ref doc §8):
/// - Service is always `"com.bardiabarabadi.PocketTop.<key.rawValue>"`.
/// - Biometry is opt-in per save (`requiresBiometry:`), so callers don't pay the
///   Face ID tax when they don't need to.
/// - Biometry-gated loads return `Result` so the UI can distinguish user cancel
///   (offer a retry) from not-found (prompt for the password) from auth failure
///   (show an error).
nonisolated enum KeychainService {
    /// Bundle/app identifier used as the Keychain service prefix. **Not** the SSH
    /// username and **not** the server identity — this is the iOS app's own
    /// namespace in the Keychain.
    static let service = "com.bardiabarabadi.PocketTop"

    /// Reserved account name for the app-wide shared SSH keypair. All
    /// key-authenticated servers share one private key stored under this account
    /// (ref doc §4 / §8). `Server.keychainKeyAccount` records whether a given
    /// server points at this shared account (value: `sshAppKeyAccount`) or legacy
    /// per-server storage (`nil`, fall back to `server.id.uuidString`).
    static let sshAppKeyAccount = "app-shared-ssh-key"

    // MARK: - Save

    /// Standard save with no biometry. See the `requiresBiometry:` overload for
    /// biometry-protected saves.
    static func save(key: KeychainKey, value: String, account: String) throws {
        try save(key: key, value: value, account: account, requiresBiometry: false)
    }

    /// Save a secret, optionally gating reads with biometry.
    ///
    /// - Parameters:
    ///   - key: Secret category; maps to the Keychain service string.
    ///   - value: UTF-8-encodable secret.
    ///   - account: Per-secret discriminator (server UUID, `host:port:user`, or
    ///     `sshAppKeyAccount`).
    ///   - requiresBiometry: If `true`, the item is saved with
    ///     `biometryCurrentSet` access control — Face/Touch ID is required on load
    ///     and the item is invalidated if the biometric set changes (added/removed
    ///     fingerprint/face). If `false`, accessibility is
    ///     `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (no biometry prompt).
    ///
    /// Existing items at the same service/account are overwritten — we `SecItemDelete`
    /// first then `SecItemAdd` so the access control flags update cleanly when the
    /// same secret is re-saved with different settings.
    static func save(
        key: KeychainKey,
        value: String,
        account: String,
        requiresBiometry: Bool
    ) throws {
        let data = Data(value.utf8)
        let serviceName = serviceName(for: key)

        // Always delete first — prevents "can't change access control on existing
        // item" errors and keeps the access-control flags in sync with the caller's
        // current intent.
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]

        if requiresBiometry {
            // `.biometryCurrentSet` invalidates the item if the user's biometric
            // enrolment changes (new face / new fingerprint). This is stricter than
            // `.biometryAny` but matches the security intent: if a new face got
            // enrolled we want the sudo password re-entered.
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                [.biometryCurrentSet],
                &error
            ) else {
                if let err = error?.takeRetainedValue() {
                    throw KeychainError.unknown(OSStatus(CFErrorGetCode(err)))
                }
                throw KeychainError.unknown(errSecParam)
            }
            addQuery[kSecAttrAccessControl as String] = access
        } else {
            // AfterFirstUnlockThisDeviceOnly: the item is readable after the first
            // unlock following a reboot, not synced to other devices, not backed up
            // to iCloud, and never prompts biometry.
            addQuery[kSecAttrAccessible as String] =
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unknown(status)
        }
    }

    // MARK: - Load

    /// Load without a biometry prompt. Returns `nil` if not found or if the item
    /// exists but is biometry-gated (use `loadWithBiometry` in that case).
    ///
    /// Uses `LAContext.interactionNotAllowed = true` to suppress any biometry UI
    /// — reads of biometry-gated items fail fast with `errSecInteractionNotAllowed`
    /// / `errSecAuthFailed` rather than popping Face ID from a view that didn't
    /// opt in. (Replaces the iOS-14-deprecated `kSecUseAuthenticationUIFail`.)
    static func load(key: KeychainKey, account: String) -> String? {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName(for: key),
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Load a biometry-gated secret. Shows the Face/Touch ID prompt with `reason`
    /// as the subtitle.
    ///
    /// Returns a `Result` so callers can distinguish:
    /// - `.success(value)` — user authenticated and we got the secret.
    /// - `.failure(.notFound)` — item doesn't exist (never saved, or invalidated by
    ///   biometry change).
    /// - `.failure(.userCancelled)` — user tapped cancel / dismissed the sheet.
    /// - `.failure(.authenticationFailed)` — biometry failed (too many attempts,
    ///   lockout, etc.). UI should offer a password fallback.
    /// - `.failure(.unknown(status))` — some other `SecItem*` error.
    static func loadWithBiometry(
        key: KeychainKey,
        account: String,
        reason: String
    ) -> Result<String, KeychainError> {
        let context = LAContext()
        context.localizedReason = reason
        // Let the system show its own prompt so it's consistent with other iOS
        // apps; don't override `localizedFallbackTitle` to empty string, as that
        // hides the password-fallback button users expect.

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName(for: key),
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                return .failure(.unknown(status))
            }
            return .success(value)
        case errSecItemNotFound:
            return .failure(.notFound)
        case errSecUserCanceled:
            // User dismissed the biometry sheet.
            return .failure(.userCancelled)
        case errSecAuthFailed:
            // Biometry attempts exhausted or fallback failed.
            return .failure(.authenticationFailed)
        default:
            return .failure(.unknown(status))
        }
    }

    // MARK: - Delete

    static func delete(key: KeychainKey, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName(for: key),
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        // `errSecItemNotFound` is benign — delete of a nonexistent secret is a
        // no-op from the caller's POV.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unknown(status)
        }
    }

    // MARK: - Internals

    private static func serviceName(for key: KeychainKey) -> String {
        "\(service).\(key.rawValue)"
    }
}
