import Foundation

/// Notifications posted by the Add-Server wizard.
///
/// `serverSetupComplete` is posted from `DoneView` when the user taps "Go to
/// Home". `object` is the newly-persisted `Server`. `RootView` (or any other
/// listener) can observe this and, e.g., navigate to the new server's detail
/// screen.
///
/// Kept in its own file because `AddServerFlow.swift` is the root sheet view —
/// putting the `Notification.Name` extension there would force any listener
/// outside the wizard to import the wizard view module just to see the name.
extension Notification.Name {
    /// Posted when a server has been successfully added and installed. `object`
    /// is the `Server` SwiftData model (main-actor isolated; read it on the
    /// main actor).
    static let serverSetupComplete = Notification.Name("pocketTop.serverSetupComplete")
}
