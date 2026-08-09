//
//  TestCardholderKey.swift
//  backupTWTests
//
//  A throwaway RSA cardholder key and certificates, shared by every test that
//  needs a card signature. Internal rather than file-private so the credential
//  tests and the presentation tests sign with the same key — two copies of a
//  key fixture is two things to keep in step.
//

import Foundation
import Security

// MARK: - Fixtures
//
// An RSA-2048 key pair and two self-signed certificates over it, produced by
// OpenSSL 3.6.2:
//
//   openssl genrsa -out holder.pem 2048
//   openssl req -new -x509 -key holder.pem -sha256 -days 3650 -utf8 \
//     -subj "/C=TW/CN=王小明/serialNumber=1234567890123456" -out holder.crt
//   openssl req -new -x509 -key holder.pem -sha256 -days 3650 -utf8 \
//     -subj "/C=TW/CN=陳小美/serialNumber=9999888877776666" -out other.crt
//   openssl rsa -in holder.pem -outform DER -traditional -out holderKey.der
//
// The second certificate wraps **the same key** under a different name. That is
// what makes the holder-binding test meaningful: the signature verifies
// mathematically against both, so only the name check can tell them apart.
//
// Signatures are not baked in — the tests produce them with
// `SecKeyCreateSignature` over whatever payload the case needs, which is the
// same primitive 內政部's HSM applies (`sign_type: "PKCS#1"`,
// `hash_algorithm: "SHA256"`). Nothing here is hand-assembled DER.
//
// ⚠️ This private key is a throwaway generated for these tests. It signs no
// credential anyone holds and belongs to no cardholder.

let holderCertificateDER = """
MIIDWTCCAkGgAwIBAgIUcUuFMu2tcgc7snSfqwJR56oFF+swDQYJKoZIhvcNAQELBQAwPDELMAkGA1UEBhMCVFcxEjAQ\
BgNVBAMMCeeOi+Wwj+aYjjEZMBcGA1UEBRMQMTIzNDU2Nzg5MDEyMzQ1NjAeFw0yNjA4MDkxMjM1NDZaFw0zNjA4MDYx\
MjM1NDZaMDwxCzAJBgNVBAYTAlRXMRIwEAYDVQQDDAnnjovlsI/mmI4xGTAXBgNVBAUTEDEyMzQ1Njc4OTAxMjM0NTYw\
ggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQC3Kh2Z54eC8PdyFME3GSVU2hAjgYEkOvmm6MxR1UvvBsNjvblf\
q0lirzbNWrwu1LfiLGSXq/QG0ml4+VRZGjd062ScTCe/3fW1soRtG33GEdG+KfV91vdwSCP4q4mMTuoXA42yTqatgRs2\
zKw6uOpYgRMmAGZ2MGilxjK9/+A8mWFjb6CrYNnUJWMxGGy9LlozWiLRuKgctoPnqwTV3EO2Pf5yvYUsrnQ6CVqLKg1E\
WoreNkmywn/oHQr952n1sgPKKQkm5KC8js3gRY2Yi/HXEI2Mv2SK5HtLdGc7Ht9LxvhMZIWKZcN230J+QnULpYM7mKkT\
dhKPacylvR6t3B4FAgMBAAGjUzBRMB0GA1UdDgQWBBQbLlsuRhIWnr0Kj8Qo8pj2GM2tyjAfBgNVHSMEGDAWgBQbLlsu\
RhIWnr0Kj8Qo8pj2GM2tyjAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4IBAQAmPGGksLuFM48sfjqEqju3\
vaHxLaJXVFFklX5kqE/jimr6JzdGZ7anAP/wD4uFtHOYhfj/1gUlQFm0nRH92UcqrDxEBW1u2pYh630RArtvbRnzje/G\
SvVyGwaFL5tKuFmRD7Fgj1Vhxze1939u3/wtv4L7S1JptKGaeVUFD9WMn+Sz/LXsoQeIA6MIsPvFZ3NbuFRCfASB1y6q\
+wmtS8LF7ePZlpbadAK82GlAIl7thXiAMRkh+U710esr/wLRrRTybYCgwrK6GaoU2/ghvF5x9hsdhWagYc0Zik/5PiCZ\
dcuAw2FBNs/fyGWDgTQdk6sG5RbfXK+c/HTptxZ6WJq8
"""

