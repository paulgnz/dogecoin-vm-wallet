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
        Task { await refreshLoop() }
    }

    // MARK: Refreshing

    private func refreshLoop() async {
        while true {
            await refresh()
            try? await Task.sleep(for: .seconds(15))
        }
    }

    func refresh() async {
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
        if let d = try? await api.deposits(for: address) { deposits = d }
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
    }

    private func unlock(reason: String) async throws -> String {
        try await Task.detached { try Vault.load(reason: reason) }.value
    }

    // MARK: Payments

    /// Sends DOGE on either network.
    func send(to destination: String, amount: String, on network: Network) async throws -> String {
        try Core.checkAddress(destination)
        let koinu = try Core.koinu(amount)
        return try await pay(on: network, to: destination, koinu: koinu,
                             reason: "send \(amount) DOGE on \(network.name)")
    }

    /// Moves DOGE from the Dogecoin balance to DogecoinVM: pays the personal
    /// deposit address, derived here from the signers' keys and checked
    /// against what the bridge says.
    func moveIn(amount: String) async throws -> String {
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
        return try await pay(on: .dogecoin, to: expected, koinu: koinu,
                             reason: "move \(amount) DOGE to DogecoinVM")
    }

    /// Withdraws DOGE from DogecoinVM to a Dogecoin address (the wallet's own,
    /// by default).
    func withdraw(to destination: String, amount: String) async throws -> String {
        guard let info else { throw CoreError(message: "The bridge isn't connected yet.") }
        try Core.checkAddress(destination)
        let koinu = try Core.koinu(amount)
        if koinu < (try Core.koinu(info.minPegOut)) {
            throw CoreError(message: "The smallest withdrawal is \(formatDoge(info.minPegOut)) DOGE.")
        }
        return try await pay(on: .dogecoinvm, to: info.reserveAddress, koinu: koinu,
                             data: try Core.pegOutData(to: destination),
                             reason: "withdraw \(amount) DOGE to Dogecoin")
    }

    private func pay(on network: Network, to destination: String, koinu: UInt64,
                     data: String? = nil, reason: String) async throws -> String {
        guard let view = network == .dogecoin ? doge : vm else {
            throw CoreError(message: "Your \(network.name) balance hasn't loaded yet.")
        }
        let utxos = view.utxos.filter { $0.confirmations > 0 }
        var raw: [String: String] = [:]
        for txid in Set(utxos.map(\.txid)) {
            raw[txid] = try await api.rawTx(txid, on: network)
        }
        let key = try await unlock(reason: reason)
        let payment = try Core.buildPayment(key: key, utxos: utxos, rawTxs: raw,
                                            to: destination, koinu: koinu, data: data)
        let txid = try await api.broadcast(payment.hex, on: network)
        guard txid == payment.txid else {
            throw CoreError(message: "The bridge reported transaction \(txid), but this wallet signed \(payment.txid).")
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            await refresh()
        }
        return txid
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
