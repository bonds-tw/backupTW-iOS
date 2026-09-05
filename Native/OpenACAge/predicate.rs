//! A narrow, production-facing OpenAC profile for age predicates over SD-JWT.
//!
//! The generic mobile bindings expose file-oriented circuit operations. That is
//! useful for benchmarks, but leaving every wallet to reproduce the TypeScript
//! SDK's byte padding, disclosure anchors and public-statement layout is a
//! security boundary disguised as glue code. This module keeps that boundary
//! beside the circuits and exports only the one policy the wallet currently
//! promises: a signed birth-date claim is at or before a verifier-supplied
//! cutoff date.

use super::{make_config, ZkProofError};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use chrono::NaiveDate;
use ecdsa_spartan2::{
    load_proof, load_verifying_key, load_witness,
    paths::keys::{
        PREPARE_PROOF, PREPARE_VERIFYING_KEY, PREPARE_WITNESS, SHOW_PROOF, SHOW_VERIFYING_KEY,
    },
    prover::verify_linked,
    utils::bigint_to_scalar,
    Scalar,
};
use ff::PrimeField;
use num_bigint::{BigInt, BigUint};
use num_traits::Num;
use p256::ecdsa::{signature::Verifier, Signature, VerifyingKey};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    fs,
    path::PathBuf,
    time::{SystemTime, UNIX_EPOCH},
};

const MAX_MESSAGE_LENGTH: usize = 2048;
const MAX_B64_PAYLOAD_LENGTH: usize = 2000;
const MAX_MATCHES: usize = 4;
const MAX_SUBSTRING_LENGTH: usize = 50;
const MAX_CLAIM_LENGTH: usize = 128;
const CLAIM_SLOTS: usize = 2;
const NAME_ID_LENGTH: usize = 31;
const P256_ORDER_HEX: &str = "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551";
const BIRTH_CLAIM_NAMES: &[&str] = &[
    "roc_birthday",
    "birthdate",
    "birthday",
    "date_of_birth",
    "birth_date",
    "出生日期",
];

#[derive(Debug)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct AgePrepareInput {
    pub claim_name: String,
    /// Circuit format: 2 = ISO YYYY-MM-DD; 3 = Taiwan ROC YYYMMDD.
    pub claim_format: u8,
}

#[derive(Debug)]
struct BirthDisclosure {
    raw: String,
    name: String,
    digest: String,
    format: u8,
}

fn invalid(message: impl Into<String>) -> ZkProofError {
    ZkProofError::InvalidInput {
        message: message.into(),
    }
}

fn io_error(message: impl Into<String>) -> ZkProofError {
    ZkProofError::IoError {
        message: message.into(),
    }
}

fn decode_url(value: &str, what: &str) -> Result<Vec<u8>, ZkProofError> {
    URL_SAFE_NO_PAD
        .decode(value)
        .map_err(|_| invalid(format!("invalid base64url {what}")))
}

fn bigint_decimal(bytes: &[u8]) -> String {
    BigUint::from_bytes_be(bytes).to_str_radix(10)
}

fn scalar_decimal(value: &Scalar) -> String {
    BigUint::from_bytes_le(value.to_repr().as_ref()).to_str_radix(10)
}

fn decimal_scalar(value: impl AsRef<str>) -> Result<Scalar, ZkProofError> {
    let integer = BigInt::from_str_radix(value.as_ref(), 10)
        .map_err(|_| invalid("invalid decimal field element"))?;
    bigint_to_scalar(integer)
        .map_err(|_| invalid("field element is outside the P-256 scalar field"))
}

fn p256_order() -> BigUint {
    BigUint::from_str_radix(P256_ORDER_HEX, 16).expect("constant P-256 order")
}

