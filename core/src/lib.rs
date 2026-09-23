//! Keys, addresses and transactions for Dogecoin and DogecoinVM.
//!
//! This is the macOS wallet's counterpart of the web wallet's `chain.js`, and
//! it must agree with it byte for byte: `tests/vectors.rs` checks it against
//! vectors the web wallet generated and the DogecoinVM Go code verified.
//! Transactions are legacy (pre-SegWit) format, which both chains use.

pub mod ffi;

use k256::ecdsa::{signature::hazmat::PrehashSigner, Signature, SigningKey};
use ripemd::Ripemd160;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use zeroize::Zeroizing;

/// One koinu is 10^-8 DOGE.
pub const KOINU: u64 = 100_000_000;
/// Dogecoin's recommended wallet fee, 0.01 DOGE per kB, per byte.
const FEE_PER_BYTE: u64 = 1_000;
/// Outputs below the soft dust limit cost that much again in fee.
const SOFT_DUST: u64 = KOINU / 100;
/// Outputs below the hard dust limit are not relayed.
const HARD_DUST: u64 = SOFT_DUST / 10;
/// A payment whose fee would exceed this is refused: something is wrong.
const MAX_FEE: u64 = 5 * KOINU;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error(pub String);

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Error {}

pub type Result<T> = std::result::Result<T, Error>;

fn err<T>(msg: impl Into<String>) -> Result<T> {
    Err(Error(msg.into()))
}

// --- hashing and base58check -----------------------------------------------------

pub fn sha256d(data: &[u8]) -> [u8; 32] {
    Sha256::digest(Sha256::digest(data)).into()
}

pub fn hash160(data: &[u8]) -> [u8; 20] {
    Ripemd160::digest(Sha256::digest(data)).into()
}

fn check_encode(version: u8, payload: &[u8]) -> String {
    let mut data = Vec::with_capacity(1 + payload.len() + 4);
    data.push(version);
    data.extend_from_slice(payload);
    let sum = sha256d(&data);
    data.extend_from_slice(&sum[..4]);
    bs58::encode(data).into_string()
}

fn check_decode(s: &str) -> Result<(u8, Vec<u8>)> {
    let raw = bs58::decode(s.trim()).into_vec().map_err(|_| Error("not base58".into()))?;
    if raw.len() < 5 {
        return err("too short");
    }
    let (data, sum) = raw.split_at(raw.len() - 4);
    if sha256d(data)[..4] != *sum {
        return err("checksum mismatch: check for a typo");
    }
    Ok((data[0], data[1..].to_vec()))
}

// --- networks, addresses and scripts ---------------------------------------------

/// Address and WIF version bytes. Dogecoin and DogecoinVM mainnet share them,
/// so a key has one address on both networks.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Deserialize, serde::Serialize)]
pub struct Versions {
    pub p2pkh: u8,
    pub p2sh: u8,
    pub wif: u8,
}

pub const MAINNET: Versions = Versions { p2pkh: 30, p2sh: 22, wif: 158 };

/// Where coins go: pay-to-public-key-hash (kind 0) or pay-to-script-hash (1).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Destination {
    pub kind: u8,
    pub hash: [u8; 20],
}

impl Destination {
    pub fn pk_script(&self) -> Vec<u8> {
        if self.kind == 1 {
            [&[0xa9, 0x14][..], &self.hash, &[0x87]].concat()
        } else {
            [&[0x76, 0xa9, 0x14][..], &self.hash, &[0x88, 0xac]].concat()
        }
    }

    pub fn address(&self, v: Versions) -> String {
        check_encode(if self.kind == 1 { v.p2sh } else { v.p2pkh }, &self.hash)
    }
}

/// Decodes an address on the network with versions `v`.
pub fn decode_address(address: &str, v: Versions) -> Result<Destination> {
    let (version, payload) = check_decode(address)?;
    if payload.len() != 20 {
        return err("not a pay-to-hash address");
    }
    let mut hash = [0u8; 20];
    hash.copy_from_slice(&payload);
    if version == v.p2pkh {
        Ok(Destination { kind: 0, hash })
    } else if version == v.p2sh {
        Ok(Destination { kind: 1, hash })
    } else {
        err("address is for a different network")
    }
}

fn push_data(data: &[u8]) -> Result<Vec<u8>> {
    if data.len() < 0x4c {
        Ok([&[data.len() as u8][..], data].concat())
    } else if data.len() <= 0xff {
        Ok([&[0x4c, data.len() as u8][..], data].concat())
    } else {
        err("push too large")
    }
}

/// The peg signers: an m-of-n multisig of compressed public keys.
#[derive(Debug, Clone, serde::Deserialize, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Signers {
    pub required: u8,
    pub public_keys: Vec<String>,
}

