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
}

/// Decodes any JSON value, for answers whose content doesn't matter.
struct AnyCodable: Codable, Sendable {
    init(from decoder: Decoder) throws { _ = try? decoder.singleValueContainer() }
    func encode(to encoder: Encoder) throws {}
}
