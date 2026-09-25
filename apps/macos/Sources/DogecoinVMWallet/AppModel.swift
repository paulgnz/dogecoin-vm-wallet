import Foundation
import Observation

/// The wallet's state and actions. The key is never held here: each payment
/// decrypts it with Touch ID, has the core sign, and lets it go.
@MainActor @Observable
final class AppModel {
    static let defaultServer = URL(string: "https://metaldoge.com")!

    private(set) var server: URL
    private let api: API

    var info: BridgeInfo?
    var status: BridgeStatus?
    /// The wallet's address: the same on Dogecoin and DogecoinVM.
    private(set) var address: String?
    var vm: AddressView?
    var doge: AddressView?
    /// Why the Dogecoin balance isn't shown, if it isn't.
    var dogeNote: String?
    var deposits: [DepositEntry] = []
    var connectionError: String?

    var hasWallet: Bool { address != nil && Vault.hasKey }

    init() {
        let saved = UserDefaults.standard.string(forKey: "server").flatMap(URL.init(string:))
        server = saved ?? Self.defaultServer
        api = API(base: saved ?? Self.defaultServer)
        address = UserDefaults.standard.string(forKey: "address")
        if address != nil && !Vault.hasKey { address = nil }
        loadWithdrawals()
        Notifier.requestPermission()
        Task { await refreshLoop() }
        Task { await listenForBlocks() }
    }

    // MARK: Refreshing

    /// True while the event stream is connected. Blocks then drive the
    /// refreshes, and the timer only keeps the status (a pause, sync
    /// progress) current.
    private var streaming = false

    private func refreshLoop() async {
        while true {
            if streaming {
                if let s = try? await api.status() { status = s }
            } else {
                await refresh()
            }
            try? await Task.sleep(for: .seconds(15))
        }
    }

