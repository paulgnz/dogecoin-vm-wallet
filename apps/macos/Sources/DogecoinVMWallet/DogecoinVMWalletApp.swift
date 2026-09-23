import SwiftUI
import Sparkle

@main
struct DogecoinVMWalletApp: App {
    @State private var model = AppModel()
    /// Checks the signed update feed daily, and on request.
    private let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    var body: some Scene {
        WindowGroup("DogecoinVM Wallet") {
            RootView()
                .environment(model)
                .environment(\.checkForUpdates, CheckForUpdates(updater: updater.updater))
                .tint(Theme.ink)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.updater.checkForUpdates() }
            }
        }
    }
}

/// Lets views offer "Check for updates".
struct CheckForUpdates: @unchecked Sendable {
    let updater: SPUUpdater?
    @MainActor func callAsFunction() { updater?.checkForUpdates() }
}

extension EnvironmentValues {
    @Entry var checkForUpdates = CheckForUpdates(updater: nil)
}
