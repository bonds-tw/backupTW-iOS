use base64::{engine::general_purpose, Engine as _};
use open_gpki_pkcs11::api::{self, SignMechanism, SignRequest};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::env;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
#[cfg(unix)]
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};
use zeroize::Zeroizing;

const REQUEST_FORMAT: &str = "bonds-tw-official-document-physical-card-request-v1";
const RESPONSE_FORMAT: &str = "bonds-tw-official-document-physical-card-response-v1";
const CONSENT_VERSION: &str = "bonds-tw-official-document-inbox-consent-v1";
const CONSENT_SCOPE: &str = "local-prototype-only";
const TBS_PREFIX: &str = "bonds-tw-official-document-consent-v1:";
const MAXIMUM_REQUEST_AGE_MS: i64 = 15 * 60 * 1_000;
const MAXIMUM_FUTURE_SKEW_MS: i64 = 60 * 1_000;
const MAXIMUM_REQUEST_BYTES: u64 = 16 * 1_024;

#[derive(Clone, Debug, Deserialize, PartialEq, Eq, Serialize)]
struct PhysicalCardSigningRequest {
    format: String,
    version: String,
    scope: String,
    created_at_unix_ms: i64,
    nonce: String,
    to_be_signed: String,
}

#[derive(Debug, Serialize)]
struct PhysicalCardSigningResponse<'a> {
    format: &'static str,
    request: &'a PhysicalCardSigningRequest,
    certificate_der_base64: String,
    signature_base64: String,
    signed_at_unix_ms: i64,
}

#[derive(Debug, PartialEq, Eq)]
struct Arguments {
    request: PathBuf,
    response: PathBuf,
    slot: Option<u64>,
}

fn usage() -> &'static str {
    "usage: bonds-official-document-physical-card-signer --request <json> --response <json> [--slot <number>]"
}

fn parse_arguments<I>(arguments: I) -> Result<Arguments, String>
where
    I: IntoIterator<Item = String>,
{
    let mut values = arguments.into_iter();
    let _program = values.next();
    let mut request = None;
    let mut response = None;
    let mut slot = None;

    while let Some(argument) = values.next() {
        match argument.as_str() {
            "--request" => {
                request = Some(PathBuf::from(
                    values.next().ok_or_else(|| usage().to_string())?,
                ));
            }
            "--response" => {
                response = Some(PathBuf::from(
                    values.next().ok_or_else(|| usage().to_string())?,
                ));
            }
            "--slot" => {
                let value = values.next().ok_or_else(|| usage().to_string())?;
                slot = Some(
                    value
                        .parse::<u64>()
                        .map_err(|_| "--slot must be a non-negative integer".to_string())?,
                );
            }
            "--help" | "-h" => return Err(usage().to_string()),
            _ => return Err(format!("unknown argument: {argument}\n{}", usage())),
        }
    }

    Ok(Arguments {
        request: request.ok_or_else(|| usage().to_string())?,
        response: response.ok_or_else(|| usage().to_string())?,
        slot,
    })
}

fn now_unix_milliseconds() -> Result<i64, String> {
    let duration = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| "system clock is before the Unix epoch".to_string())?;
    i64::try_from(duration.as_millis()).map_err(|_| "system clock is out of range".to_string())
}

fn validate_request(request: &PhysicalCardSigningRequest, now_ms: i64) -> Result<(), String> {
    if request.format != REQUEST_FORMAT
        || request.version != CONSENT_VERSION
        || request.scope != CONSENT_SCOPE
    {
        return Err(
            "request format, version, or scope is not the supported local prototype".into(),
        );
    }

    let nonce = general_purpose::URL_SAFE_NO_PAD
        .decode(request.nonce.as_bytes())
        .map_err(|_| "request nonce is not unpadded base64url".to_string())?;
    if nonce.len() != 32 {
        return Err("request nonce must contain exactly 32 bytes".into());
    }

    let age = now_ms
        .checked_sub(request.created_at_unix_ms)
        .ok_or_else(|| "request timestamp is out of range".to_string())?;
    if age > MAXIMUM_REQUEST_AGE_MS {
        return Err(
            "request is older than the 15-minute signing window; create a new one in the app"
                .into(),
        );
    }
    if age < -MAXIMUM_FUTURE_SKEW_MS {
        return Err("request timestamp is too far in the future; check both device clocks".into());
    }

    let canonical = format!(
        "version={}\nscope={}\ncreated_at_unix_ms={}\nnonce={}\n",
        request.version, request.scope, request.created_at_unix_ms, request.nonce
    );
    let digest = Sha256::digest(canonical.as_bytes());
    let expected = format!(
        "{}{}",
        TBS_PREFIX,
        digest
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>()
    );
    if request.to_be_signed != expected {
        return Err("to_be_signed does not match the canonical consent fields".into());
    }
    Ok(())
}

fn read_request(path: &Path, now_ms: i64) -> Result<PhysicalCardSigningRequest, String> {
    let metadata = fs::metadata(path).map_err(|error| format!("cannot read request: {error}"))?;
    if !metadata.is_file() || metadata.len() > MAXIMUM_REQUEST_BYTES {
        return Err("request must be a regular JSON file no larger than 16 KiB".into());
    }
    let bytes = fs::read(path).map_err(|error| format!("cannot read request: {error}"))?;
    let request: PhysicalCardSigningRequest =
        serde_json::from_slice(&bytes).map_err(|error| format!("invalid request JSON: {error}"))?;
    validate_request(&request, now_ms)?;
    Ok(request)
}

