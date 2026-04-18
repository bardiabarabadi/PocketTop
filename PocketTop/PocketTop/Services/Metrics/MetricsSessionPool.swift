import Foundation

/// Process-wide pool of `URLSession` instances keyed by server identity.
///
/// ### Why a pool
///
/// Every `URLSession` with a custom delegate maintains its own TCP/TLS
/// connection pool. In the reference app (CloseAI, §7) a separate `URLSession`
/// per view caused 15–30s cold-start hangs when the first request opened a
/// fresh TLS connection. The fix — lifted wholesale here — is a single process-
/// wide pool keyed by host, so any number of `MetricsService` instances for the
/// same server share one warm session.
///
/// ### Why NSLock, not an actor
///
/// `URLSession` is not `Sendable`, so concurrent dictionary access must be
/// serialized. We use an `NSLock` rather than wrapping in an `actor` because:
///
/// - Actor isolation would make `session(host:port:certFingerprint:)` `async`
///   and serialize every lookup, reintroducing cold-start latency.
/// - The critical section is a single dictionary read/write; the lock is held
///   for microseconds.
/// - The singleton must be accessible from non-async contexts (e.g. initialisers
///   on `@MainActor` services that spawn `URLSession` synchronously).
///
/// Hence `nonisolated final class … @unchecked Sendable` — we vouch for
/// thread-safety manually via the lock.
nonisolated final class MetricsSessionPool: @unchecked Sendable {
    static let shared = MetricsSessionPool()

    private let lock = NSLock()
    private var sessions: [String: URLSession] = [:]

    private init() {}

    /// Returns the warm `URLSession` for `(host, port, certFingerprint)`,
    /// creating one if needed. Safe to call from any thread.
    ///
    /// The key includes the first 16 hex chars of the fingerprint so that if
    /// the server cert rotates (or the user re-points at a different host on
    /// the same IP), a fresh session is minted rather than reusing the old
    /// TCP pool with the wrong delegate.
    func session(host: String, port: Int, certFingerprint: String) -> URLSession {
        let fpPrefix = String(certFingerprint.prefix(16))
        let key = "\(host):\(port):\(fpPrefix)"

        lock.lock()
        defer { lock.unlock() }

        if let existing = sessions[key] {
            return existing
        }

        let config = URLSessionConfiguration.default
        // Plan Phase 6: polls are frequent and the UI deliberately short-
        // circuits stale requests. 5s per-request, 10s per-resource. (Ref doc
        // §7 uses 15/30 for CloseAI streaming — our workload is different.)
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        // No caching: snapshots are fresh by definition, and URL caches
        // interact poorly with certificate pinning.
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        // Prefer HTTP/2 when the server advertises it; self-signed cert is
        // fine over H2.
        config.httpShouldUsePipelining = false

        let delegate = CertPinningDelegate(expectedFingerprint: certFingerprint)
        let session = URLSession(
            configuration: config,
            delegate: delegate,
            delegateQueue: nil
        )

        sessions[key] = session
        return session
    }
}
