import Foundation
import CryptoKit
import LocalAuthentication

struct VaultError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Where the wallet key lives: in a file, encrypted to a Secure Enclave key
/// that only Touch ID (or the Mac's password, on a Mac without Touch ID) can
/// use. The Dogecoin key is secp256k1, which the Secure Enclave can't hold
/// directly, so it is wrapped (ECIES-style) with an Enclave P-256 key:
/// encrypting needs only the public key; decrypting runs the Enclave key,
/// which asks for Touch ID. The file is useless on any other Mac.
///
/// This is the vault design of the PulseVM wallet.
enum Vault {
    private static let dir: URL = {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.homeDirectoryForCurrentUser
        let d = base.appendingPathComponent("DogecoinVM Wallet", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return d
    }()
    private static let keyURL = dir.appendingPathComponent("wallet-key.bin")
    private static let wrapURL = dir.appendingPathComponent("enclave-wrap.bin")
    private static let salt = Data("com.metaldoge.wallet.vault.v1".utf8)

    static var hasKey: Bool { FileManager.default.fileExists(atPath: keyURL.path) }

    static var isAvailable: Bool { SecureEnclave.isAvailable }

    /// Stores the key (hex), encrypted to the Enclave. No Touch ID needed.
    static func store(keyHex: String) throws {
        guard SecureEnclave.isAvailable else { throw VaultError(message: "This Mac has no Secure Enclave, which the wallet needs to protect your key.") }
        guard let raw = Data(hexString: keyHex), raw.count == 32 else { throw VaultError(message: "invalid key") }
        let wrapPub = try wrappingPublicKey()
        let eph = P256.KeyAgreement.PrivateKey()
        let sym = try eph.sharedSecretFromKeyAgreement(with: wrapPub)
            .hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Data(), outputByteCount: 32)
        let sealed = try AES.GCM.seal(raw, using: sym)
        var blob = eph.publicKey.x963Representation   // 65 bytes
        blob.append(sealed.combined!)                  // nonce, ciphertext, tag
        try blob.write(to: keyURL, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
    }

    /// Decrypts the key, asking for Touch ID with `reason`.
    static func load(reason: String) throws -> String {
        guard let blob = try? Data(contentsOf: keyURL), blob.count > 65 else {
            throw VaultError(message: "No wallet key on this Mac.")
        }
        let ephPub = try P256.KeyAgreement.PublicKey(x963Representation: blob.prefix(65))
        let sealed = try AES.GCM.SealedBox(combined: blob.dropFirst(65))
        let ctx = LAContext()
        ctx.localizedReason = reason
        let wrap = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: Data(contentsOf: wrapURL),
                                                                  authenticationContext: ctx)
        do {
            let sym = try wrap.sharedSecretFromKeyAgreement(with: ephPub)   // Touch ID here
                .hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Data(), outputByteCount: 32)
            return try AES.GCM.open(sealed, using: sym).hexString
        } catch {
            throw VaultError(message: "Touch ID was cancelled or didn't match, so nothing was signed.")
        }
    }

    /// Deletes the key. Without a backup, its DOGE is gone.
    static func delete() {
        try? FileManager.default.removeItem(at: keyURL)
    }

    private static func wrappingPublicKey() throws -> P256.KeyAgreement.PublicKey {
        if let data = try? Data(contentsOf: wrapURL) {
            return try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: data).publicKey
        }
        // Touch ID if it's set up; the Mac's password otherwise.
        let flags: SecAccessControlCreateFlags = LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
            ? [.privateKeyUsage, .biometryCurrentSet]
            : [.privateKeyUsage, .userPresence]
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, &error) else {
            throw VaultError(message: "could not protect the key")
        }
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
        try key.dataRepresentation.write(to: wrapURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: wrapURL.path)
        return key.publicKey
    }
}

extension Data {
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var data = Data(capacity: hexString.count / 2)
        var i = hexString.startIndex
        while i < hexString.endIndex {
            let j = hexString.index(i, offsetBy: 2)
            guard let b = UInt8(hexString[i..<j], radix: 16) else { return nil }
            data.append(b)
            i = j
        }
        self = data
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