fn write_response(path: &Path, response: &PhysicalCardSigningResponse<'_>) -> Result<(), String> {
    let bytes = serde_json::to_vec(response)
        .map_err(|error| format!("cannot encode response JSON: {error}"))?;
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    options.mode(0o600);
    let mut file = options
        .open(path)
        .map_err(|error| format!("cannot create response without overwriting: {error}"))?;
    file.write_all(&bytes)
        .and_then(|_| file.sync_all())
        .map_err(|error| format!("cannot write response: {error}"))
}

fn run(arguments: Arguments) -> Result<(), String> {
    let request_time = now_unix_milliseconds()?;
    let request = read_request(&arguments.request, request_time)?;

    let tokens =
        api::list_tokens().map_err(|error| format!("GPKI reader/card check failed: {error}"))?;
    let slot = match arguments.slot {
        Some(slot) => {
            if !tokens.iter().any(|token| token.slot_id == slot) {
                return Err(format!(
                    "slot {slot} does not contain a recognized GPKI card"
                ));
            }
            slot
        }
        None if tokens.len() == 1 => tokens[0].slot_id,
        None => {
            return Err(format!(
                "{} recognized GPKI cards are present; rerun with --slot and the intended slot number",
                tokens.len()
            ));
        }
    };

    eprintln!("已重建並核對一次性同意內容；接下來只會簽這串內容：");
    eprintln!("{}", request.to_be_signed);
    eprintln!("PIN 輸錯會扣卡片重試次數，本工具不會自動重試。\n");
    let pin = Zeroizing::new(
        rpassword::prompt_password("自然人憑證 PIN（輸入不顯示）: ")
            .map_err(|error| format!("cannot read PIN from the terminal: {error}"))?,
    );
    if pin.is_empty() {
        return Err("empty PIN; no signing operation was attempted".into());
    }

    let result = api::sign(SignRequest {
        slot_id: Some(slot),
        pin: pin.as_str(),
        key_id: None,
        mechanism: SignMechanism::Sha256RsaPkcs,
        data: request.to_be_signed.as_bytes(),
        return_certificate: true,
    })
    .map_err(|error| match error {
        api::Error::PinIncorrect => {
            "PIN incorrect; one card retry may have been consumed. The tool will not retry."
                .to_string()
        }
        api::Error::PinLocked => "the natural-person certificate PIN is locked".to_string(),
        other => format!("physical-card signing failed: {other}"),
    })?;

    let certificate = result
        .certificate_der
        .ok_or_else(|| "the signing certificate was not returned by the driver".to_string())?;
    let signed_at = now_unix_milliseconds()?;
    validate_request(&request, signed_at)?;
    let response = PhysicalCardSigningResponse {
        format: RESPONSE_FORMAT,
        request: &request,
        certificate_der_base64: general_purpose::STANDARD.encode(certificate),
        signature_base64: general_purpose::STANDARD.encode(result.signature),
        signed_at_unix_ms: signed_at,
    };
    write_response(&arguments.response, &response)?;
    eprintln!("簽章完成；回傳檔已以 0600 權限建立，內容未印到終端。 ");
    Ok(())
}

fn main() {
    let result = parse_arguments(env::args()).and_then(run);
    if let Err(error) = result {
        let _ = writeln!(io::stderr(), "error: {error}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(now_ms: i64) -> PhysicalCardSigningRequest {
        let nonce = general_purpose::URL_SAFE_NO_PAD.encode([0x42; 32]);
        let canonical = format!(
            "version={CONSENT_VERSION}\nscope={CONSENT_SCOPE}\ncreated_at_unix_ms={now_ms}\nnonce={nonce}\n"
        );
        let digest = Sha256::digest(canonical.as_bytes());
        PhysicalCardSigningRequest {
            format: REQUEST_FORMAT.into(),
            version: CONSENT_VERSION.into(),
            scope: CONSENT_SCOPE.into(),
            created_at_unix_ms: now_ms,
            nonce,
            to_be_signed: format!(
                "{}{}",
                TBS_PREFIX,
                digest
                    .iter()
                    .map(|byte| format!("{byte:02x}"))
                    .collect::<String>()
            ),
        }
    }

    #[test]
    fn exact_request_validates_without_identity_data() {
        let now = 1_800_000_000_000;
        let request = request(now);
        validate_request(&request, now + 100).unwrap();
        let json = serde_json::to_string(&request).unwrap();
        assert!(!json.contains("idNumber"));
        assert!(!json.contains("hashed_id_num"));
    }

    #[test]
    fn changed_target_and_stale_request_are_rejected() {
        let now = 1_800_000_000_000;
        let mut altered = request(now);
        altered.to_be_signed.push('0');
        assert!(validate_request(&altered, now).is_err());
        assert!(validate_request(&request(now), now + MAXIMUM_REQUEST_AGE_MS + 1).is_err());
    }

    #[test]
    fn command_line_never_accepts_a_pin_argument() {
        let error = parse_arguments(
            [
                "tool",
                "--request",
                "in",
                "--response",
                "out",
                "--pin",
                "1234",
            ]
            .into_iter()
            .map(String::from),
        )
        .unwrap_err();
        assert!(error.contains("unknown argument: --pin"));
    }
}