fn signature_parts(raw: &[u8]) -> Result<(String, String, Signature), ZkProofError> {
    let signature =
        Signature::from_slice(raw).map_err(|_| invalid("signature is not compact ES256"))?;
    let inverse = Option::<p256::Scalar>::from(signature.s().invert())
        .ok_or_else(|| invalid("signature s has no inverse"))?;
    Ok((
        bigint_decimal(signature.r().to_bytes().as_ref()),
        bigint_decimal(inverse.to_bytes().as_ref()),
        signature,
    ))
}

fn verifying_key(x: &[u8], y: &[u8]) -> Result<VerifyingKey, ZkProofError> {
    if x.len() != 32 || y.len() != 32 {
        return Err(invalid("P-256 coordinates must each be 32 bytes"));
    }
    let mut point = Vec::with_capacity(65);
    point.push(4);
    point.extend_from_slice(x);
    point.extend_from_slice(y);
    VerifyingKey::from_sec1_bytes(&point).map_err(|_| invalid("P-256 point is invalid"))
}

fn occurrences(haystack: &str, needle: &str) -> usize {
    haystack.match_indices(needle).count()
}

fn padded_bytes(bytes: &[u8], maximum: usize) -> Result<(Vec<u8>, usize), ZkProofError> {
    let mut padded_len = bytes.len() + 1 + 8;
    padded_len = ((padded_len + 63) / 64) * 64;
    if padded_len > maximum {
        return Err(invalid(format!(
            "signed input needs {padded_len} bytes; circuit limit is {maximum}"
        )));
    }
    let mut output = vec![0u8; maximum];
    output[..bytes.len()].copy_from_slice(bytes);
    output[bytes.len()] = 0x80;
    let bit_len = (bytes.len() as u64) * 8;
    output[padded_len - 8..padded_len].copy_from_slice(&bit_len.to_be_bytes());
    Ok((output, padded_len))
}

fn json_strings(bytes: impl IntoIterator<Item = u8>) -> Vec<String> {
    bytes.into_iter().map(|v| v.to_string()).collect()
}

fn padded_ascii(value: &str, width: usize) -> Result<Vec<String>, ZkProofError> {
    let bytes = value.as_bytes();
    if bytes.len() > width {
        return Err(invalid(format!("value exceeds {width}-byte circuit slot")));
    }
    let mut out = vec![0u8; width];
    out[..bytes.len()].copy_from_slice(bytes);
    Ok(json_strings(out))
}

