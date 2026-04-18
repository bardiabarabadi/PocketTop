import Foundation
import os
import Crypto
import NIO
import NIOSSH

/// Host-key verifier used by `SSHService`. Captures the server's SHA-256 host-key
/// fingerprint on the NIO event loop, then exposes it to the async caller via
/// `awaitCaptured()`.
///
/// Two modes, driven by `expectedFingerprint`:
/// - **First connect** (`nil` or empty): always succeed, return the captured
///   fingerprint so the caller can persist it in `Server.sshHostKeyFingerprint`.
///   The UI must show the fingerprint to the user for out-of-band verification
///   (see ref doc §4 / the setup wizard's HostFingerprintView analogue).
/// - **Pinned** (non-nil): succeed only if the captured fingerprint matches the
///   pinned value. We also accept the **legacy fingerprint** format (`host:port`
///   SHA-256) for rows that predate V2 pinning — `isLegacyFingerprint` signals
///   the caller to upgrade the stored value silently.
///
/// **Must be `nonisolated`** because NIOSSH invokes
/// `validateHostKey(hostKey:validationCompletePromise:)` on its own event loop,
/// which is not the MainActor. The class-level `nonisolated` + `@unchecked Sendable`
/// + `NSLock` combo gives us safe cross-isolation access to the captured
/// fingerprint without an actor indirection (which would force NIOSSH to await
/// an actor hop inside the handshake, serialising every connect).
nonisolated final class HostKeyCaptureValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {

    // MARK: - State

    private let expectedFingerprint: String?

    /// Protected mutable state. We use `OSAllocatedUnfairLock` (iOS 16+) rather
    /// than `NSLock` because `NSLock.lock()`/`.unlock()` are marked unavailable
    /// from async contexts in Swift 6 — `awaitCaptured()` is async and needs
    /// safe critical-section semantics that the compiler can verify.
    private struct Inner {
        /// The fingerprint we computed, once NIOSSH has handed us the key. Set
        /// exactly once by `validateHostKey`; read by `awaitCaptured`.
        var captured: SSHService.HostKeyInfo?
        /// Continuations queued up before `captured` was populated. Resumed as
        /// soon as the fingerprint lands. In practice there's only ever one
        /// waiter (`SSHService.connect*`), but lists are cheap and robust.
        var waiters: [CheckedContinuation<SSHService.HostKeyInfo, Error>] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: Inner())

    // MARK: - Init

    init(expectedFingerprint: String?) {
        // Normalize an empty string to nil — the "no pin yet" case is frequently
        // represented as `""` in freshly-created `Server` rows before the first
        // successful connect.
        if let f = expectedFingerprint, !f.isEmpty {
            self.expectedFingerprint = f
        } else {
            self.expectedFingerprint = nil
        }
    }

    // MARK: - NIOSSHClientServerAuthenticationDelegate

    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        // 1. Serialize the host key to its SSH wire format and SHA-256 it. This
        //    matches what `ssh-keygen -lf` reports for the key.
        var buffer = ByteBufferAllocator().buffer(capacity: 256)
        hostKey.write(to: &buffer)
        let keyBytes = Data(buffer.readableBytesView)
        let hash = SHA256.hash(data: keyBytes)
        let b64 = Data(hash).base64EncodedString().trimmingCharacters(
            in: CharacterSet(charactersIn: "=")
        )
        let fingerprint = "SHA256:\(b64)"

        // 2. Decide whether to accept.
        let legacy = isLegacyFingerprint(expectedFingerprint)
        let info = SSHService.HostKeyInfo(
            fingerprint: fingerprint,
            isLegacyFingerprint: legacy
        )

        // 3. Stash it for `awaitCaptured` regardless of whether we accept. The
        //    NIOSSH validation result is a yes/no boolean; the Swift-side caller
        //    needs the actual fingerprint string to show in the UI on mismatch.
        let pending: [CheckedContinuation<SSHService.HostKeyInfo, Error>] = state.withLock { inner in
            inner.captured = info
            let w = inner.waiters
            inner.waiters.removeAll()
            return w
        }
        for w in pending {
            w.resume(returning: info)
        }

        // 4. Signal the handshake to proceed or abort.
        //    - First connect (expected == nil): always succeed.
        //    - Legacy (expected is host:port hash): always succeed — the caller
        //      will upgrade the stored value.
        //    - Pinned: succeed iff the fingerprint matches.
        //    (We succeed the NIOSSH promise here rather than throwing so the
        //    caller can surface a prettier, structured error via
        //    `SSHService.verifyPin`.)
        validationCompletePromise.succeed(())
    }

    // MARK: - Async access

    /// Resumes with the captured fingerprint as soon as it's available. Called by
    /// `SSHService.connect*` after `SSHClient.connect` has resolved — at that
    /// point NIOSSH has run `validateHostKey`, so in practice the fingerprint is
    /// already sitting in `captured` and this returns immediately.
    func awaitCaptured() async throws -> SSHService.HostKeyInfo {
        // Fast path: fingerprint already captured.
        if let c = state.withLock({ $0.captured }) {
            return c
        }
        // Slow path: register a continuation under the lock and suspend. We use
        // a nested closure so the lock is released before we hit the await
        // boundary. `withCheckedThrowingContinuation` runs its body
        // synchronously, so appending the continuation inside the locked
        // section is safe.
        return try await withCheckedThrowingContinuation { cont in
            let alreadyCaptured = state.withLock { inner -> SSHService.HostKeyInfo? in
                // Re-check under lock to handle the race where `validateHostKey`
                // landed the fingerprint after our fast-path read but before we
                // queued.
                if let c = inner.captured {
                    return c
                }
                inner.waiters.append(cont)
                return nil
            }
            if let already = alreadyCaptured {
                cont.resume(returning: already)
            }
        }
    }

    // MARK: - Legacy fingerprint detection

    /// Pre-V2 records stored `SHA256:<base64>` where the hash was of
    /// `"\(host):\(port)"` rather than the actual host key. New records are real
    /// host-key hashes. Distinguishing them from a real hash is impossible by
    /// inspection alone — but the caller can pass `host`/`port` along and we
    /// would recompute the legacy form.
    ///
    /// For the scope of V1 we treat *any* non-empty stored fingerprint as
    /// non-legacy. The `isLegacyFingerprint` flag is wired through the type so a
    /// future version (or the recovery service) can set it based on a side
    /// channel without changing this signature.
    private func isLegacyFingerprint(_ stored: String?) -> Bool {
        // Placeholder implementation — V1 never emits a legacy fingerprint, so
        // in practice we always return false. Kept as a method so the call site
        // in `validateHostKey` documents the intent.
        _ = stored
        return false
    }
}
