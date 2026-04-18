import SwiftUI

/// Step 1 of the Add-Server wizard: host / port / username / auth method.
///
/// Stateless WRT persistence — every field writes straight through to the
/// shared `EphemeralSetupState` so later steps see the values synchronously
/// (ref doc §11 — the whole point of the reference-typed state container).
///
/// Validation is limited to "can we physically attempt a connection?":
/// non-empty host, valid 1–65535 port, non-empty username. We don't try to
/// DNS-resolve the host or test reachability here; the next step will
/// surface any real connect error.
struct ConnectionFormView: View {
    /// The shared setup state. Observed via property access on the class —
    /// no `@Bindable` needed for two-way binding to `@Observable` properties
    /// with iOS 17+, but `Bindable` gives us `$state.field` for SwiftUI
    /// controls.
    @Bindable var state: EphemeralSetupState

    /// Tap handler for the Continue button. The wizard root owns the
    /// navigation decisions, so we don't push directly from here.
    let onContinue: () -> Void

    var body: some View {
        Form {
            Section("Machine") {
                TextField("Name (optional)", text: $state.name)
                    .textContentType(.name)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

            Section("Connection") {
                TextField("Host or IP", text: $state.host)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .textContentType(.URL)

                TextField("Port", text: $state.portText)
                    .keyboardType(.numberPad)

                TextField("SSH Username", text: $state.sshUsername)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .textContentType(.username)
            }

            Section {
                Picker("Authentication", selection: $state.authMethod) {
                    Text("Password").tag(Server.AuthMethod.password)
                    Text("SSH Key").tag(Server.AuthMethod.key)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Authentication")
            } footer: {
                switch state.authMethod {
                case .password:
                    Text("You'll enter the SSH password on the next step. Non-root users: the same password is reused for sudo during install.")
                case .key:
                    Text("PocketTop will generate a key on the next step for you to copy to the server. You can also import your own private key.")
                }
            }

            // Inline validation footers so we don't have to bury "why is
            // Continue disabled?" in an alert.
            if !portValid {
                Section {
                    Text("Port must be between 1 and 65535.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Add Machine")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Continue", action: onContinue)
                    .disabled(!state.connectionFormIsValid)
            }
        }
        // When the user toggles the picker we proactively wipe the fields
        // from the other branch so a half-filled alternate path can't leak
        // into a later step.
        .onChange(of: state.authMethod) { _, new in
            switch new {
            case .password:
                state.resetKeyFields()
            case .key:
                state.resetPasswordFields()
            }
        }
    }

    /// True if the port text parses to a valid range or the user is still
    /// typing (empty). We surface an explicit error only for non-empty
    /// invalid input so the field isn't "red" while the user types.
    private var portValid: Bool {
        let t = state.portText.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return true }
        return state.port != nil
    }
}