fn parse_birth_disclosure(
    serialized: &str,
    sd_digests: &[String],
) -> Result<BirthDisclosure, ZkProofError> {
    let mut matches = Vec::new();
    for raw in serialized
        .split('~')
        .skip(1)
        .filter(|part| !part.is_empty() && !part.contains('.'))
    {
        let decoded = decode_url(raw, "disclosure")?;
        let decoded_text =
            std::str::from_utf8(&decoded).map_err(|_| invalid("disclosure is not UTF-8"))?;
        if decoded_text.contains('\\') {
            return Err(invalid(
                "birth disclosure contains a JSON escape unsupported by the circuit",
            ));
        }
        let value: Value =
            serde_json::from_slice(&decoded).map_err(|_| invalid("disclosure is not JSON"))?;
        let array = value
            .as_array()
            .ok_or_else(|| invalid("disclosure is not an array"))?;
        if array.len() < 3 {
            continue;
        }
        let Some(name) = array[1].as_str() else {
            continue;
        };
        if !BIRTH_CLAIM_NAMES.contains(&name) {
            continue;
        }
        let Some(claim_value) = array[2].as_str() else {
            return Err(invalid("birth-date disclosure is not a string"));
        };
        let format = if claim_value.len() == 10
            && claim_value.as_bytes().get(4) == Some(&b'-')
            && claim_value.as_bytes().get(7) == Some(&b'-')
            && claim_value
                .chars()
                .enumerate()
                .all(|(i, c)| i == 4 || i == 7 || c.is_ascii_digit())
        {
            NaiveDate::parse_from_str(claim_value, "%Y-%m-%d")
                .map_err(|_| invalid("birth date is not a real calendar date"))?;
            2
        } else if claim_value.len() == 7 && claim_value.chars().all(|c| c.is_ascii_digit()) {
            let roc_year: i32 = claim_value[0..3]
                .parse()
                .map_err(|_| invalid("ROC birth year is invalid"))?;
            let month: u32 = claim_value[3..5]
                .parse()
                .map_err(|_| invalid("ROC birth month is invalid"))?;
            let day: u32 = claim_value[5..7]
                .parse()
                .map_err(|_| invalid("ROC birth day is invalid"))?;
            NaiveDate::from_ymd_opt(roc_year + 1911, month, day)
                .ok_or_else(|| invalid("ROC birth date is not a real calendar date"))?;
            3
        } else {
            return Err(invalid("birth date must be YYYY-MM-DD or YYYMMDD"));
        };
        if name.as_bytes().len() > NAME_ID_LENGTH {
            return Err(invalid("birth-date field name is too long for the circuit"));
        }
        let digest = URL_SAFE_NO_PAD.encode(Sha256::digest(raw.as_bytes()));
        if !sd_digests.iter().any(|item| item == &digest) {
            return Err(invalid(
                "birth disclosure digest is not in the signed _sd array",
            ));
        }
        matches.push(BirthDisclosure {
            raw: raw.to_owned(),
            name: name.to_owned(),
            digest,
            format,
        });
    }
    match matches.len() {
        0 => Err(invalid("credential has no supported birth-date disclosure")),
        1 => Ok(matches.remove(0)),
        _ => Err(invalid(
            "credential has more than one supported birth-date disclosure",
        )),
    }
}