impl Signers {
    fn multisig(&self) -> Result<Vec<u8>> {
        if self.required < 1 || self.required as usize > self.public_keys.len() || self.public_keys.len() > 15 {
            return err("invalid signer set");
        }
        let mut s = vec![0x50 + self.required];
        for k in &self.public_keys {
            let raw = hex::decode(k).map_err(|_| Error("signer key is not hex".into()))?;
            if raw.len() != 33 {
                return err("signer keys must be compressed");
            }
            s.extend(push_data(&raw)?);
        }
        s.push(0x50 + self.public_keys.len() as u8);
        s.push(0xae);
        Ok(s)
    }
}

/// The redeem script of `dest`'s personal deposit address: `<kind || hash160>
/// OP_DROP` followed by the signers' multisig. Only the signers can spend it,
/// and it credits `dest`.
pub fn deposit_redeem_script(dest: &Destination, signers: &Signers) -> Result<Vec<u8>> {
    let mut s = vec![0x15, dest.kind];
    s.extend_from_slice(&dest.hash);
    s.push(0x75);
    s.extend(signers.multisig()?);
    Ok(s)
}

/// `dest`'s personal Dogecoin deposit address, computed from the signers'
/// keys, so the wallet can check what the bridge says.
pub fn deposit_address(dest: &Destination, signers: &Signers, v: Versions) -> Result<String> {
    let script = deposit_redeem_script(dest, signers)?;
    Ok(Destination { kind: 1, hash: hash160(&script) }.address(v))
}

/// The DVMO tag asking the bridge to pay a withdrawal to `dest` on Dogecoin.
pub fn peg_out_data(dest: &Destination) -> Vec<u8> {
    [&b"DVMO"[..], &[dest.kind], &dest.hash].concat()
}

// --- keys ------------------------------------------------------------------------

/// A private key, wiped from memory when dropped.
pub struct Key(Zeroizing<[u8; 32]>);

impl Key {
    pub fn from_bytes(b: &[u8]) -> Result<Key> {
        if b.len() != 32 {
            return err("a private key is 32 bytes");
        }
        if SigningKey::from_slice(b).is_err() {
            return err("not a valid private key");
        }
        let mut k = Zeroizing::new([0u8; 32]);
        k.copy_from_slice(b);
        Ok(Key(k))
    }

    /// A new random key.
    pub fn generate() -> Key {
        let sk = SigningKey::random(&mut rand_core::OsRng);
        Key::from_bytes(&sk.to_bytes()).expect("a fresh key is valid")
    }

    /// Parses 64 hex characters, or a compressed-key WIF for any network. An
    /// uncompressed-key WIF would open a different, empty wallet, so it is
    /// refused.
    pub fn parse(s: &str) -> Result<Key> {
        let s = s.trim();
        if s.len() == 64 && s.bytes().all(|c| c.is_ascii_hexdigit()) {
            return Key::from_bytes(&Zeroizing::new(hex::decode(s).expect("checked hex")));
        }
        let (_, payload) = check_decode(s)?;
        let payload = Zeroizing::new(payload);
        match payload.len() {
            32 => err("this is an uncompressed-key WIF; export a compressed one"),
            33 if payload[32] == 1 => Key::from_bytes(&payload[..32]),
            _ => err("not a private key"),
        }
    }

    pub fn bytes(&self) -> &[u8; 32] {
        &self.0
    }

    fn signing_key(&self) -> SigningKey {
        SigningKey::from_slice(&self.0[..]).expect("checked when made")
    }

    pub fn public_key(&self) -> [u8; 33] {
        let point = self.signing_key().verifying_key().to_encoded_point(true);
        let mut out = [0u8; 33];
        out.copy_from_slice(point.as_bytes());
        out
    }

    pub fn destination(&self) -> Destination {
        Destination { kind: 0, hash: hash160(&self.public_key()) }
    }

    pub fn wif(&self, v: Versions) -> Zeroizing<String> {
        let mut payload = Zeroizing::new([0u8; 33]);
        payload[..32].copy_from_slice(&self.0[..]);
        payload[32] = 1;
        Zeroizing::new(check_encode(v.wif, &payload[..]))
    }
}

// --- amounts ---------------------------------------------------------------------

/// Parses a DOGE amount like "12.5" into koinu.
pub fn parse_doge(s: &str) -> Result<u64> {
    let s = s.trim();
    let (whole, frac) = s.split_once('.').unwrap_or((s, ""));
    if whole.is_empty() || whole.len() > 11 || frac.len() > 8
        || !whole.bytes().all(|c| c.is_ascii_digit()) || !frac.bytes().all(|c| c.is_ascii_digit())
        || (s.contains('.') && frac.is_empty())
    {
        return err("enter an amount like 12.5");
    }
    let whole: u64 = whole.parse().map_err(|_| Error("amount too large".into()))?;
    let frac: u64 = format!("{frac:0<8}").parse().expect("digits");
    whole.checked_mul(KOINU).and_then(|w| w.checked_add(frac)).ok_or(Error("amount too large".into()))
}

