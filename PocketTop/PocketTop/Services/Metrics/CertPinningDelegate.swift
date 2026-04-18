import Foundation
import Security
import CryptoKit

/// URLSession delegate that pins the server's leaf certificate by SHA-256
/// fingerprint. Ported verbatim from `docs/SSH_App_Architecture_Reference.md` §7.
///
/// Three non-negotiable requirements (all iOS-version-sensitive, learned the
/// hard way in the reference implementation):
///
/// 1. **`SecTrustEvaluateWithError` must be called** before completing with
///    `.useCredential`. On iOS 15+ URLSession silently cancels the request
///    (`NSURLErrorCancelled` / -999) if a custom delegate returns `.useCredential`
///    without having first evaluated the trust object. The call's *result* is
///    ignored for self-signed certs (it will fail), but it must happen.
///
/// 2. **Use `SecPolicyCreateBasicX509()`, not the default SSL policy.** The
///    self-signed cert the installer generates has only an **IP** SAN (no
///    hostname SAN and no DNS name) because iOS 14+ requires SAN and the
///    user connects by IP. The default SSL policy walks the SAN looking for
///    the URL's hostname, which would reject the cert. Basic X.509 policy
///    skips that check — identity verification is done entirely via the pinned
///    fingerprint.
///
/// 3. **Anchor the leaf cert:** `SecTrustSetAnchorCertificates` +
///    `SecTrustSetAnchorCertificatesOnly(true)`. Without this the trust
///    evaluation considers the system anchors, which rejects our self-signed
///    cert outright.
///
/// ### Threading
///
/// `URLSessionDelegate` methods fire on arbitrary queues managed by URLSession.
/// The delegate therefore must not capture actor-isolated state. We mark it
/// `nonisolated` and keep it stateless apart from the immutable
/// `expectedFingerprint`.
nonisolated final class CertPinningDelegate: NSObject, URLSessionDelegate {
    /// SHA-256 of the DER-encoded leaf cert, hex-encoded (lowercase or uppercase
    /// — comparison is case-insensitive). 64 hex chars.
    private let expectedFingerprint: String

    init(expectedFingerprint: String) {
        self.expectedFingerprint = expectedFingerprint
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Only handle server trust challenges; everything else falls through
        // to the default handling (which for our sessions means no auth, so
        // the request fails — correct behaviour for unexpected challenges).
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Grab the leaf certificate. `SecTrustCopyCertificateChain` (iOS 15+)
        // replaces the deprecated `SecTrustGetCertificateAtIndex`; the leaf is
        // always index 0 of the returned chain.
        guard let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
              let leafCert = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // 1) Policy: BasicX509, not SSL (see requirement #2 above).
        let policy = SecPolicyCreateBasicX509()
        SecTrustSetPolicies(serverTrust, policy)

        // 2) Anchor: leaf cert only (requirement #3).
        SecTrustSetAnchorCertificates(serverTrust, [leafCert] as CFArray)
        SecTrustSetAnchorCertificatesOnly(serverTrust, true)

        // 3) Evaluate — must happen before `.useCredential` (requirement #1).
        //    For a self-signed cert this still returns false (the cert isn't
        //    trusted by the system's baseline), but the *act of calling* is
        //    what URLSession requires. Our identity check is the fingerprint
        //    comparison below, not the evaluation result.
        _ = SecTrustEvaluateWithError(serverTrust, nil)

        // 4) Fingerprint comparison — authoritative identity check.
        let certData = SecCertificateCopyData(leafCert) as Data
        let digest = SHA256.hash(data: certData)
        let actualFingerprint = digest.map { String(format: "%02x", $0) }.joined()

        // Case-insensitive compare: stored fingerprints may be lowercase (what
        // the install script writes) while manual entry / display paths may be
        // uppercase.
        if actualFingerprint.lowercased() == expectedFingerprint.lowercased() {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
