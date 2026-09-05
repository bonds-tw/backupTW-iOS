//! Generates the immutable OpenAC age-profile keys and exercises the complete
//! linked proof before anything is published for the iOS app.

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use openac_age_mobile_app::{
    create_age_prepare_input, create_age_show_input, generate_shared_blinds, prove_jwt,
    prove_show, reblind_jwt, reblind_show, setup_jwt_keys, setup_show_keys,
    verify_age_presentation,
};
use p256::ecdsa::{signature::Signer, Signature, SigningKey};
use rand_core::OsRng;
use serde_json::json;
use sha2::{Digest, Sha256};
use std::{env, fs, os::unix::fs::symlink, path::PathBuf, time::Instant};

fn b64(bytes: impl AsRef<[u8]>) -> String {
    URL_SAFE_NO_PAD.encode(bytes)
}

fn coordinates(key: &SigningKey) -> (String, String) {
    let point = key.verifying_key().to_encoded_point(false);
    (b64(point.x().expect("P-256 x")), b64(point.y().expect("P-256 y")))
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = env::args_os().skip(1);
    let zkid = PathBuf::from(args.next().ok_or("usage: age_assets ZKID OUTPUT")?);
    let output = PathBuf::from(args.next().ok_or("usage: age_assets ZKID OUTPUT")?);
    if args.next().is_some() {
        return Err("usage: age_assets ZKID OUTPUT".into());
    }
    let documents = output.join("circom");
    let build = documents.join("build");
    fs::create_dir_all(documents.join("keys"))?;
    fs::create_dir_all(&build)?;
    for (source, destination) in [
        (
            zkid.join("wallet-unit-poc/circom/build/jwt_2k/jwt_2k_js/jwt_2k.r1cs"),
            build.join("jwt/jwt_js/jwt.r1cs"),
        ),
        (
            zkid.join("wallet-unit-poc/circom/build/show/show_js/show.r1cs"),
            build.join("show/show_js/show.r1cs"),
        ),
    ] {
        fs::create_dir_all(destination.parent().ok_or("invalid circuit destination")?)?;
        if destination.symlink_metadata().is_ok() {
            fs::remove_file(&destination)?;
        }
        symlink(source, destination)?;
    }
    let docs = documents.to_string_lossy().into_owned();

    let started = Instant::now();
    println!("{}", setup_jwt_keys(docs.clone())?);
    println!("{}", setup_show_keys(docs.clone())?);
    println!("key setup: {} ms", started.elapsed().as_millis());

    let issuer = SigningKey::random(&mut OsRng);
    let holder = SigningKey::random(&mut OsRng);
    let (issuer_x, issuer_y) = coordinates(&issuer);
    let (holder_x, holder_y) = coordinates(&holder);
    let disclosure = b64(br#"["fixed-test-salt","birthdate","1990-01-01"]"#);
    let digest = b64(Sha256::digest(disclosure.as_bytes()));
    let header = b64(serde_json::to_vec(&json!({"alg":"ES256","typ":"vc+sd-jwt"}))?);
    let payload = b64(serde_json::to_vec(&json!({
        "iss": "did:key:openac-age-test-issuer",
        "nbf": 1,
        "exp": 4_102_444_800u64,
        "cnf": {"jwk": {"kty":"EC", "crv":"P-256", "x":holder_x, "y":holder_y}},
        "vc": {"credentialSubject": {"_sd_alg":"sha-256", "_sd":[digest]}}
    }))?);
    let signing_input = format!("{header}.{payload}");
    let signature: Signature = issuer.sign(signing_input.as_bytes());
    let sd_jwt = format!("{signing_input}.{}~{disclosure}~", b64(signature.to_bytes()));

    let prepared = create_age_prepare_input(
        docs.clone(), sd_jwt, issuer_x.clone(), issuer_y.clone(),
    )?;
    let jwt_timing = prove_jwt(docs.clone())?;
    let nonce = "fixed-openac-age-request-nonce-0123456789".to_owned();
    let holder_signature: Signature = holder.sign(nonce.as_bytes());
    create_age_show_input(
        docs.clone(), nonce.clone(), b64(holder_signature.to_bytes()),
        prepared.claim_name.clone(), prepared.claim_format, 2008_0901,
    )?;
    let show_timing = prove_show(docs.clone())?;
    generate_shared_blinds(docs.clone())?;
    reblind_jwt(docs.clone())?;
    reblind_show(docs.clone())?;
    let accepted = verify_age_presentation(
        docs.clone(), nonce, prepared.claim_name, prepared.claim_format, 2008_0901,
        issuer_x, issuer_y,
    )?;
    if !accepted {
        return Err("linked age proof rejected its own fixed vector".into());
    }
    println!(
        "linked proof accepted; prepare={} ms show={} ms",
        jwt_timing.total_ms, show_timing.total_ms
    );
    Ok(())
}
