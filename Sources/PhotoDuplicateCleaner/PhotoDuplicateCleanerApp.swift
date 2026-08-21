import SwiftUI

@main
struct PhotoDuplicateCleanerApp: App {
    var body: some Scene {
        WindowGroup {
            CleanerRootView()
        }
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
