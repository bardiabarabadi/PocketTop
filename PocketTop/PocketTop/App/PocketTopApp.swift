import SwiftUI
import SwiftData

@main
struct PocketTopApp: App {
    let modelContainer: ModelContainer

    init() {
        self.modelContainer = Self.makeModelContainer()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(modelContainer)
    }

    private static func makeModelContainer() -> ModelContainer {
        let schema = Schema([Server.self])
        let config = ModelConfiguration("PocketTop", schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            resetStoreFiles()
            do {
                return try ModelContainer(for: schema, configurations: [config])
            } catch {
                fatalError("Could not create ModelContainer after reset: \(error)")
            }
        }
    }

    private static func resetStoreFiles() {
        let fm = FileManager.default
        guard let appSupport = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else { return }
        for ext in ["store", "store-wal", "store-shm"] {
            let url = appSupport.appendingPathComponent("default.\(ext)")
            try? fm.removeItem(at: url)
        }
    }
}
