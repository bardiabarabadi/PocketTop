import SwiftUI

/// Step 3: present the SSH host-key fingerprint captured during the initial
/// handshake and ask the user to trust it.
///
/// The actual SSH connect is done by the parent (`AddServerFlow`) before
/// navigating here — by the time this view appears, `state.pendingHostFingerprint`
/// is already populated. Our only job is to render it legibly and gate
/// progression on an explicit "Trust" tap (ref doc §4: pinning is mandatory,
/// there's no silent-accept path).
///
/// Fingerprint format: `SHA256:<base64>` straight from
/// `HostKeyCaptureValidator`. We display it in chunks of 4 characters so the
/// user can actually compare it to a `ssh-keygen -lf /etc/ssh/ssh_host_*_key.pub`
/// output on the server.
struct HostFingerprintView: View {
    @Bindable var state: EphemeralSetupState

    /// Called when the user taps "Trust this host". Parent writes the
    /// fingerprint into `Server.sshHostKeyFingerprint` and advances to the
    /// next appropriate step (sudo or install).
    let onTrust: () -> Void

    /// Called when the user taps Cancel. Parent pops back to the connection
    /// form so the user can adjust host/port/auth and try again.
    let onCancel: () -> Void

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Verify host identity", systemImage: "lock.shield")
                        .font(.headline)
                    Text("PocketTop captured this fingerprint from the server on first connect. Verify it out-of-band (for example, run `ssh-keygen -lf` on the server) before trusting it — mismatches can indicate a man-in-the-middle attack.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("Fingerprint (SHA-256)") {
                Text(formatted)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(nil)
            }

            Section {
                Button {
                    onTrust()
                } label: {
                    Label("Trust this host", systemImage: "checkmark.seal")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .navigationTitle("Host Key")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Back", action: onCancel)
            }
        }
    }

    /// Group the fingerprint body into 4-char chunks separated by spaces so
    /// it's legible on an iPhone without wrapping weirdly. Keeps the
    /// `SHA256:` prefix on its own line as a header.
    private var formatted: String {
        let raw = state.pendingHostFingerprint
        guard let colonIdx = raw.firstIndex(of: ":") else {
            return raw
        }
        let prefix = String(raw[..<colonIdx])
        let body = String(raw[raw.index(after: colonIdx)...])
        let chunks = stride(from: 0, to: body.count, by: 4).map { i -> String in
            let start = body.index(body.startIndex, offsetBy: i)
            let end = body.index(start, offsetBy: min(4, body.count - i))
            return String(body[start..<end])
        }
        return "\(prefix):\n\(chunks.joined(separator: " "))"
    }
}