    /// Listens for new blocks on either chain and refreshes at once. On
    /// DogecoinVM a block is final once accepted, so a payment shows as soon
    /// as it's final. Reconnects after 3 seconds if the stream drops.
    private func listenForBlocks() async {
        let url = server.appending(path: "api/events")
        while true {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 60 // the server pings every 25 seconds
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                streaming = true
                for try await line in bytes.lines where line.hasPrefix("data:") {
                    await refresh()
                }
            } catch {}
            streaming = false
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private var refreshing = false
    private var refreshAgain = false

    /// Refreshes everything. Calls that arrive while one is running are
    /// folded into a single follow-up, so a burst of events makes one pass.
    func refresh() async {
        if refreshing {
            refreshAgain = true
            return
        }
        refreshing = true
        defer { refreshing = false }
        repeat {
            refreshAgain = false
            await refreshOnce()
        } while refreshAgain
    }

    private func refreshOnce() async {
        do {
            if info == nil { info = try await api.info() }
            status = try await api.status()
            connectionError = nil
        } catch {
            connectionError = error.localizedDescription
            return
        }
        guard let address else { return }
        if let v = try? await api.address(address, on: .dogecoinvm) { vm = v }
        await refreshDogecoin(address)
        if let d = try? await api.deposits(for: address) {
            deposits = d
            noticeDeposits()
        }
        await refreshWithdrawals()
    }

    private func refreshDogecoin(_ address: String) async {
        guard info?.dogeWallet == true else {
            dogeNote = "This bridge doesn't serve Dogecoin balances."
            return
        }
        do {
            doge = try await api.address(address, on: .dogecoin)
            dogeNote = nil
        } catch let e as APIError where e.status == 404 {
            try? await api.watchDogecoin(address)   // first time: register the address
            doge = try? await api.address(address, on: .dogecoin)
            dogeNote = doge == nil ? "Starting to watch your Dogecoin address…" : nil
        } catch let e as APIError where e.status == 503 {
            dogeNote = "Shows once the bridge's Dogecoin node has caught up."
        } catch {
            dogeNote = "Can't load your Dogecoin balance: \(error.localizedDescription)"
        }
    }

    func setServer(_ url: URL) async {
        server = url
        UserDefaults.standard.set(url.absoluteString, forKey: "server")
        await api.setBase(url)
        info = nil
        vm = nil
        doge = nil
        await refresh()
    }

    // MARK: The wallet

    func createWallet() throws {
        try adopt(key: try Core.newKey())
    }

    func importWallet(_ text: String) throws {
        try adopt(key: try Core.parseKey(text))
    }

    private func adopt(key: String) throws {
        guard !Vault.hasKey else { throw VaultError(message: "This Mac already has a wallet. Remove it first.") }
        let addr = try Core.address(ofKey: key)
        try Vault.store(keyHex: key)
        UserDefaults.standard.set(addr, forKey: "address")
        address = addr
        loadWithdrawals()
        knownDepositStatus = nil
        Task { await refresh() }
    }

    /// The key as a WIF, after Touch ID, for backing up.
    func exportWIF() async throws -> String {
        let key = try await unlock(reason: "show your wallet key")
        return try Core.wif(key)
    }

    func removeWallet() async throws {
        _ = try await unlock(reason: "remove the wallet from this Mac")
        Vault.delete()
        UserDefaults.standard.removeObject(forKey: "address")
        address = nil
        vm = nil
        doge = nil
        deposits = []
        withdrawals = []
        knownDepositStatus = nil
    }

    private func unlock(reason: String) async throws -> String {
        try await Task.detached { try Vault.load(reason: reason) }.value
    }

    // MARK: Payments: review, then sign exactly what was reviewed

    /// The payment waiting for review, shown as a sheet.
    var review: PendingPayment?

    /// Prepares a payment on either network for review.
    func prepareSend(to destination: String, amount: String, on network: Network) async throws {
        try Core.checkAddress(destination)
        review = try await plan(.send, on: network, to: destination, koinu: try Core.koinu(amount))
    }

    /// Prepares a move from the Dogecoin balance to DogecoinVM: a payment to
    /// the personal deposit address, derived here from the signers' keys and
    /// checked against what the bridge says.
    func prepareMoveIn(amount: String) async throws {
        guard let info, let address else { throw CoreError(message: "The bridge isn't connected yet.") }
        let koinu = try Core.koinu(amount)
        let min = try Core.koinu(info.minDeposit), max = try Core.koinu(info.maxDeposit)
        if koinu < min { throw CoreError(message: "The smallest deposit is \(formatDoge(info.minDeposit)) DOGE.") }
        if max > 0 && koinu > max {
            throw CoreError(message: "During the beta a deposit can be at most \(formatDoge(info.maxDeposit)) DOGE; a larger one is held for a refund.")
        }
        let expected = try Core.depositAddress(for: address, signers: info.signers)
        let told = try await api.depositAddress(for: address)   // also registers it with the bridge
        guard told == expected else {
            throw CoreError(message: "The bridge gave a deposit address that doesn't match the peg signers, so nothing was sent.")
        }
        depositAddress = expected
        review = try await plan(.moveIn, on: .dogecoin, to: expected, koinu: koinu)
    }

    /// Prepares a withdrawal from DogecoinVM to a Dogecoin address.
    func prepareWithdraw(to destination: String, amount: String) async throws {
        guard let info else { throw CoreError(message: "The bridge isn't connected yet.") }
        try Core.checkAddress(destination)
        let koinu = try Core.koinu(amount)
        if koinu < (try Core.koinu(info.minPegOut)) {
            throw CoreError(message: "The smallest withdrawal is \(formatDoge(info.minPegOut)) DOGE.")
        }
        review = try await plan(.withdraw, on: .dogecoinvm, to: info.reserveAddress, koinu: koinu,
                                data: try Core.pegOutData(to: destination), withdrawalTo: destination)
    }

    private func plan(_ kind: PendingPayment.Kind, on network: Network, to destination: String, koinu: UInt64,
                      data: String? = nil, withdrawalTo: String? = nil) async throws -> PendingPayment {
        guard let address, let view = network == .dogecoin ? doge : vm else {
            throw CoreError(message: "Your \(network.name) balance hasn't loaded yet.")
        }
        let utxos = view.utxos.filter { $0.confirmations > 0 }
        var raw: [String: String] = [:]
        for txid in Set(utxos.map(\.txid)) {
            raw[txid] = try await api.rawTx(txid, on: network)
        }
        let plan = try Core.planPayment(from: address, utxos: utxos, rawTxs: raw, to: destination, koinu: koinu, data: data)
        return PendingPayment(kind: kind, network: network, to: destination, koinu: koinu, data: data,
                              withdrawalTo: withdrawalTo, utxos: utxos, rawTxs: raw, plan: plan)
    }

    /// Signs the reviewed payment after Touch ID, checks the signed
    /// transaction says exactly what was reviewed, and sends it.
    func confirm(_ p: PendingPayment) async throws -> String {
        let key = try await unlock(reason: p.touchIDReason)
        let payment = try Core.buildPayment(key: key, utxos: p.utxos, rawTxs: p.rawTxs, to: p.to,
                                            koinu: p.koinu, data: p.data)
        let signed = try Core.decodeTx(payment.hex)
        guard signed.outputs == p.plan.outputs, payment.fee == p.plan.fee, signed.txid == payment.txid else {
            throw CoreError(message: "The signed transaction didn't match what you reviewed, so it wasn't sent.")
        }
        if let to = p.withdrawalTo {
            // Recorded before sending, so it is tracked even if the answer is lost.
            track(Withdrawal(txid: payment.txid, to: to, amount: String(p.koinu), time: Date(), status: "sending"))
        }
        let txid = try await api.broadcast(payment.hex, on: p.network)
        guard txid == payment.txid else {
            throw CoreError(message: "The bridge reported transaction \(txid), but this wallet signed \(payment.txid).")
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            await refresh()
        }
        return txid
    }

    /// The deposit address last checked against the signers, for labelling
    /// a review.
    private(set) var depositAddress: String?

    // MARK: Withdrawals

    struct Withdrawal: Codable, Identifiable, Sendable {
        let txid: String
        let to: String
        let amount: String      // koinu
        let time: Date
        var status: String      // sending, pending, paid or unknown
        var pays: String?
        var paymentTxid: String?
        var id: String { txid }
    }

    private(set) var withdrawals: [Withdrawal] = []

    private var withdrawalsKey: String { "withdrawals.\(address ?? "")" }

    private func loadWithdrawals() {
        guard let data = UserDefaults.standard.data(forKey: withdrawalsKey),
              let list = try? JSONDecoder().decode([Withdrawal].self, from: data) else { withdrawals = []; return }
        withdrawals = list
    }

    private func saveWithdrawals() {
        if let data = try? JSONEncoder().encode(Array(withdrawals.prefix(50))) {
            UserDefaults.standard.set(data, forKey: withdrawalsKey)
        }
    }

    private func track(_ w: Withdrawal) {
        withdrawals.removeAll { $0.txid == w.txid }
        withdrawals.insert(w, at: 0)
        saveWithdrawals()
    }

    /// Checks each unpaid withdrawal with the bridge, and notifies when one
    /// is paid on Dogecoin.
    private func refreshWithdrawals() async {
        for (i, w) in withdrawals.enumerated() where w.status != "paid" {
            guard let s = try? await api.pegOut(w.txid) else { continue }
            var updated = w
            updated.status = s.status == "unknown" && w.status == "sending" ? "sending" : s.status
            updated.pays = s.pays
            updated.paymentTxid = s.paymentTxid
            if i < withdrawals.count, withdrawals[i].txid == w.txid { withdrawals[i] = updated }
            if s.status == "paid" {
                Notifier.post(title: "Withdrawal paid",
                              body: "\(formatDoge(s.pays ?? "")) DOGE is on its way to \(w.to.prefix(8))… on Dogecoin.")
            }
        }
        saveWithdrawals()
    }

    /// Notifies when a deposit is credited. The first load only records.
    private var knownDepositStatus: [String: String]?

    private func noticeDeposits() {
        let now = Dictionary(deposits.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
        if let before = knownDepositStatus {
            for d in deposits where d.status == "credited" && before[d.id] != "credited" {
                Notifier.post(title: "Deposit credited",
                              body: "\(formatDoge(d.credited ?? d.amount)) DOGE is in your DogecoinVM balance.")
            }
        }
        knownDepositStatus = now
    }
}

/// A payment prepared for review: what it will do, and everything needed to
/// sign exactly that.
struct PendingPayment: Identifiable, Sendable {
    enum Kind: Sendable { case send, moveIn, withdraw }
    let id = UUID()
    let kind: Kind
    let network: Network
    let to: String
    let koinu: UInt64
    let data: String?
    let withdrawalTo: String?
    let utxos: [Utxo]
    let rawTxs: [String: String]
    let plan: PaymentPlan

    var title: String {
        switch kind {
        case .send: "Send on \(network.name)"
        case .moveIn: "Move to DogecoinVM"
        case .withdraw: "Withdraw to Dogecoin"
        }
    }

    var touchIDReason: String {
        let amount = formatDoge(Core.dogeText(koinu))
        switch kind {
        case .send: return "send \(amount) DOGE on \(network.name)"
        case .moveIn: return "move \(amount) DOGE to DogecoinVM"
        case .withdraw: return "withdraw \(amount) DOGE to Dogecoin"
        }
    }
}

/// Formats an API amount ("12.50000000") as DOGE, grouped, without trailing
/// zeros.
func formatDoge(_ s: String) -> String {
    let negative = s.hasPrefix("-")
    let body = negative ? String(s.dropFirst()) : s
    let parts = body.split(separator: ".", maxSplits: 1)
    let whole = Int(parts.first ?? "0") ?? 0
    let grouped = NumberFormatter.localizedString(from: NSNumber(value: whole), number: .decimal)
    var frac = parts.count > 1 ? String(parts[1]) : ""
    while frac.hasSuffix("0") { frac.removeLast() }
    return (negative ? "−" : "") + grouped + (frac.isEmpty ? "" : "." + frac)
}
