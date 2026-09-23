import SwiftUI

struct MoveInView: View {
    @Environment(AppModel.self) private var model
    @State private var amount = ""
    @State private var moving = false
    @State private var result: ActionResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Move DOGE from your Dogecoin balance to DogecoinVM. It's credited one for one after \(model.info?.depositConfirmations ?? 20) Dogecoin confirmations, about as many minutes, less a \(formatDoge(model.info?.vmFee ?? "0.01")) DOGE fee.")
                .fixedSize(horizontal: false, vertical: true)
            if let sync = model.status?.dogecoinSync, sync.syncing {
                Label("The bridge's Dogecoin node is catching up (\(Int(sync.progress * 100))%). Deposits are credited once it reaches the present.",
                      systemImage: "hourglass")
                    .foregroundStyle(Theme.coinInk)
            }
            BalanceTile(network: .dogecoin, amount: model.doge?.confirmed, note: model.dogeNote ?? "Available to move")
                .frame(maxWidth: 360)
            Field(label: "Amount (DOGE)", text: $amount).frame(maxWidth: 220)
            if let info = model.info {
                Text(limits(info)).font(.callout).foregroundStyle(Theme.inkSoft)
            }
            HStack {
                Button(moving ? "Preparing…" : "Review move") { Task { await move() } }
                    .buttonStyle(.borderedProminent).tint(Theme.vm)
                    .disabled(moving || amount.isEmpty || model.doge == nil)
                Text("Your deposit address is checked against the signers' keys first.")
                    .font(.caption).foregroundStyle(Theme.inkSoft)
            }
            ResultLine(result: result)
            DepositList()
        }
    }

    private func limits(_ info: BridgeInfo) -> String {
        var s = "The minimum is \(formatDoge(info.minDeposit)) DOGE."
        if info.maxDeposit != "0.00000000" { s += " During the beta the maximum is \(formatDoge(info.maxDeposit)) DOGE per deposit." }
        return s
    }

    private func move() async {
        moving = true
        defer { moving = false }
        result = nil
        do {
            try await model.prepareMoveIn(amount: amount)
            amount = ""
        } catch {
            result = .failure(error)
        }
    }
}

struct DepositList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your deposits").font(.title3.bold())
            if model.deposits.isEmpty {
                Text("None yet. They show up here once Dogecoin sees them.").foregroundStyle(Theme.inkSoft)
            }
            ForEach(model.deposits) { d in
                HStack {
                    TxLink(txid: d.txid, network: .dogecoin, server: model.server)
                    Text("\(formatDoge(d.amount)) DOGE").monospacedDigit()
                    Spacer()
                    Text(status(d)).foregroundStyle(d.status == "credited" ? Theme.vmInk : Theme.inkSoft)
                }
                Divider()
            }
        }
    }

    private func status(_ d: DepositEntry) -> String {
        switch d.status {
        case "credited": "Credited \(formatDoge(d.credited ?? d.amount)) DOGE"
        case "refunded": "Refunded"
        case "held": "Held for a refund: \(d.reason ?? "")"
        case "waiting_for_capacity": "Waiting for room under the beta limit"
        case "crediting": "Crediting now"
        default: "\(min(d.confirmations, d.required)) of \(d.required) confirmations"
        }
    }
}

struct WithdrawView: View {
    @Environment(AppModel.self) private var model
    @State private var to = ""
    @State private var amount = ""
    @State private var sending = false
    @State private var result: ActionResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Withdraw DOGE from DogecoinVM to any Dogecoin address. The bridge pays it once the withdrawal is final on DogecoinVM, usually within a minute, less a \(formatDoge(model.info?.dogeFee ?? "0.1")) DOGE Dogecoin fee. The minimum is \(formatDoge(model.info?.minPegOut ?? "2")) DOGE.")
                .fixedSize(horizontal: false, vertical: true)
            BalanceTile(network: .dogecoinvm, amount: model.vm?.confirmed, note: "Available to withdraw").frame(maxWidth: 360)
            VStack(alignment: .leading, spacing: 4) {
                Field(label: "To Dogecoin address", text: $to)
                Button("Use my Dogecoin address") { to = model.address ?? "" }.buttonStyle(.link)
            }
            Field(label: "Amount (DOGE)", text: $amount).frame(maxWidth: 220)
            Button(sending ? "Preparing…" : "Review withdrawal") { Task { await withdraw() } }
                .buttonStyle(.borderedProminent).tint(Theme.coin)
                .disabled(sending || to.isEmpty || amount.isEmpty)
            ResultLine(result: result)
            WithdrawalList()
        }
    }

    private func withdraw() async {
        sending = true
        defer { sending = false }
        result = nil
        do {
            try await model.prepareWithdraw(to: to.trimmingCharacters(in: .whitespaces), amount: amount)
            amount = ""
        } catch {
            result = .failure(error)
        }
    }
}

struct WithdrawalList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your withdrawals").font(.title3.bold())
            if model.withdrawals.isEmpty {
                Text("None yet.").foregroundStyle(Theme.inkSoft)
            }
            ForEach(model.withdrawals) { w in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(formatDoge(Core.dogeText(UInt64(w.amount) ?? 0))) DOGE to \(w.to.prefix(8))…")
                        HStack(spacing: 6) {
                            TxLink(txid: w.txid, network: .dogecoinvm, server: model.server)
                            if let paid = w.paymentTxid {
                                Image(systemName: "arrow.right").font(.caption).foregroundStyle(Theme.inkSoft)
                                TxLink(txid: paid, network: .dogecoin, server: model.server)
                            }
                        }
                    }
                    Spacer()
                    Text(status(w)).foregroundStyle(w.status == "paid" ? Theme.vmInk : Theme.inkSoft)
                }
                Divider()
            }
        }
    }

    private func status(_ w: AppModel.Withdrawal) -> String {
        switch w.status {
        case "paid": "Paid \(formatDoge(w.pays ?? "")) DOGE on Dogecoin"
        case "pending": "Waiting for the bridge"
        default: "Waiting for a DogecoinVM block"
        }
    }
}
