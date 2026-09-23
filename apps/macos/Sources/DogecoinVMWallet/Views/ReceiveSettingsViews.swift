import SwiftUI

struct ReceiveView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Anyone can send you DOGE on Dogecoin or on DogecoinVM at this address.")
            HStack(alignment: .top, spacing: 24) {
                QRCodeView(text: model.address ?? "")
                    .frame(width: 200, height: 200)
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.address ?? "").font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                    CopyButton(text: model.address ?? "")
                    Text("From an exchange or another wallet, choose the Dogecoin network. To get DOGE onto DogecoinVM, receive it on Dogecoin and use Move to DogecoinVM.")
                        .font(.callout).foregroundStyle(Theme.inkSoft).frame(maxWidth: 360, alignment: .leading)
                }
            }
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.checkForUpdates) private var checkForUpdates
    @State private var server = ""
    @State private var wif: String?
    @State private var confirmRemove = false
    @State private var result: ActionResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Back up your key").font(.title3.bold())
                Text("This key is your wallet on both networks. Keep a copy in a password manager: if this Mac is lost, the key is the only way back to your DOGE.")
                    .fixedSize(horizontal: false, vertical: true)
                if let wif {
                    HStack {
                        Text(wif).font(Theme.mono).textSelection(.enabled)
                        CopyButton(text: wif)
                    }
                    Button("Hide") { self.wif = nil }
                } else {
                    Button("Show key (Touch ID)") {
                        Task {
                            do { wif = try await model.exportWIF() } catch { result = .failure(error) }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Bridge").font(.title3.bold())
                Text("The bridge this wallet reads balances from and sends transactions through. It never sees your key.")
                    .foregroundStyle(Theme.inkSoft)
                HStack {
                    TextField("Server", text: $server).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                    Button("Save") {
                        guard let url = URL(string: server), url.scheme == "https" else {
                            result = .init(ok: false, message: "Use an https:// address.")
                            return
                        }
                        Task { await model.setServer(url) }
                        result = .success("Connected to \(url.host() ?? server).")
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Remove the wallet").font(.title3.bold())
                Text("Deletes the key from this Mac. Without a backup, its DOGE is gone for good.")
                    .foregroundStyle(Theme.inkSoft)
                Button("Remove wallet from this Mac…", role: .destructive) { confirmRemove = true }
            }

            ResultLine(result: result)

            HStack {
                Text("DogecoinVM Wallet \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                Button("Check for updates") { checkForUpdates() }.buttonStyle(.link)
            }
            .font(.caption).foregroundStyle(Theme.inkSoft)
        }
        .onAppear { server = model.server.absoluteString }
        .confirmationDialog("Remove the wallet from this Mac?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) {
                Task {
                    do { try await model.removeWallet() } catch { result = .failure(error) }
                }
            }
        } message: {
            Text("Make sure you have backed up the key. Touch ID confirms.")
        }
    }
}
