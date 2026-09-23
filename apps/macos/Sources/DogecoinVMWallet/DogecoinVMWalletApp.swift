import SwiftUI

@main
struct DogecoinVMWalletApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("DogecoinVM Wallet") {
            RootView()
                .environment(model)
                .tint(Theme.ink)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