/// Validate an ES256 SD-JWT and write the exact Prepare-circuit input file.
#[cfg_attr(feature = "uniffi", uniffi::export)]
pub fn create_age_prepare_input(
    documents_path: String,
    sd_jwt: String,
    issuer_key_x: String,
    issuer_key_y: String,
) -> Result<AgePrepareInput, ZkProofError> {
    let jwt = sd_jwt
        .split('~')
        .next()
        .ok_or_else(|| invalid("missing JWT"))?;
    let segments: Vec<&str> = jwt.split('.').collect();
    if segments.len() != 3 {
        return Err(invalid("credential JWT must have three segments"));
    }
    let header: Value = serde_json::from_slice(&decode_url(segments[0], "JWT header")?)
        .map_err(|_| invalid("JWT header is not JSON"))?;
    if header.get("alg").and_then(Value::as_str) != Some("ES256") {
        return Err(invalid("credential JWT is not ES256"));
    }
    if let Some(typ) = header.get("typ").and_then(Value::as_str) {
        if !["vc+sd-jwt", "dc+sd-jwt", "JWT"].contains(&typ) {
            return Err(invalid("credential JWT typ is unsupported"));
        }
    }
    if header.get("crit").is_some() {
        return Err(invalid("credential JWT crit header is unsupported"));
    }

    let payload_bytes = decode_url(segments[1], "JWT payload")?;
    let payload_text =
        std::str::from_utf8(&payload_bytes).map_err(|_| invalid("JWT payload is not UTF-8"))?;
    if segments[1].len() > MAX_B64_PAYLOAD_LENGTH {
        return Err(invalid("JWT payload exceeds the 2k OpenAC profile"));
    }
    let payload: Value =
        serde_json::from_slice(&payload_bytes).map_err(|_| invalid("JWT payload is not JSON"))?;
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| invalid("clock is unavailable"))?
        .as_secs();
    if payload.get("exp").is_some() && payload.get("exp").and_then(Value::as_u64).is_none() {
        return Err(invalid("credential exp is not an integer timestamp"));
    }
    if let Some(exp) = payload.get("exp").and_then(Value::as_u64) {
        if now >= exp.saturating_add(60) {
            return Err(invalid("credential is expired"));
        }
    }
    if payload.get("nbf").is_some() && payload.get("nbf").and_then(Value::as_u64).is_none() {
        return Err(invalid("credential nbf is not an integer timestamp"));
    }
    if let Some(nbf) = payload.get("nbf").and_then(Value::as_u64) {
        if now.saturating_add(60) < nbf {
            return Err(invalid("credential is not valid yet"));
        }
    }

    let credential_subject = payload
        .pointer("/vc/credentialSubject")
        .and_then(Value::as_object)
        .ok_or_else(|| invalid("credential has no vc.credentialSubject"))?;
    if let Some(algorithm) = credential_subject.get("_sd_alg").and_then(Value::as_str) {
        if algorithm != "sha-256" {
            return Err(invalid("credential uses an unsupported _sd_alg"));
        }
    }
    let sd_digests: Vec<String> = credential_subject
        .get("_sd")
        .and_then(Value::as_array)
        .ok_or_else(|| invalid("credential has no _sd array"))?
        .iter()
        .map(|v| {
            v.as_str()
                .map(str::to_owned)
                .ok_or_else(|| invalid("_sd digest is not text"))
        })
        .collect::<Result<_, _>>()?;
    let birth = parse_birth_disclosure(&sd_jwt, &sd_digests)?;

    if payload.pointer("/cnf/jwk/kty").and_then(Value::as_str) != Some("EC")
        || payload.pointer("/cnf/jwk/crv").and_then(Value::as_str) != Some("P-256")
    {
        return Err(invalid("credential cnf.jwk is not an EC P-256 key"));
    }
    let device_x = payload
        .pointer("/cnf/jwk/x")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid("credential has no cnf.jwk.x"))?;
    let device_y = payload
        .pointer("/cnf/jwk/y")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid("credential has no cnf.jwk.y"))?;
    let x_anchor = "\"x\":\"";
    let y_anchor = "\"y\":\"";
    if occurrences(payload_text, x_anchor) != 1
        || occurrences(payload_text, y_anchor) != 1
        || occurrences(payload_text, "\"_sd\":[") != 1
        || occurrences(payload_text, &birth.digest) != 1
    {
        return Err(invalid("signed payload has ambiguous OpenAC anchors"));
    }
    let x_index = payload_text
        .find(x_anchor)
        .ok_or_else(|| invalid("missing x anchor"))?;
    let y_index = payload_text
        .find(y_anchor)
        .ok_or_else(|| invalid("missing y anchor"))?;
    if !payload_text[x_index + x_anchor.len()..].starts_with(device_x)
        || !payload_text[y_index + y_anchor.len()..].starts_with(device_y)
    {
        return Err(invalid(
            "cnf.jwk coordinates do not follow their signed anchors",
        ));
    }

    let issuer_x = decode_url(&issuer_key_x, "issuer x")?;
    let issuer_y = decode_url(&issuer_key_y, "issuer y")?;
    let verifier = verifying_key(&issuer_x, &issuer_y)?;
    let raw_signature = decode_url(segments[2], "credential signature")?;
    let (sig_r, sig_s_inverse, signature) = signature_parts(&raw_signature)?;
    let signing_input = format!("{}.{}", segments[0], segments[1]);
    verifier
        .verify(signing_input.as_bytes(), &signature)
        .map_err(|_| invalid("credential issuer signature is invalid"))?;
    let (padded_message, padded_len) = padded_bytes(signing_input.as_bytes(), MAX_MESSAGE_LENGTH)?;

    let mut match_substrings = vec![
        padded_ascii(x_anchor, MAX_SUBSTRING_LENGTH)?,
        padded_ascii(y_anchor, MAX_SUBSTRING_LENGTH)?,
        padded_ascii(&birth.digest, MAX_SUBSTRING_LENGTH)?,
    ];
    let mut match_lengths = vec![x_anchor.len(), y_anchor.len(), birth.digest.len()];
    let mut match_indices = vec![x_index, y_index, payload_text.find(&birth.digest).unwrap()];
    while match_substrings.len() < MAX_MATCHES {
        match_substrings.push(padded_ascii("", MAX_SUBSTRING_LENGTH)?);
        match_lengths.push(0);
        match_indices.push(0);
    }
    let (claim_padded, _) = padded_bytes(birth.raw.as_bytes(), MAX_CLAIM_LENGTH)?;
    let mut claims = vec![
        json_strings(claim_padded),
        vec!["0".to_owned(); MAX_CLAIM_LENGTH],
    ];
    claims.truncate(CLAIM_SLOTS);
    let input = json!({
        "sig_r": sig_r,
        "sig_s_inverse": sig_s_inverse,
        "pubKeyX": bigint_decimal(&issuer_x),
        "pubKeyY": bigint_decimal(&issuer_y),
        "message": json_strings(padded_message),
        "messageLength": padded_len,
        "periodIndex": segments[0].len(),
        "matchesCount": 3,
        "matchSubstring": match_substrings,
        "matchLength": match_lengths,
        "matchIndex": match_indices,
        "claims": claims,
        "claimLengths": [birth.raw.len().to_string(), "0".to_owned()],
        "decodeFlags": [1, 0],
        "claimFormats": [birth.format.to_string(), "1".to_owned()],
    });
    fs::create_dir_all(&documents_path).map_err(|e| io_error(e.to_string()))?;
    fs::write(
        PathBuf::from(&documents_path).join("jwt_input.json"),
        serde_json::to_vec(&input).unwrap(),
    )
    .map_err(|e| io_error(e.to_string()))?;
    Ok(AgePrepareInput {
        claim_name: birth.name,
        claim_format: birth.format,
    })
}

