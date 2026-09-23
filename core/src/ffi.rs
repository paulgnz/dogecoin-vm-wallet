//! C ABI for the macOS app: one JSON call.
//!
//! `dwc_call` takes a NUL-terminated JSON request `{"op": ..., ...}` and
//! returns a NUL-terminated JSON response, either the result or
//! `{"error": "..."}`. The caller frees it with `dwc_free`. Private keys cross
//! as hex in both directions; the app keeps them only in memory, briefly, and
//! stores them in its Secure Enclave–wrapped vault.

use crate::*;
use serde::Deserialize;
use serde_json::{json, Value};
use std::ffi::{CStr, CString};
use std::os::raw::c_char;

#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "camelCase")]
enum Request {
    /// A new random key.
    NewKey,
    /// A key typed or pasted by the user: hex, or a compressed WIF.
    ParseKey { text: String },
    /// A key's public details.
    KeyInfo { key: String, versions: Option<Versions> },
    /// A key's WIF, for backup.
    Wif { key: String, versions: Option<Versions> },
    DecodeAddress { address: String, versions: Option<Versions> },
    #[serde(rename_all = "camelCase")]
    DepositAddress { address: String, signers: Signers, versions: Option<Versions> },
    #[serde(rename_all = "camelCase")]
    PegOutData { address: String, versions: Option<Versions> },
    ParseDoge { text: String },
    FormatDoge { koinu: u64 },
    #[serde(rename_all = "camelCase")]
    BuildPayment {
        key: String,
        utxos: Vec<Utxo>,
        raw_txs: HashMap<String, String>,
        to_address: String,
        amount: String, // koinu
        data: Option<String>,
        versions: Option<Versions>,
    },
}

fn key_from_hex(h: &str) -> Result<Key> {
    let raw = zeroize::Zeroizing::new(hex::decode(h).map_err(|_| Error("key is not hex".into()))?);
    Key::from_bytes(&raw)
}

fn handle(req: Request) -> Result<Value> {
    Ok(match req {
        Request::NewKey => json!({ "key": hex::encode(Key::generate().bytes()) }),
        Request::ParseKey { text } => json!({ "key": hex::encode(Key::parse(&text)?.bytes()) }),
        Request::KeyInfo { key, versions } => {
            let v = versions.unwrap_or(MAINNET);
            let k = key_from_hex(&key)?;
            let dest = k.destination();
            json!({
                "address": dest.address(v),
                "publicKey": hex::encode(k.public_key()),
                "hash160": hex::encode(dest.hash),
                "script": hex::encode(dest.pk_script()),
            })
        }
        Request::Wif { key, versions } => {
            json!({ "wif": key_from_hex(&key)?.wif(versions.unwrap_or(MAINNET)).as_str() })
        }
        Request::DecodeAddress { address, versions } => {
            let d = decode_address(&address, versions.unwrap_or(MAINNET))?;
            json!({ "kind": d.kind, "hash160": hex::encode(d.hash), "script": hex::encode(d.pk_script()) })
        }
        Request::DepositAddress { address, signers, versions } => {
            let v = versions.unwrap_or(MAINNET);
            let dest = decode_address(&address, v)?;
            json!({
                "address": deposit_address(&dest, &signers, v)?,
                "redeemScript": hex::encode(deposit_redeem_script(&dest, &signers)?),
            })
        }
        Request::PegOutData { address, versions } => {
            json!({ "data": hex::encode(peg_out_data(&decode_address(&address, versions.unwrap_or(MAINNET))?)) })
        }
        Request::ParseDoge { text } => json!({ "koinu": parse_doge(&text)?.to_string() }),
        Request::FormatDoge { koinu } => json!({ "doge": format_doge(koinu) }),
        Request::BuildPayment { key, utxos, raw_txs, to_address, amount, data, versions } => {
            let v = versions.unwrap_or(MAINNET);
            let k = key_from_hex(&key)?;
            let to = decode_address(&to_address, v)?;
            let amount: u64 = amount.parse().map_err(|_| Error("amount must be koinu".into()))?;
            let data = match data {
                Some(d) if !d.is_empty() => Some(hex::decode(d).map_err(|_| Error("data is not hex".into()))?),
                _ => None,
            };
            let p = build_payment(&k, &utxos, &raw_txs, &to.pk_script(), amount, data.as_deref())?;
            json!({ "hex": p.hex, "txid": p.txid, "fee": p.fee.to_string() })
        }
    })
}

fn respond(v: Value) -> *mut c_char {
    CString::new(v.to_string()).expect("JSON has no NUL").into_raw()
}

/// # Safety
/// `request` must be a valid NUL-terminated string. Free the result with
/// `dwc_free`.
#[no_mangle]
pub unsafe extern "C" fn dwc_call(request: *const c_char) -> *mut c_char {
    if request.is_null() {
        return respond(json!({ "error": "no request" }));
    }
    let text = match CStr::from_ptr(request).to_str() {
        Ok(t) => t,
        Err(_) => return respond(json!({ "error": "request is not UTF-8" })),
    };
    match serde_json::from_str::<Request>(text) {
        Err(e) => respond(json!({ "error": format!("bad request: {e}") })),
        Ok(req) => match handle(req) {
            Ok(v) => respond(v),
            Err(e) => respond(json!({ "error": e.0 })),
        },
    }
}

/// Frees a string returned by `dwc_call`, wiping it first: responses can hold
/// a key.
///
/// # Safety
/// `s` must come from `dwc_call` and not be freed twice.
#[no_mangle]
pub unsafe extern "C" fn dwc_free(s: *mut c_char) {
    if s.is_null() {
        return;
    }
    let owned = CString::from_raw(s);
    let mut bytes = owned.into_bytes();
    zeroize::Zeroize::zeroize(&mut bytes);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call(req: Value) -> Value {
        let c = CString::new(req.to_string()).unwrap();
        unsafe {
            let out = dwc_call(c.as_ptr());
            let v: Value = serde_json::from_str(CStr::from_ptr(out).to_str().unwrap()).unwrap();
            dwc_free(out);
            v
        }
    }

    #[test]
    fn round_trips_through_json() {
        let k = call(json!({ "op": "newKey" }));
        let key = k["key"].as_str().unwrap();
        let info = call(json!({ "op": "keyInfo", "key": key }));
        assert!(info["address"].as_str().unwrap().starts_with('D'));
        let wif = call(json!({ "op": "wif", "key": key }));
        let back = call(json!({ "op": "parseKey", "text": wif["wif"] }));
        assert_eq!(back["key"], k["key"]);
        assert_eq!(call(json!({ "op": "parseDoge", "text": "1.5" }))["koinu"], "150000000");
        assert!(call(json!({ "op": "parseKey", "text": "nope" }))["error"].is_string());
        assert!(call(json!({ "op": "whatever" }))["error"].is_string());
    }
}
