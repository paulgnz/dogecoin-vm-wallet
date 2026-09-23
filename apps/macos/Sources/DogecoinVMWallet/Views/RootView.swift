import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.hasWallet {
                MainView()
            } else {
                OnboardingView()
            }
        }
        .frame(minWidth: 860, minHeight: 600)
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var importText = ""
    @State private var result: ActionResult?

    var body: some View {
        VStack(spacing: 22) {
            Image("Doge").resizable().scaledToFit().frame(width: 150)
            VStack(spacing: 6) {
                Text("DogecoinVM Wallet").font(.system(size: 30, weight: .heavy))
                Text("One key for Dogecoin and DogecoinVM, and the bridge between them. Your key is protected by Touch ID and never leaves this Mac.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.inkSoft)
                    .frame(maxWidth: 440)
            }
            Button {
                do { try model.createWallet() } catch { result = .failure(error) }
            } label: {
                Text("Create a new wallet").frame(minWidth: 220).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Theme.ink)

            VStack(alignment: .leading, spacing: 6) {
                Text("Or import a key you already have (WIF or hex)").font(.subheadline.weight(.medium))
                HStack {
                    SecureField("Key", text: $importText).textFieldStyle(.roundedBorder).font(Theme.mono)
                    Button("Import") {
                        do { try model.importWallet(importText); importText = "" } catch { result = .failure(error) }
                    }
                    .disabled(importText.isEmpty)
                }
            }
            .frame(maxWidth: 440)
            ResultLine(result: result).frame(maxWidth: 440)
            if !Vault.isAvailable {
                Text("This Mac has no Secure Enclave, so the wallet can't protect a key here.")
                    .foregroundStyle(Theme.bad)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Main

enum Section: String, CaseIterable, Identifiable {
    case wallet, moveIn, withdraw, receive, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .wallet: "Wallet"
        case .moveIn: "Move to DogecoinVM"
        case .withdraw: "Withdraw to Dogecoin"
        case .receive: "Receive"
        case .settings: "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .wallet: "wallet.bifold"
        case .moveIn: "arrow.down.to.line.circle"
        case .withdraw: "arrow.up.to.line.circle"
        case .receive: "qrcode"
        case .settings: "gearshape"
        }
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var section: Section? = .wallet

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { s in
                Label(s.title, systemImage: s.symbol).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .safeAreaInset(edge: .bottom) { ChainStatus().padding(12) }
        } detail: {
            VStack(spacing: 0) {
                if let pause = model.status?.paused {
                    Text("The bridge is paused: \(pause.reason) Transfers already sent are processed when it resumes.")
                        .font(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(10)
                        .background(Theme.bad)
                        .foregroundStyle(.white)
                }
                ScrollView {
                    Group {
                        switch section ?? .wallet {
                        case .wallet: WalletView()
                        case .moveIn: MoveInView()
                        case .withdraw: WithdrawView()
                        case .receive: ReceiveView()
                        case .settings: SettingsView()
                        }
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .navigationTitle((section ?? .wallet).title)
            .toolbar {
                ToolbarItem {
                    Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                }
            }
        }
    }
}

/// Both chains' heights, and the Dogecoin node's sync while it catches up.
struct ChainStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = model.connectionError {
                Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(Theme.bad)
            } else if let s = model.status {
                if let sync = s.dogecoinSync, sync.syncing {
                    Text("Dogecoin node syncing, \(Int(sync.progress * 100))%").foregroundStyle(Theme.coinInk)
                } else {
                    Text("Dogecoin block \(s.dogecoinHeight.formatted())").foregroundStyle(Theme.coinInk)
                }
                Text("DogecoinVM block \(s.dogecoinvmHeight.formatted())").foregroundStyle(Theme.vmInk)
            } else {
                Text("Connecting…").foregroundStyle(Theme.inkSoft)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