/// Read the private values authenticated by Prepare and write the bound Show input.
#[cfg_attr(feature = "uniffi", uniffi::export)]
pub fn create_age_show_input(
    documents_path: String,
    nonce: String,
    device_signature: String,
    claim_name: String,
    claim_format: u8,
    cutoff: u64,
) -> Result<(), ZkProofError> {
    if nonce.as_bytes().len() < 16 {
        return Err(invalid("verifier nonce is too short"));
    }
    if claim_name.as_bytes().len() > NAME_ID_LENGTH
        || !BIRTH_CLAIM_NAMES.contains(&claim_name.as_str())
    {
        return Err(invalid("claim is not a supported birth-date field"));
    }
    if ![2, 3].contains(&claim_format) {
        return Err(invalid("age claim format must be ISO or ROC date"));
    }
    let config = make_config(&documents_path);
    let witness = load_witness(config.artifact_path(PREPARE_WITNESS))
        .map_err(|e| invalid(format!("prepare witness is unavailable: {e}")))?;
    // Spartan stores the explicitly shared partition first, in exactly the
    // order `PrepareCircuit::shared()` allocates it: device x/y, two normalized
    // claim values, then two claim-name hashes. These are private values; they
    // are read only on the holder to construct Show and never packaged.
    if witness.W.len() < 2 + 2 * CLAIM_SLOTS {
        return Err(invalid("prepare witness has no complete shared partition"));
    }
    let device_x_scalar = witness.W[0];
    let device_y_scalar = witness.W[1];
    let claim_values: Vec<String> = witness.W[2..2 + CLAIM_SLOTS]
        .iter()
        .map(scalar_decimal)
        .collect();
    let identifiers: Vec<String> = witness.W[2 + CLAIM_SLOTS..2 + 2 * CLAIM_SLOTS]
        .iter()
        .map(scalar_decimal)
        .collect();
    let device_x_bytes = device_x_scalar.to_repr();
    let device_y_bytes = device_y_scalar.to_repr();
    let mut x_be = device_x_bytes.as_ref().to_vec();
    x_be.reverse();
    let mut y_be = device_y_bytes.as_ref().to_vec();
    y_be.reverse();
    let verifier = verifying_key(&x_be, &y_be)?;
    let raw_signature = decode_url(&device_signature, "device signature")?;
    let (sig_r, sig_s_inverse, signature) = signature_parts(&raw_signature)?;
    verifier
        .verify(nonce.as_bytes(), &signature)
        .map_err(|_| invalid("device signature does not answer this verifier nonce"))?;

    let message_hash = BigUint::from_bytes_be(&Sha256::digest(nonce.as_bytes())) % p256_order();
    let mut lhs_name = vec![vec!["0".to_owned(); NAME_ID_LENGTH]; 2];
    for (index, byte) in claim_name.as_bytes().iter().enumerate() {
        lhs_name[0][index] = byte.to_string();
    }
    let input = json!({
        "deviceKeyX": scalar_decimal(&device_x_scalar),
        "deviceKeyY": scalar_decimal(&device_y_scalar),
        "sig_r": sig_r,
        "sig_s_inverse": sig_s_inverse,
        "messageHash": message_hash.to_str_radix(10),
        "predicateLen": "1",
        "claimValues": claim_values,
        "claimIdentifierHashes": identifiers,
        "predicateClaimRefs": ["0", "0"],
        "predicateOps": ["0", "2"],
        "predicateRhsIsRef": ["0", "0"],
        "predicateRhsValues": [cutoff.to_string(), "0".to_owned()],
        "predicateClaimNames": lhs_name,
        "predicateClaimNameLens": [claim_name.as_bytes().len().to_string(), "0".to_owned()],
        "predicateRhsClaimNames": [vec!["0".to_owned(); NAME_ID_LENGTH], vec!["0".to_owned(); NAME_ID_LENGTH]],
        "predicateRhsClaimNameLens": ["0", "0"],
        "tokenTypes": ["0", "0", "0", "0", "0", "0", "0", "0"],
        "tokenValues": ["0", "0", "0", "0", "0", "0", "0", "0"],
        "exprLen": "1",
    });
    fs::write(
        PathBuf::from(&documents_path).join("show_input.json"),
        serde_json::to_vec(&input).unwrap(),
    )
    .map_err(|e| io_error(e.to_string()))?;
    Ok(())
}

