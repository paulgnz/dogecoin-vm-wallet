import SwiftUI

/// Transfers in flight, one card each until it's done: deposits as a row of
/// confirmation blocks that fill as Dogecoin blocks arrive, withdrawals as
/// their stages, and Dogecoin sends with the change that comes back. Block
/// events refresh the model, so the cards move as the chains do.
struct InFlightView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let cards = self.cards
        if !cards.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(cards) { $0 }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("In progress")
        }
    }

    private var cards: [InFlightCard] {
        var out: [InFlightCard] = []
        let vmFee = parseDogeKoinu(model.info?.vmFee ?? "0.01")

        for d in model.deposits where !["credited", "refunded"].contains(d.status) {
            let amount = parseDogeKoinu(d.amount)
            let gets = formatDoge(Core.dogeText(amount > vmFee ? amount - vmFee : 0))
            let title = "Moving \(formatDoge(d.amount)) DOGE to DogecoinVM"
            switch d.status {
            case "held":
                out.append(InFlightCard(id: d.id, title: title, detail: "Held for a refund: \(d.reason ?? "")", tint: Theme.bad))
            case "waiting_for_capacity":
                out.append(InFlightCard(id: d.id, title: title, detail: "Confirmed, and waiting for room under the beta limit."))
            case "crediting":
                out.append(InFlightCard(id: d.id, title: title, progress: .blocks(d.required, d.required),
                                        detail: "Confirmed. Crediting \(gets) DOGE now."))
            default:
                let left = max(d.required - d.confirmations, 0)
                out.append(InFlightCard(id: d.id, title: title, progress: .blocks(d.confirmations, d.required),
                                        detail: "\(d.confirmations) of \(d.required) confirmations. \(about(left)) left, then \(gets) DOGE arrives.",
                                        quiet: quietNote))
            }
        }

        for w in model.withdrawals where w.inFlight {
            let final = w.status == "pending" || w.status == "paid"
            let paid = w.status == "paid"
            let detail = paid ? "\(formatDoge(w.pays ?? "")) DOGE is on its way; it confirms in the next Dogecoin block, usually within a minute."
                : final ? "The bridge pays it within seconds."
                : "Waiting for it to be final on DogecoinVM, about two seconds."
            out.append(InFlightCard(id: w.txid, title: "Withdrawing \(formatDoge(Core.dogeText(UInt64(w.amount) ?? 0))) DOGE to Dogecoin",
                                    progress: .steps([("Final on DogecoinVM", final), ("Paid on Dogecoin", paid), ("In a Dogecoin block", false)]),
                                    detail: detail, quiet: paid ? quietNote : nil))
        }

        let depositTxids = Set(model.deposits.map(\.txid))
        for o in model.outgoing where o.network == Network.dogecoin.rawValue && o.kind != "withdraw" {
            if o.kind == "move" && depositTxids.contains(o.txid) { continue } // the deposit card covers it
            let back = o.change > 0 ? " \(formatDoge(Core.dogeText(o.change))) DOGE change comes back when it confirms." : ""
            let amount = formatDoge(Core.dogeText(o.amount))
            out.append(InFlightCard(id: o.txid,
                                    title: o.kind == "move" ? "Moving \(amount) DOGE to DogecoinVM" : "Sending \(amount) DOGE on Dogecoin",
                                    progress: .steps([("Sent", true), ("In a Dogecoin block", false)]),
                                    detail: "Waiting for a Dogecoin block, usually within a minute.\(back)", quiet: quietNote))
        }
        return out
    }

    /// Dogecoin blocks come at random. When one is slow, say so rather than
    /// leave a countdown that looks stuck.
    private var quietNote: String? {
        guard let t = model.status?.dogecoinBlockTime, t > 0 else { return nil }
        let minutes = Int(Date().timeIntervalSince1970 - Double(t)) / 60
        guard minutes >= 4 else { return nil }
        return "Dogecoin hasn't found a block for \(minutes) minutes. Blocks average a minute but come at random; this continues when the next one arrives."
    }

    private func about(_ minutes: Int) -> String { minutes <= 1 ? "About a minute" : "About \(minutes) minutes" }
}

/// Koinu in a DOGE decimal string.
private func parseDogeKoinu(_ doge: String) -> UInt64 {
    let parts = doge.split(separator: ".", maxSplits: 1)
    let whole = UInt64(parts.first ?? "0") ?? 0
    let frac = parts.count > 1 ? String(parts[1].prefix(8)).padding(toLength: 8, withPad: "0", startingAt: 0) : "00000000"
    return whole * 100_000_000 + (UInt64(frac) ?? 0)
}

struct InFlightCard: View, Identifiable {
    enum Progress {
        case blocks(Int, Int)                 // confirmations so far, needed
        case steps([(String, Bool)])          // label, done
    }

    let id: String
    let title: String
    var progress: Progress? = nil
    let detail: String
    var tint: Color = Theme.coin
    var quiet: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            switch progress {
            case .blocks(let have, let need): ConfirmationBlocks(have: have, need: need)
            case .steps(let steps):
                HStack(spacing: 14) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                        Label(step.0, systemImage: step.1 ? "checkmark" : "circle")
                            .font(.caption)
                            .foregroundStyle(step.1 ? Theme.ink : Theme.inkSoft)
                    }
                }
            case nil: EmptyView()
            }
            Text(detail).font(.callout).foregroundStyle(Theme.inkSoft).fixedSize(horizontal: false, vertical: true)
            if let quiet {
                Text(quiet).font(.callout).foregroundStyle(Theme.coinInk).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.wash(for: .dogecoin).opacity(0.35)))
        .overlay(alignment: .leading) { Rectangle().fill(tint).frame(width: 4) }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Confirmations as a row of blocks. A block that fills pops in with a
/// spring, unless Reduce Motion is on.
struct ConfirmationBlocks: View {
    let have: Int
    let need: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<max(need, 1), id: \.self) { i in
                RoundedRectangle(cornerRadius: 3)
                    .fill(i < have ? Theme.coin : Theme.coinWash)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(i < have ? Theme.coin : Theme.inkSoft.opacity(0.3)))
                    .frame(width: 16, height: 16)
                    .scaleEffect(i < have ? 1 : 0.85)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.55), value: have)
        .accessibilityElement()
        .accessibilityLabel("\(min(have, need)) of \(need) confirmations")
    }
}