/// Formats koinu as DOGE, without trailing zeros.
pub fn format_doge(koinu: u64) -> String {
    let frac = format!("{:08}", koinu % KOINU);
    let frac = frac.trim_end_matches('0');
    if frac.is_empty() {
        (koinu / KOINU).to_string()
    } else {
        format!("{}.{}", koinu / KOINU, frac)
    }
}

// --- transactions ----------------------------------------------------------------

struct TxIn {
    txid: [u8; 32], // as displayed (big-endian)
    vout: u32,
    script: Vec<u8>,
}

struct TxOut {
    value: u64,
    script: Vec<u8>,
}

struct Tx {
    inputs: Vec<TxIn>,
    outputs: Vec<TxOut>,
}

fn varint(n: usize, out: &mut Vec<u8>) {
    if n < 0xfd {
        out.push(n as u8);
    } else if n <= 0xffff {
        out.push(0xfd);
        out.extend_from_slice(&(n as u16).to_le_bytes());
    } else {
        out.push(0xfe);
        out.extend_from_slice(&(n as u32).to_le_bytes());
    }
}

impl Tx {
    fn serialize(&self) -> Vec<u8> {
        let mut b = Vec::new();
        b.extend_from_slice(&1u32.to_le_bytes());
        varint(self.inputs.len(), &mut b);
        for i in &self.inputs {
            let mut id = i.txid;
            id.reverse();
            b.extend_from_slice(&id);
            b.extend_from_slice(&i.vout.to_le_bytes());
            varint(i.script.len(), &mut b);
            b.extend_from_slice(&i.script);
            b.extend_from_slice(&0xffff_ffffu32.to_le_bytes());
        }
        varint(self.outputs.len(), &mut b);
        for o in &self.outputs {
            b.extend_from_slice(&o.value.to_le_bytes());
            varint(o.script.len(), &mut b);
            b.extend_from_slice(&o.script);
        }
        b.extend_from_slice(&0u32.to_le_bytes());
        b
    }

    /// Legacy SIGHASH_ALL: the input being signed carries the script it
    /// spends, the others none.
    fn sighash(&self, index: usize, prev_script: &[u8]) -> [u8; 32] {
        let copy = Tx {
            inputs: self.inputs.iter().enumerate().map(|(n, i)| TxIn {
                txid: i.txid,
                vout: i.vout,
                script: if n == index { prev_script.to_vec() } else { Vec::new() },
            }).collect(),
            outputs: self.outputs.iter().map(|o| TxOut { value: o.value, script: o.script.clone() }).collect(),
        };
        let mut data = copy.serialize();
        data.extend_from_slice(&1u32.to_le_bytes());
        sha256d(&data)
    }
}

/// A transaction id, as displayed: the double SHA-256, byte-reversed.
pub fn txid(raw: &[u8]) -> String {
    let mut h = sha256d(raw);
    h.reverse();
    hex::encode(h)
}

/// Reads the outputs of a legacy transaction.
fn parse_outputs(raw: &[u8]) -> Result<Vec<TxOut>> {
    let mut i = 4usize;
    let need = |i: usize, n: usize| if i + n > raw.len() { err("truncated transaction") } else { Ok(()) };
    let read_varint = |i: &mut usize| -> Result<usize> {
        need(*i, 1)?;
        let b = raw[*i];
        *i += 1;
        Ok(match b {
            0xfd => { need(*i, 2)?; let v = u16::from_le_bytes([raw[*i], raw[*i + 1]]) as usize; *i += 2; v }
            0xfe => { need(*i, 4)?; let v = u32::from_le_bytes(raw[*i..*i + 4].try_into().unwrap()) as usize; *i += 4; v }
            0xff => return err("transaction too large"),
            b => b as usize,
        })
    };
    let inputs = read_varint(&mut i)?;
    for _ in 0..inputs {
        need(i, 36)?;
        i += 36;
        let len = read_varint(&mut i)?;
        need(i, len + 4)?;
        i += len + 4;
    }
    let count = read_varint(&mut i)?;
    let mut outs = Vec::with_capacity(count);
    for _ in 0..count {
        need(i, 8)?;
        let value = u64::from_le_bytes(raw[i..i + 8].try_into().unwrap());
        i += 8;
        let len = read_varint(&mut i)?;
        need(i, len)?;
        outs.push(TxOut { value, script: raw[i..i + len].to_vec() });
        i += len;
    }
    Ok(outs)
}

