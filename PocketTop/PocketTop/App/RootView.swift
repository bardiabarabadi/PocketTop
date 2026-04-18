import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Server.createdAt, order: .forward) private var servers: [Server]
    @State private var showingAddServer = false

    var body: some View {
        NavigationStack {
            Group {
                if servers.isEmpty {
                    EmptyStateView { showingAddServer = true }
                } else {
                    HomeView(servers: servers, onAddTapped: { showingAddServer = true })
                }
            }
        }
        .sheet(isPresented: $showingAddServer) {
            AddServerFlow()
        }
    }
}

private struct EmptyStateView: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "server.rack")
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
                .foregroundStyle(.secondary)
            Text("No machines yet")
                .font(.title2.weight(.semibold))
            Text("Add a Linux host to watch its CPU, memory, GPU, and kill runaway processes.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("Add Machine", action: onAdd)
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
        }
        .padding()
        .navigationTitle("PocketTop")
    }
}
