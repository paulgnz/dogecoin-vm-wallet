import Foundation

struct CoreError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The Rust core (core/): keys, addresses and transactions, the same code the
/// test vectors pin to the web wallet byte for byte. One JSON call.
enum Core {
    static func call(_ request: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: request)
        guard let text = String(data: data, encoding: .utf8) else { throw CoreError(message: "bad request") }
        guard let out = text.withCString({ dwc_call($0) }) else { throw CoreError(message: "the wallet core did not answer") }
        defer { dwc_free(out) }
        let json = (try? JSONSerialization.jsonObject(with: Data(bytes: out, count: strlen(out)))) as? [String: Any] ?? [:]
        if let error = json["error"] as? String { throw CoreError(message: error) }
        return json
    }

    static func string(_ request: [String: Any], _ field: String) throws -> String {
        guard let v = try call(request)[field] as? String else { throw CoreError(message: "the wallet core returned no \(field)") }
        return v
    }

    // MARK: Keys

    static func newKey() throws -> String { try string(["op": "newKey"], "key") }
    static func parseKey(_ text: String) throws -> String { try string(["op": "parseKey", "text": text], "key") }
    static func address(ofKey key: String) throws -> String { try string(["op": "keyInfo", "key": key], "address") }
    static func wif(_ key: String) throws -> String { try string(["op": "wif", "key": key], "wif") }

    // MARK: Addresses and amounts

    /// Throws unless `address` is a valid mainnet address.
    static func checkAddress(_ address: String) throws { _ = try call(["op": "decodeAddress", "address": address]) }

    static func depositAddress(for address: String, signers: Signers) throws -> String {
        try string(["op": "depositAddress", "address": address,
                    "signers": ["required": signers.required, "publicKeys": signers.publicKeys]], "address")
    }

    static func pegOutData(to address: String) throws -> String {
        try string(["op": "pegOutData", "address": address], "data")
    }

    /// Koinu as a DOGE decimal string, for formatDoge.
    static func dogeText(_ koinu: UInt64) -> String {
        "\(koinu / 100_000_000).\(String(format: "%08llu", koinu % 100_000_000))"
    }

    static func koinu(_ doge: String) throws -> UInt64 {
        guard let k = UInt64(try string(["op": "parseDoge", "text": doge], "koinu")) else { throw CoreError(message: "bad amount") }
        return k
    }

    // MARK: Payments

    /// Plans a payment for review: nothing is signed.
    static func planPayment(from: String, utxos: [Utxo], rawTxs: [String: String],
                            to address: String, koinu: UInt64, data: String? = nil,
                            feePerByte: UInt64? = nil) throws -> PaymentPlan {
        var req = paymentRequest("planPayment", utxos: utxos, rawTxs: rawTxs, to: address, koinu: koinu,
                                 data: data, feePerByte: feePerByte)
        req["fromAddress"] = from
        let r = try call(req)
        guard let fee = (r["fee"] as? String).flatMap(UInt64.init),
              let totalIn = (r["totalIn"] as? String).flatMap(UInt64.init) else { throw CoreError(message: "the wallet core returned no plan") }
        return PaymentPlan(outputs: outputs(r["outputs"]), fee: fee, totalIn: totalIn)
    }

    /// Reads a signed transaction back: its id, the coins it spends
    /// ("txid:vout") and its outputs.
    static func decodeTx(_ hex: String) throws -> (txid: String, inputs: [String], outputs: [PlannedOutput]) {
        let r = try call(["op": "decodeTx", "hex": hex])
        return (r["txid"] as? String ?? "", r["inputs"] as? [String] ?? [], outputs(r["outputs"]))
    }

    private static func outputs(_ value: Any?) -> [PlannedOutput] {
        (value as? [[String: Any]] ?? []).map {
            PlannedOutput(value: UInt64($0["value"] as? String ?? "") ?? 0, script: $0["script"] as? String ?? "",
                          kind: $0["kind"] as? String ?? "other", address: $0["address"] as? String,
                          withdrawalTo: $0["withdrawalTo"] as? String)
        }
    }

    private static func paymentRequest(_ op: String, utxos: [Utxo], rawTxs: [String: String],
                                       to address: String, koinu: UInt64, data: String?,
                                       feePerByte: UInt64?) -> [String: Any] {
        var req: [String: Any] = [
            "op": op,
            "utxos": utxos.map { ["txid": $0.txid, "vout": $0.vout, "value": $0.value, "script": $0.script, "confirmations": $0.confirmations] },
            "rawTxs": rawTxs, "toAddress": address, "amount": String(koinu),
        ]
        if let data { req["data"] = data }
        if let feePerByte { req["feePerByte"] = feePerByte }
        return req
    }

    struct Payment { let hex: String; let txid: String; let fee: UInt64 }

    /// Builds and signs a payment. `rawTxs` holds each spent output's
    /// transaction, which the core checks against its txid and takes the
    /// value from, so a lying server can't inflate the fee.
    static func buildPayment(key: String, utxos: [Utxo], rawTxs: [String: String],
                             to address: String, koinu: UInt64, data: String? = nil,
                             feePerByte: UInt64? = nil) throws -> Payment {
        var req = paymentRequest("buildPayment", utxos: utxos, rawTxs: rawTxs, to: address, koinu: koinu,
                                 data: data, feePerByte: feePerByte)
        req["key"] = key
        let r = try call(req)
        guard let hex = r["hex"] as? String, let txid = r["txid"] as? String,
              let fee = (r["fee"] as? String).flatMap(UInt64.init) else { throw CoreError(message: "the wallet core returned no transaction") }
        return Payment(hex: hex, txid: txid, fee: fee)
    }
}

/// One output of a payment, as the core describes it.
struct PlannedOutput: Equatable, Sendable {
    let value: UInt64
    let script: String
    let kind: String            // "address", "data" or "other"
    let address: String?
    let withdrawalTo: String?   // for a DVMO withdrawal instruction
}

struct PaymentPlan: Equatable, Sendable {
    let outputs: [PlannedOutput]
    let fee: UInt64
    let totalIn: UInt64
}
