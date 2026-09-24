//! The core must reproduce the web wallet's vectors byte for byte. The
//! vectors come from dogecoin-vm (cmd/dogevm/testdata/wallet-vectors.json),
//! where the DogecoinVM Go code and btcd's script engine verify them; copy a
//! new version here with scripts/sync-vectors.sh.

use dogevm_wallet_core::*;
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::collections::HashMap;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Vectors {
    versions: Versions,
    keys: Vec<KeyVector>,
    deposit: DepositVector,
    reserve_script: String,
    payments: Vec<PaymentVector>,
}

#[derive(Deserialize)]
struct KeyVector {
    label: String,
    hash160: String,
    address: String,
    wif: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DepositVector {
    signers: Signers,
    dest: DestVector,
    redeem_script: String,
    address: String,
}

#[derive(Deserialize)]
struct DestVector {
    hash160: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PaymentVector {
    name: String,
    from_label: String,
    prev_tx: String,
    utxos: Vec<Utxo>,
    to_script: String,
    amount: String,
    data: String,
    tx: String,
    txid: String,
    fee: String,
}

fn vectors() -> Vectors {
    serde_json::from_str(include_str!("vectors/wallet-vectors.json")).expect("vectors parse")
}

fn key_for(label: &str) -> Key {
    Key::from_bytes(&Sha256::digest(label.as_bytes())).unwrap()
}

#[test]
fn keys_and_addresses() {
    let v = vectors();
    assert_eq!(v.versions, MAINNET);
    for k in &v.keys {
        let key = key_for(&k.label);
        assert_eq!(hex::encode(key.destination().hash), k.hash160, "{}", k.label);
        assert_eq!(key.destination().address(MAINNET), k.address, "{}", k.label);
        assert_eq!(key.wif(MAINNET).as_str(), k.wif, "{}", k.label);
        // The WIF parses back to the same key.
        assert_eq!(Key::parse(&k.wif).unwrap().bytes(), key.bytes());
        assert_eq!(decode_address(&k.address, MAINNET).unwrap(), key.destination());
    }
}

#[test]
fn deposit_address_matches() {
    let v = vectors();
    let mut hash = [0u8; 20];
    hash.copy_from_slice(&hex::decode(&v.deposit.dest.hash160).unwrap());
    let dest = Destination { kind: 0, hash };
    assert_eq!(hex::encode(deposit_redeem_script(&dest, &v.deposit.signers).unwrap()), v.deposit.redeem_script);
    assert_eq!(deposit_address(&dest, &v.deposit.signers, MAINNET).unwrap(), v.deposit.address);
    // The reserve (peg) script is P2SH of the bare multisig; a deposit
    // address is P2SH of its redeem script.
    let deposit = decode_address(&v.deposit.address, MAINNET).unwrap();
    assert_eq!(deposit.kind, 1);
    assert!(v.reserve_script.starts_with("a914"));
}

#[test]
fn payments_match_byte_for_byte() {
    let v = vectors();
    for p in &v.payments {
        let key = key_for(&p.from_label);
        let raw: HashMap<String, String> = p.utxos.iter().map(|u| (u.txid.clone(), p.prev_tx.clone())).collect();
        let data = if p.data.is_empty() { None } else { Some(hex::decode(&p.data).unwrap()) };
        let got = build_payment(
            &key, &p.utxos, &raw, &hex::decode(&p.to_script).unwrap(),
            p.amount.parse().unwrap(), data.as_deref(),
        ).unwrap_or_else(|e| panic!("{}: {e}", p.name));
        assert_eq!(got.hex, p.tx, "{}", p.name);
        assert_eq!(got.txid, p.txid, "{}", p.name);
        assert_eq!(got.fee.to_string(), p.fee, "{}", p.name);
    }
}

#[test]
fn a_lying_server_changes_nothing() {
    let v = vectors();
    let p = &v.payments[0];
    let key = key_for(&p.from_label);
    let raw: HashMap<String, String> = p.utxos.iter().map(|u| (u.txid.clone(), p.prev_tx.clone())).collect();
    let mut inflated = p.utxos.clone();
    inflated[0].value = "999999999999999".into();
    let got = build_payment(&key, &inflated, &raw, &hex::decode(&p.to_script).unwrap(), p.amount.parse().unwrap(), None).unwrap();
    assert_eq!(got.hex, p.tx, "the value comes from the verified transaction");

    let wrong: HashMap<String, String> = p.utxos.iter().map(|u| (u.txid.clone(), v.payments[1].prev_tx.clone())).collect();
    let e = build_payment(&key, &p.utxos, &wrong, &hex::decode(&p.to_script).unwrap(), p.amount.parse().unwrap(), None);
    assert!(e.is_err_and(|e| e.0.contains("wrong transaction")));
}

#[test]
fn keys_and_amounts_refuse_bad_input() {
    // The Bitcoin wiki's example WIF (uncompressed), public for years. Split so
    // key scanners, including Antelope ones that read the same format, don't
    // take it for a leaked key.
    let textbook = concat!("5HueCGU8rMjxEXxiPuD5", "BDku4MkFqeZyd4dZ1jvhTVqvbTLvyTJ");
    assert!(Key::parse(textbook).is_err_and(|e| e.0.contains("uncompressed")));
    assert!(Key::parse(&"00".repeat(32)).is_err());
    assert!(Key::parse("not a key").is_err());
    assert_eq!(parse_doge("12.5").unwrap(), 1_250_000_000);
    assert_eq!(parse_doge("0.00000001").unwrap(), 1);
    assert!(parse_doge("1.").is_err());
    assert!(parse_doge("1.123456789").is_err());
    assert!(parse_doge("-1").is_err());
    assert_eq!(format_doge(1_250_000_000), "12.5");
    assert_eq!(format_doge(100_000_000), "1");
    let fresh = Key::generate();
    assert_eq!(Key::parse(&hex::encode(fresh.bytes())).unwrap().bytes(), fresh.bytes());
}
