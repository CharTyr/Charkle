import SwiftUI
import CharkleCore
import CharkleCanvas

@main
struct CharkleApp: App {
    var body: some Scene {
        WindowGroup("Charkle") {
            Text("Charkle Bootstrap (\(CharkleCanvasModuleInfo.version))")
                .padding(32)
        }
    }
}