fn expected_show_values(
    nonce: &str,
    claim_name: &str,
    cutoff: u64,
) -> Result<Vec<Scalar>, ZkProofError> {
    let mut decimal = Vec::<String>::new();
    decimal.push("1".to_owned());
    decimal.push(
        (BigUint::from_bytes_be(&Sha256::digest(nonce.as_bytes())) % p256_order()).to_str_radix(10),
    );
    decimal.push("1".to_owned());
    decimal.extend(
        ["0", "0", "0", "2", "0", "0"]
            .into_iter()
            .map(str::to_owned),
    );
    decimal.extend([cutoff.to_string(), "0".to_owned()]);
    decimal.extend(claim_name.as_bytes().iter().map(u8::to_string));
    decimal.extend(
        std::iter::repeat("0".to_owned()).take(NAME_ID_LENGTH - claim_name.as_bytes().len()),
    );
    decimal.extend(std::iter::repeat("0".to_owned()).take(NAME_ID_LENGTH));
    decimal.extend([claim_name.as_bytes().len().to_string(), "0".to_owned()]);
    decimal.extend(std::iter::repeat("0".to_owned()).take(NAME_ID_LENGTH * 2));
    decimal.extend(["0", "0"].into_iter().map(str::to_owned));
    decimal.extend(std::iter::repeat("0".to_owned()).take(8));
    decimal.extend(std::iter::repeat("0".to_owned()).take(8));
    decimal.push("1".to_owned());
    decimal.into_iter().map(decimal_scalar).collect()
}

