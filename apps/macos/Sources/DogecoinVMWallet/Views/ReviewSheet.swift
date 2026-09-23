import SwiftUI

/// Shows exactly what a payment will do, as the core decoded it, before Touch
/// ID signs it. After signing, the wallet checks the signed transaction says
/// the same thing before sending it.
struct ReviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let payment: PendingPayment
    @State private var signing = false
    @State private var sentTxid: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                if payment.network == .dogecoin {
                    Image("DogecoinCoin").resizable().frame(width: 30, height: 30)
                } else {
                    Image(systemName: "bolt.circle.fill").font(.system(size: 28)).foregroundStyle(Theme.vm)
                }
                VStack(alignment: .leading) {
                    Text(payment.title).font(.title2.bold())
                    Text("Check every line. Touch ID signs exactly this.").foregroundStyle(Theme.inkSoft)
                }
            }

            VStack(spacing: 0) {
                ForEach(Array(payment.plan.outputs.enumerated()), id: \.offset) { _, out in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label(for: out)).font(.body.weight(.medium))
                            if let detail = detail(for: out) {
                                Text(detail).font(.system(.callout, design: .monospaced)).foregroundStyle(Theme.inkSoft)
                                    .textSelection(.enabled)
                            }
                        }
                        Spacer()
                        if out.kind != "data" {
                            Text("\(formatDoge(Core.dogeText(out.value))) DOGE").font(.system(.body, design: .monospaced)).monospacedDigit()
                        }
                    }
                    .padding(.vertical, 10)
                    Divider()
                }
                row("Network fee", payment.plan.fee)
                Divider()
                row("Leaves your wallet", payment.plan.totalIn - change, bold: true)
            }
            .padding(.horizontal, 14)
            .background(Theme.wash(for: payment.network), in: RoundedRectangle(cornerRadius: 6))

            if let note = note {
                Text(note).font(.callout).foregroundStyle(Theme.inkSoft).fixedSize(horizontal: false, vertical: true)
            }

            if let sentTxid {
                Label("Sent. Transaction \(sentTxid.prefix(12))…", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.vmInk).textSelection(.enabled)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.bad)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                if sentTxid == nil {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button {
                        Task { await sign() }
                    } label: {
                        Label(signing ? "Signing…" : "Sign with Touch ID", systemImage: "touchid")
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.ink)
                    .keyboardShortcut(.defaultAction)
                    .disabled(signing)
                } else {
                    Button("Done") { dismiss() }.buttonStyle(.borderedProminent).tint(Theme.ink).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    /// What comes back to the wallet as change.
    private var change: UInt64 {
        payment.plan.outputs.filter { $0.address == model.address }.reduce(0) { $0 + $1.value }
    }

    private func label(for out: PlannedOutput) -> String {
        if let to = out.withdrawalTo { return "Instruction to the bridge: pay \(to.prefix(8))… on Dogecoin" }
        if out.kind == "data" { return "Data" }
        if out.address == model.address { return "Change, back to you" }
        switch payment.kind {
        case .moveIn where out.address == payment.to: return "To your deposit address"
        case .withdraw where out.address == payment.to: return "To the bridge"
        default: return "To"
        }
    }

    private func detail(for out: PlannedOutput) -> String? {
        if let to = out.withdrawalTo { return to }
        if out.kind == "data" { return out.script }
        return out.address
    }

    private var note: String? {
        switch payment.kind {
        case .send: nil
        case .moveIn: "Your deposit address was derived on this Mac from the signers' keys and matches the bridge's. It's credited to you on DogecoinVM after \(model.info?.depositConfirmations ?? 20) Dogecoin confirmations, less a \(formatDoge(model.info?.vmFee ?? "0.01")) DOGE fee."
        case .withdraw: "The bridge pays \(formatDoge(Core.dogeText(payment.koinu))) DOGE, less its \(formatDoge(model.info?.dogeFee ?? "0.1")) DOGE Dogecoin fee, to \(payment.withdrawalTo ?? "") once this is final on DogecoinVM."
        }
    }

    private func row(_ title: String, _ koinu: UInt64, bold: Bool = false) -> some View {
        HStack {
            Text(title).font(bold ? .body.bold() : .body)
            Spacer()
            Text("\(formatDoge(Core.dogeText(koinu))) DOGE").font(.system(.body, design: .monospaced)).monospacedDigit()
                .fontWeight(bold ? .bold : .regular)
        }
        .padding(.vertical, 10)
    }

    private func sign() async {
        signing = true
        defer { signing = false }
        error = nil
        do {
            sentTxid = try await model.confirm(payment)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
