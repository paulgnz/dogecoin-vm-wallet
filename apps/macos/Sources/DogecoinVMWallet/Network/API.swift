import Foundation

// The bridge's public API (dogevm serve), the same one metaldoge.com's web
// wallet uses. It holds no keys: everything is signed in this app.

struct Signers: Codable, Sendable { let required: Int; let publicKeys: [String] }

struct BridgeInfo: Codable, Sendable {
    let dogecoinNetwork: String
    let dogecoinvmNetwork: String
    let pegAddress: String
    let reserveAddress: String
    let signers: Signers
    let depositConfirmations: Int
    let vmFee: String
    let dogeFee: String
    let minDeposit: String
    let minPegOut: String
    let maxDeposit: String
    let maxCirculating: String
    let dogeWallet: Bool?
    /// Smaller deposits need fewer confirmations; larger ones need
    /// depositConfirmations.
    let confirmationTiers: [ConfirmationTier]?

    struct ConfirmationTier: Codable, Sendable { let upTo: String; let confirmations: Int }

    /// How many Dogecoin confirmations a deposit of `koinu` needs.
    func confirmations(for koinu: UInt64) -> Int {
        for t in confirmationTiers ?? [] where koinu <= parseKoinu(t.upTo) {
            return t.confirmations
        }
        return depositConfirmations
    }

    /// How long deposits wait, e.g. "1 confirmation for up to 1 DOGE, 6 for
    /// up to 10 DOGE, … and 20 for anything larger".
    var confirmationsText: String {
        let tiers = confirmationTiers ?? []
        func plural(_ n: Int) -> String { "\(n) confirmation\(n == 1 ? "" : "s")" }
        if tiers.isEmpty { return plural(depositConfirmations) }
        let parts = tiers.enumerated().map { i, t in
            "\(i == 0 ? plural(t.confirmations) : String(t.confirmations)) for up to \(formatDoge(t.upTo)) DOGE"
        }
        return parts.joined(separator: ", ") + ", and \(depositConfirmations) for anything larger"
    }
}

/// Koinu in a DOGE decimal string from the API.
private func parseKoinu(_ doge: String) -> UInt64 {
    let parts = doge.split(separator: ".", maxSplits: 1)
    let whole = UInt64(parts.first ?? "0") ?? 0
    let frac = parts.count > 1 ? String(parts[1].prefix(8)).padding(toLength: 8, withPad: "0", startingAt: 0) : "00000000"
    return whole * 100_000_000 + (UInt64(frac) ?? 0)
}

struct BridgeStatus: Codable, Sendable {
    struct Sync: Codable, Sendable { let headers: Int; let progress: Double; let syncing: Bool }
    struct Audit: Codable, Sendable { let locked: String; let circulating: String; let solvent: Bool }
    struct Pause: Codable, Sendable { let reason: String }
    let dogecoinvmHeight: Int
    let dogecoinHeight: Int
    let dogecoinSync: Sync?
    let audit: Audit?
    let paused: Pause?
    /// When the latest Dogecoin block was found, unix seconds.
    let dogecoinBlockTime: Int?
}

struct Utxo: Codable, Sendable, Hashable {
    let txid: String
    let vout: Int
    let value: String      // koinu, as a string
    let script: String
    let confirmations: Int
}

struct HistoryEntry: Codable, Sendable, Hashable, Identifiable {
    let txid: String
    let net: String        // signed DOGE
    let confirmations: Int
    let time: Int?
    var id: String { txid }
}

struct AddressView: Codable, Sendable {
    let address: String
    let confirmed: String
    let pending: String
    let utxos: [Utxo]
    let history: [HistoryEntry]
}

struct DepositEntry: Codable, Sendable, Identifiable {
    let txid: String
    let vout: Int
    let amount: String
    let confirmations: Int
    let required: Int
    let status: String
    let reason: String?
    let credited: String?
    let creditTxid: String?
    var id: String { "\(txid):\(vout)" }
}

struct PegOutStatus: Codable, Sendable {
    let status: String          // pending, paid or unknown
    let pays: String?
    let paymentTxid: String?
    let paymentConfirmations: Int?   // the payout's, on Dogecoin
}

struct APIError: LocalizedError, Sendable {
    let status: Int            // 0: no response
    let message: String
    var errorDescription: String? { message }
}

/// Which chain a request is about.
enum Network: String, CaseIterable, Identifiable, Sendable {
    case dogecoinvm, dogecoin
    var id: String { rawValue }
    var name: String { self == .dogecoin ? "Dogecoin" : "DogecoinVM" }
    /// Koinu per byte. DogecoinVM pays its relay minimum, 0.001 DOGE/kB: its
    /// blocks have room to spare. Dogecoin, which can be busy, gets the core's
    /// default, the recommended 0.01 DOGE/kB.
    var feePerByte: UInt64? { self == .dogecoinvm ? 100 : nil }
}

actor API {
    var base: URL

    init(base: URL) { self.base = base }

    func setBase(_ url: URL) { base = url }

    private func request<T: Decodable>(_ path: String, body: [String: String]? = nil) async throws -> T {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.timeoutInterval = 30
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw APIError(status: 0, message: "Can't reach the bridge: \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? "request failed (\(status))"
            throw APIError(status: status, message: message)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func info() async throws -> BridgeInfo { try await request("api/info") }
    func status() async throws -> BridgeStatus { try await request("api/status") }

    func address(_ address: String, on network: Network) async throws -> AddressView {
        try await request(network == .dogecoin ? "api/doge/address/\(address)" : "api/address/\(address)")
    }

    func watchDogecoin(_ address: String) async throws {
        let _: [String: AnyCodable] = try await request("api/doge/watch", body: ["address": address])
    }

    func rawTx(_ txid: String, on network: Network) async throws -> String {
        let r: [String: String] = try await request(network == .dogecoin ? "api/doge/rawtx/\(txid)" : "api/rawtx/\(txid)")
        guard let hex = r["hex"] else { throw APIError(status: 0, message: "no transaction \(txid)") }
        return hex
    }

    func broadcast(_ hex: String, on network: Network) async throws -> String {
        let r: [String: String] = try await request(network == .dogecoin ? "api/doge/tx" : "api/tx", body: ["hex": hex])
        guard let txid = r["txid"] else { throw APIError(status: 0, message: "no txid in the answer") }
        return txid
    }

    func depositAddress(for address: String) async throws -> String {
        let r: [String: String] = try await request("api/deposit-address", body: ["address": address])
        guard let d = r["depositAddress"] else { throw APIError(status: 0, message: "no deposit address in the answer") }
        return d
    }

    func deposits(for address: String) async throws -> [DepositEntry] { try await request("api/deposits/\(address)") }

    func pegOut(_ txid: String) async throws -> PegOutStatus { try await request("api/pegout/\(txid)") }
}

/// Decodes any JSON value, for answers whose content doesn't matter.
struct AnyCodable: Codable, Sendable {
    init(from decoder: Decoder) throws { _ = try? decoder.singleValueContainer() }
    func encode(to encoder: Encoder) throws {}
}