/// The same key, certified under a different name.
let otherCardholderCertificateDER = """
MIIDWTCCAkGgAwIBAgIUccmEYQ8Yr3pQ8XDkg929ehTPt1YwDQYJKoZIhvcNAQELBQAwPDELMAkGA1UEBhMCVFcxEjAQ\
BgNVBAMMCemZs+Wwj+e+jjEZMBcGA1UEBRMQOTk5OTg4ODg3Nzc3NjY2NjAeFw0yNjA4MDkxMjM1NDZaFw0zNjA4MDYx\
MjM1NDZaMDwxCzAJBgNVBAYTAlRXMRIwEAYDVQQDDAnpmbPlsI/nvo4xGTAXBgNVBAUTEDk5OTk4ODg4Nzc3NzY2NjYw\
ggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQC3Kh2Z54eC8PdyFME3GSVU2hAjgYEkOvmm6MxR1UvvBsNjvblf\
q0lirzbNWrwu1LfiLGSXq/QG0ml4+VRZGjd062ScTCe/3fW1soRtG33GEdG+KfV91vdwSCP4q4mMTuoXA42yTqatgRs2\
zKw6uOpYgRMmAGZ2MGilxjK9/+A8mWFjb6CrYNnUJWMxGGy9LlozWiLRuKgctoPnqwTV3EO2Pf5yvYUsrnQ6CVqLKg1E\
WoreNkmywn/oHQr952n1sgPKKQkm5KC8js3gRY2Yi/HXEI2Mv2SK5HtLdGc7Ht9LxvhMZIWKZcN230J+QnULpYM7mKkT\
dhKPacylvR6t3B4FAgMBAAGjUzBRMB0GA1UdDgQWBBQbLlsuRhIWnr0Kj8Qo8pj2GM2tyjAfBgNVHSMEGDAWgBQbLlsu\
RhIWnr0Kj8Qo8pj2GM2tyjAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4IBAQA6g93vqtj1Db8r124CSk8B\
C8FW4c/341psNo4zpaf44wJ91YxpwlHNlpEWgE5J/wqLwGTQH3aPBIAxjPfYNXrz4J12wET7KQrjcEGw3FeG+DbmpZAg\
VL6LzJg6kwZkQnlHBhZKd3sQbvDpRkxC3M2x5eJRRAUM66e1aQutIdMVNlRFTLId1dfZUpa1v+i1Ju6kf7zJgffJ0XDL\
0+/EUv5MghHftjVyRV2vQu3W6PyRwqg3X4U0UvbP26oc22s41Kj1zvdwEM1LLCSiP0a8szMw16ZmagaxrG/rS7xCbczY\
ktJyjgPj99w/s9t1v7MZavTmZu+HqcBDmcduyKl/odM+
"""

