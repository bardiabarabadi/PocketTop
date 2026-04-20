import SwiftUI
import SwiftData

/// Post-setup machine list. Each row is a self-polling glance tile (5s
/// cadence) that navigates to a `DetailView` when tapped. Planned in
/// Phase 8 of the V1 implementation plan.
///
/// ### Why the rows own their own polling
///
/// Each `ServerRow` spawns its own `.task { }` in `onAppear` and tears it
/// down on disappear. That keeps the polling lifetime scoped to row
/// visibility — `List` recycles cells off-screen, so we get free
/// back-pressure without a central coordinator. The alternative (one
/// timer-driven `@Observable` store at the Home level) means every server
/// continues polling even when scrolled out of view, which is wasteful at
/// 5s × N cadence and worse when the user has a dozen machines.
///
/// ### Initializer contract
///
/// `RootView` constructs us as `HomeView(servers: servers, onAddTapped:
/// { ... })`. Keep that signature stable — `RootView` is pre-written and
/// not scoped to this phase.
struct HomeView: View {
    let servers: [Server]
    let onAddTapped: () -> Void

    @Environment(\.modelContext) private var modelContext

    @State private var serverToRename: Server?
    @State private var renameInput: String = ""
    @State private var serverToDelete: Server?
    @State private var showingHelp = false

    init(servers: [Server], onAddTapped: @escaping () -> Void) {
        self.servers = servers
        self.onAddTapped = onAddTapped
    }

    var body: some View {
        List {
            ForEach(servers) { server in
                NavigationLink(value: ServerNavigationValue(serverID: server.id)) {
                    ServerRow(server: server)
                }
                .id(server.id)
                .contextMenu {
                    Button {
                        beginRename(server)
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        serverToDelete = server
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        serverToDelete = server
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        beginRename(server)
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    .tint(.blue)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Machines")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showingHelp = true
                } label: {
                    Label("Help", systemImage: "questionmark.circle")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: onAddTapped) {
                    Label("Add", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingHelp) {
            HelpView()
        }
        .alert(
            "Rename machine",
            isPresented: Binding(
                get: { serverToRename != nil },
                set: { if !$0 { serverToRename = nil } }
            ),
            presenting: serverToRename
        ) { server in
            TextField("Name", text: $renameInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Save") {
                ServerActions.rename(server, to: renameInput, in: modelContext)
            }
            Button("Cancel", role: .cancel) { }
        } message: { server in
            Text("New name for \(server.host)")
        }
        .alert(
            "Delete machine?",
            isPresented: Binding(
                get: { serverToDelete != nil },
                set: { if !$0 { serverToDelete = nil } }
            ),
            presenting: serverToDelete
        ) { server in
            Button("Delete", role: .destructive) {
                ServerActions.delete(server, from: modelContext)
            }
            Button("Cancel", role: .cancel) { }
        } message: { server in
            Text("Removes \"\(server.name)\" from this app. The agent on the host stays installed — uninstall it on the server if you no longer need it.")
        }
        .navigationDestination(for: ServerNavigationValue.self) { nav in
            if let server = servers.first(where: { $0.id == nav.serverID }) {
                DetailView(server: server)
            } else {
                // Server went away mid-navigation (deleted under us). Pop is
                // the right UX but SwiftUI's NavigationStack doesn't give us a
                // clean hook from here; just show a placeholder.
                ContentUnavailableView(
                    "Machine removed",
                    systemImage: "exclamationmark.triangle",
                    description: Text("This machine is no longer in your list.")
                )
            }
        }
    }

    private func beginRename(_ server: Server) {
        renameInput = server.name
        serverToRename = server
    }
}

/// Hashable wrapper so `NavigationLink(value:)` can route to a specific
/// `Server` without making `Server` itself `Hashable` (a SwiftData `@Model`
/// is equatable by persistent identifier but stuffing the model directly
/// into a `NavigationPath` leaks `@MainActor` across the hashing protocol).
struct ServerNavigationValue: Hashable {
    let serverID: UUID
}
