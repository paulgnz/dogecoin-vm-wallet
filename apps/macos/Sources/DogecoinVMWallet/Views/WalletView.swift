import SwiftUI

struct WalletView: View {
    @Environment(AppModel.self) private var model
    @State private var network: Network = .dogecoinvm
    @State private var to = ""
    @State private var amount = ""
    @State private var sending = false
    @State private var result: ActionResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your address").font(.subheadline.weight(.medium)).foregroundStyle(Theme.inkSoft)
                HStack {
                    Text(model.address ?? "").font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                    CopyButton(text: model.address ?? "")
                }
                Text("The same on Dogecoin and DogecoinVM: one key, two networks.")
                    .font(.callout).foregroundStyle(Theme.inkSoft)
            }

            HStack(spacing: 12) {
                BalanceTile(network: .dogecoin, amount: model.doge?.confirmed, note: model.dogeNote ?? pendingNote(model.doge))
                BalanceTile(network: .dogecoinvm, amount: model.vm?.confirmed, note: pendingNote(model.vm))
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Send DOGE").font(.title2.bold())
                Picker("Send on", selection: $network) {
                    Text("DogecoinVM · final in seconds").tag(Network.dogecoinvm)
                    Text("Dogecoin · a block about every minute").tag(Network.dogecoin)
                }
                .pickerStyle(.radioGroup)
                Field(label: "To address", text: $to)
                Field(label: "Amount (DOGE)", text: $amount).frame(maxWidth: 220)
                HStack {
                    Button(sending ? "Preparing…" : "Review") { Task { await send() } }
                        .buttonStyle(.borderedProminent).tint(Theme.ink)
                        .disabled(sending || to.isEmpty || amount.isEmpty)
                    Text("You review every payment, then Touch ID signs it.").font(.caption).foregroundStyle(Theme.inkSoft)
                }
                ResultLine(result: result)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Recent activity").font(.title2.bold())
                Activity(network: .dogecoinvm, entries: model.vm?.history,
                         empty: "Nothing yet. Move DOGE over from Dogecoin.")
                Activity(network: .dogecoin, entries: model.doge?.history,
                         empty: model.dogeNote ?? "Nothing yet. Send DOGE to your address from any Dogecoin wallet.")
            }
        }
    }

    private func pendingNote(_ view: AddressView?) -> String? {
        guard let p = view?.pending, p != "0.00000000", p != "0" else { return nil }
        return p.hasPrefix("-") ? "\(formatDoge(p)) DOGE leaving, waiting for a block" : "+\(formatDoge(p)) DOGE arriving, waiting for a block"
    }

    private func send() async {
        sending = true
        defer { sending = false }
        result = nil
        do {
            try await model.prepareSend(to: to.trimmingCharacters(in: .whitespaces), amount: amount, on: network)
            to = ""
            amount = ""
        } catch {
            result = .failure(error)
        }
    }
}

struct Activity: View {
    @Environment(AppModel.self) private var model
    let network: Network
    let entries: [HistoryEntry]?
    let empty: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("On \(network.name)").font(.headline).foregroundStyle(Theme.ink(for: network))
            if let entries, !entries.isEmpty {
                ForEach(entries.prefix(15)) { e in
                    HStack {
                        TxLink(txid: e.txid, network: network, server: model.server)
                        Spacer()
                        Text((e.net.hasPrefix("-") ? "" : "+") + formatDoge(e.net) + " DOGE")
                            .font(.system(.body, design: .monospaced)).monospacedDigit()
                        if e.confirmations == 0 {
                            Text("pending").font(.caption).foregroundStyle(Theme.inkSoft)
                        }
                    }
                    Divider()
                }
            } else {
                Text(empty).foregroundStyle(Theme.inkSoft)
            }
        }
    }
}