let holderPrivateKeyPKCS1DER = """
MIIEowIBAAKCAQEAtyodmeeHgvD3chTBNxklVNoQI4GBJDr5pujMUdVL7wbDY725X6tJYq82zVq8LtS34ixkl6v0BtJp\
ePlUWRo3dOtknEwnv931tbKEbRt9xhHRvin1fdb3cEgj+KuJjE7qFwONsk6mrYEbNsysOrjqWIETJgBmdjBopcYyvf/g\
PJlhY2+gq2DZ1CVjMRhsvS5aM1oi0bioHLaD56sE1dxDtj3+cr2FLK50OglaiyoNRFqK3jZJssJ/6B0K/edp9bIDyikJ\
JuSgvI7N4EWNmIvx1xCNjL9kiuR7S3RnOx7fS8b4TGSFimXDdt9CfkJ1C6WDO5ipE3YSj2nMpb0erdweBQIDAQABAoIB\
ACF0PcfYc/XEkU1y4P9xRlJDKeNySeYWJ3cG2hqwPJhBwfo7stn4bQTrP7UuN2TOUW+r8AuLypxcXgtMbs1/blWakNvD\
RRdUMQaovms3NDezFX4IJ+B+HN+TLY7DtfG8kCD38y94EhVqmU/e/i4TjCnyGU89j3lSyipNEwOE8q3eflQ3AjFLREAR\
tnA9qbu4n5bcXTfnw7PYQ7czKXXoO5r+gnpf9vMO2ee5Zw93D8yI2HCxSwrHqCBqmpfO7KvmrrDkRdUotA52NtRDoNdF\
hBwYv/8nFtwe8oYKio+FYNoUlFgjcS50XlXN+SgEJP6UbI/HLx6aSn9RBJJQeVHmd1kCgYEA8G2+hICy10A34b3lx+Ig\
uSXVw4VK1w8ugM/21t5z9uhWRgvl8+fsnzEeDwhnKr2DBRTBUhq080YTaSGElmx3NRb+zkEkRu15pwQKsR1/Mq/CD5rx\
tsqEb26tAKFZPx7HZUJdl/gOtl7gA+gL8laXZZYAoI4vKxkUB+vGiM7fceMCgYEAwwbxmplYurCLSV/ykdWn+JQgaJ4Q\
ELVVNNmI9s7zPTVfPbVHhToyQ2vTlORIT7yCS/eHn0PRF0K48I40yqoNBunaDo2rR7vJM3ffjwqMLrcixn2ba2I8D1lF\
JG23arho37eFd4TKWhUf5yhioZ34RuBT1T1YKUGl+Kr4WNM6lPcCgYEAzxl5NqG1a3zBpg3xVFAQZ+uTSqwSX1WQdRyu\
Pz+3HEPdrNCq74IjbKzee4x9cW904HeUXqjqnXMLXU+l6fzcYjrAmeG64e3FEHyGyTHjU0HaI58P/qhLk8D9/MD/I0Pb\
9flIrZLa+XSX+kVzpPe5yaOAPsy7DKC5hGkvxsCL8IkCgYAv4Ax/PxWg/qWypXMOibxqMTKje+nFsD3yc1REAhmD9Q4k\
P9QGyHp+QoH2EvQNXuE9dM4+Mo+pfh+YLdCXz5bTE6UL3YsmWNrTX6Hpo1U2Qo6u2zbD7aGAwxFOGADmmc5k3NBOvrJN\
2tGyFR/hPL4t5/OsbRqvRgZQPOgqJfBDkQKBgB2S0heZuXj7h1zeJ7hTJ2Vk4kt8Xzik2tKcInXD0AwT2+EEumbewalh\
lpK2VQkn8oUnTcKfkxO+Zwmvcr56QTityTAIbdKZOuJlzHm+oGaKwxwVw9z7R1bkvTNCMCEBebt5fN/iMcIyW3WRCTj4\
+Sm/7KFDm8x9PmxnCkCjqLrV
"""

enum FixtureError: Error {
    case keyUnavailable
    case signingFailed
}

/// Signs with the throwaway key, using the same primitive the SP API applies.
func cardSignature(over message: Data) throws -> Data {
    guard let der = Data(base64Encoded: holderPrivateKeyPKCS1DER) else {
        throw FixtureError.keyUnavailable
    }
    let attributes: [CFString: Any] = [
        kSecAttrKeyType: kSecAttrKeyTypeRSA,
        kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        kSecAttrKeySizeInBits: 2048,
    ]
    var error: Unmanaged<CFError>?
    guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) else {
        error?.release()
        throw FixtureError.keyUnavailable
    }
    guard let signature = SecKeyCreateSignature(key,
                                                .rsaSignatureMessagePKCS1v15SHA256,
                                                message as CFData,
                                                &error) else {
        error?.release()
        throw FixtureError.signingFailed
    }
    return signature as Data
}