/// Verify both linked proofs, the exact nonce/predicate program, normalization,
/// and the independently expected issuer key. No package-supplied policy is trusted.
#[cfg_attr(feature = "uniffi", uniffi::export)]
pub fn verify_age_presentation(
    documents_path: String,
    nonce: String,
    claim_name: String,
    claim_format: u8,
    cutoff: u64,
    expected_issuer_key_x: String,
    expected_issuer_key_y: String,
) -> Result<bool, ZkProofError> {
    if nonce.as_bytes().len() < 16
        || claim_name.as_bytes().len() > NAME_ID_LENGTH
        || !BIRTH_CLAIM_NAMES.contains(&claim_name.as_str())
        || ![2, 3].contains(&claim_format)
    {
        return Err(invalid("invalid expected age statement"));
    }
    let config = make_config(&documents_path);
    let prepare_proof =
        load_proof(config.artifact_path(PREPARE_PROOF)).map_err(|e| invalid(e.to_string()))?;
    let show_proof =
        load_proof(config.artifact_path(SHOW_PROOF)).map_err(|e| invalid(e.to_string()))?;
    let prepare_vk = load_verifying_key(config.key_path(PREPARE_VERIFYING_KEY))
        .map_err(|e| invalid(e.to_string()))?;
    let show_vk = load_verifying_key(config.key_path(SHOW_VERIFYING_KEY))
        .map_err(|e| invalid(e.to_string()))?;
    let Some((prepare_public, show_public)) =
        verify_linked(&prepare_proof, &prepare_vk, &show_proof, &show_vk)
    else {
        return Ok(false);
    };
    let expected_x = decimal_scalar(bigint_decimal(&decode_url(
        &expected_issuer_key_x,
        "expected issuer x",
    )?))?;
    let expected_y = decimal_scalar(bigint_decimal(&decode_url(
        &expected_issuer_key_y,
        "expected issuer y",
    )?))?;
    let expected_prepare = vec![
        expected_x,
        expected_y,
        decimal_scalar("1")?,
        decimal_scalar("0")?,
        decimal_scalar(claim_format.to_string())?,
        decimal_scalar("1")?,
    ];
    if prepare_public != expected_prepare {
        return Ok(false);
    }
    Ok(show_public == expected_show_values(&nonce, &claim_name, cutoff)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn expected_age_statement_has_the_compiled_public_width() {
        let values = expected_show_values("0123456789abcdef", "roc_birthday", 970901).unwrap();
        assert_eq!(values.len(), 156);
    }

    #[test]
    fn arbitrary_claim_cannot_be_relabelled_as_a_birth_date() {
        let result = create_age_show_input(
            "/tmp/does-not-matter".to_owned(),
            "0123456789abcdef".to_owned(),
            "unused".to_owned(),
            "membership_started_at".to_owned(),
            2,
            20000101,
        );
        assert!(matches!(result, Err(ZkProofError::InvalidInput { .. })));
    }

    #[test]
    fn sha_padding_uses_a_real_block_length() {
        let (padded, length) = padded_bytes(b"abc", 128).unwrap();
        assert_eq!(length, 64);
        assert_eq!(padded[3], 0x80);
        assert_eq!(&padded[56..64], &(24u64.to_be_bytes()));
    }

    #[test]
    fn scalar_decimal_round_trips_the_curve_representation() {
        for decimal in ["0", "1", "255", "123456789012345678901234567890"] {
            let scalar = decimal_scalar(decimal).unwrap();
            assert_eq!(scalar_decimal(&scalar), decimal);
        }
    }

    #[test]
    fn invalid_calendar_dates_are_rejected() {
        let raw = URL_SAFE_NO_PAD.encode(br#"["salt","birthdate","2000-02-31"]"#);
        let digest = URL_SAFE_NO_PAD.encode(Sha256::digest(raw.as_bytes()));
        let credential = format!("x~{raw}~");
        assert!(parse_birth_disclosure(&credential, &[digest]).is_err());
    }
}
