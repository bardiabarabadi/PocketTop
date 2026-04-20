import Foundation
import SwiftData

/// Shared mutations for `Server` rows. Lives here (not in a view) so the
/// Home list and the Detail screen can delete/rename via the same path and
/// keep Keychain cleanup identical.
@MainActor
enum ServerActions {
    /// Delete the server from SwiftData and clear its per-server Keychain
    /// items. The shared app-wide SSH key (`sshAppKeyAccount`) is left
    /// intact — other servers may still point at it.
    static func delete(_ server: Server, from context: ModelContext) {
        let account = server.id.uuidString
        try? KeychainService.delete(key: .apiKey, account: account)
        try? KeychainService.delete(key: .sshPassword, account: account)
        try? KeychainService.delete(key: .sudoPassword, account: account)
        // Only delete per-server SSH keys. The shared app-wide keypair is
        // reused across servers and must outlive any single deletion.
        if server.keychainKeyAccount != KeychainService.sshAppKeyAccount {
            try? KeychainService.delete(key: .sshPrivateKey, account: account)
        }
        context.delete(server)
        try? context.save()
    }

    /// Rename the server. No-op on empty/whitespace input.
    static func rename(_ server: Server, to newName: String, in context: ModelContext) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != server.name else { return }
        server.name = trimmed
        server.updatedAt = .now
        try? context.save()
    }
}