/// An unspent output as the server lists it. Its value is only a claim: the
/// value signed for comes from the verified transaction that created it.
#[derive(Debug, Clone, serde::Deserialize)]
pub struct Utxo {
    pub txid: String,
    pub vout: u32,
    pub value: String,
    pub script: String,
    pub confirmations: i64,
}

pub struct Payment {
    pub hex: String,
    pub txid: String,
    pub fee: u64,
}

/// Spends `key`'s P2PKH outputs to pay `amount` to `script`, with an optional
/// OP_RETURN. `raw_txs` maps each utxo's txid to the transaction's hex, from
/// which each input's value and script are taken after checking the hex
/// hashes to the txid: legacy signatures do not commit to the amounts they
/// spend, so a server lying about a value could otherwise turn it into fee.
pub fn build_payment(
    key: &Key,
    utxos: &[Utxo],
    raw_txs: &HashMap<String, String>,
    script: &[u8],
    amount: u64,
    data: Option<&[u8]>,
) -> Result<Payment> {
    if amount < HARD_DUST {
        return err(format!("the smallest payment is {} DOGE", format_doge(HARD_DUST)));
    }
    let from_script = key.destination().pk_script();
    let from_hex = hex::encode(&from_script);
    let mut spendable: Vec<(u64, &Utxo)> = utxos
        .iter()
        .filter(|u| u.confirmations > 0 && u.script == from_hex)
        .map(|u| (u.value.parse::<u64>().unwrap_or(0), u))
        .collect();
    // Largest first, by the server's claimed value (as chain.js does).
    spendable.sort_by(|a, b| b.0.cmp(&a.0));

    let mut outputs = vec![TxOut { value: amount, script: script.to_vec() }];
    if let Some(d) = data {
        outputs.push(TxOut { value: 0, script: [&[0x6a][..], &push_data(d)?].concat() });
    }
    let dust_fee = if amount < SOFT_DUST { SOFT_DUST } else { 0 };

    let mut inputs: Vec<([u8; 32], u32, u64)> = Vec::new();
    let mut total = 0u64;
    let mut fee = 0u64;
    for (_, u) in spendable {
        let raw = hex::decode(raw_txs.get(&u.txid).ok_or(Error(format!("no transaction {}", u.txid)))?)
            .map_err(|_| Error("transaction is not hex".into()))?;
        if txid(&raw) != u.txid {
            return err(format!("the server sent the wrong transaction for {}", u.txid));
        }
        let outs = parse_outputs(&raw)?;
        let out = outs.get(u.vout as usize).ok_or(Error(format!("transaction {} has no output {}", u.txid, u.vout)))?;
        if out.script != from_script {
            return err(format!("output {}:{} is not yours", u.txid, u.vout));
        }
        let mut id = [0u8; 32];
        id.copy_from_slice(&hex::decode(&u.txid).map_err(|_| Error("bad txid".into()))?);
        inputs.push((id, u.vout, out.value));
        total += out.value;
        let size = 10 + 149 * inputs.len() + 34 * (outputs.len() + 1) + data.map_or(0, |d| d.len() + 3);
        fee = size as u64 * FEE_PER_BYTE + dust_fee;
        if total >= amount + fee {
            break;
        }
    }
    if total < amount + fee {
        return err(format!(
            "not enough confirmed DOGE: have {}, need {} including the fee",
            format_doge(total), format_doge(amount + fee)
        ));
    }
    let change = total - amount - fee;
    if change >= SOFT_DUST {
        outputs.push(TxOut { value: change, script: from_script.clone() });
    } else {
        fee += change;
    }
    if fee > MAX_FEE {
        return err(format!("the fee would be {} DOGE; refusing to sign", format_doge(fee)));
    }

    let mut tx = Tx {
        inputs: inputs.iter().map(|(id, vout, _)| TxIn { txid: *id, vout: *vout, script: Vec::new() }).collect(),
        outputs,
    };
    let signing = key.signing_key();
    let public = key.public_key();
    for i in 0..tx.inputs.len() {
        let hash = tx.sighash(i, &from_script);
        let sig: Signature = signing.sign_prehash(&hash).map_err(|e| Error(e.to_string()))?;
        let sig = sig.normalize_s().unwrap_or(sig);
        let mut der = sig.to_der().as_bytes().to_vec();
        der.push(1); // SIGHASH_ALL
        tx.inputs[i].script = [push_data(&der)?, push_data(&public)?].concat();
    }
    let raw = tx.serialize();
    Ok(Payment { txid: txid(&raw), hex: hex::encode(raw), fee })
}
