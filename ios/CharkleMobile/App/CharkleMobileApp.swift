import CharkleCore
import SwiftUI

@main
struct CharkleMobileApp: App {
    @State private var store: MobileAppStore
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let rootDir = MobileLibraryContainer.rootDirectory()
        let engine: any CharkleEngineProtocol
        if let live = try? LiveCharkleEngine.make(appSupportDirectory: rootDir, startAutoSync: true) {
            engine = live
        } else {
            let fallback = FileManager.default.temporaryDirectory
                .appending(path: "CharkleFallback", directoryHint: .isDirectory)
            let db = try! LibraryDatabase(path: ":memory:")
            let media = try! MediaPipeline(directory: fallback)
            engine = LiveCharkleEngine(database: db, media: media)
        }
        _store = State(initialValue: MobileAppStore(engine: engine))
    }

    var body: some Scene {
        WindowGroup {
            RootShellView(store: store)
                .tint(Color("AccentColor"))
                .task {
                    await store.bootstrap()
                }
                .onOpenURL { url in
                    Task { await store.handleIncomingURL(url) }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        Task { await store.handleBecameActive() }
                    }
                }
        }
    }
}
