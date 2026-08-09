//
//  DistinguishedNameTests.swift
//  backupTWTests
//
//  Reading attributes out of a certificate's Subject DN.
//

import Foundation
import Testing
@testable import backupTW

// MARK: - Fixtures
//
// Every certificate below was produced by OpenSSL 3.6.2, not written by hand.
// That is a deliberate correction: an earlier parser in this project was tested
// against hand-written strings, which meant its fixtures were missing the very
// structures real tools emit — and it shipped a false positive that only showed
// up when somebody ran real files through it.
//
// The exact commands, so these can be regenerated:
//
//   openssl ecparam -name prime256v1 -genkey -noout -out k.pem
//   openssl req -new -x509 -key k.pem -sha256 -days 3650 -utf8 \
//     -subj "/C=TW/CN=王小明/serialNumber=1234567890123456" -out moicaShape.pem
//   # leafSigned: a CA-signed leaf, so subject and issuer genuinely differ
//   openssl req -new -x509 -key ca.pem -sha256 -days 3650 -utf8 \
//     -subj "/C=TW/O=行政院/CN=內政部憑證管理中心" -out ca.crt
//   openssl req -new -key k.pem -utf8 \
//     -subj "/C=TW/CN=王小明/serialNumber=1234567890123456" -out leaf.csr
//   openssl x509 -req -in leaf.csr -CA ca.crt -CAkey ca.pem -sha256 -days 3650 \
//     -out leafSigned.pem
//   # multiValued: two attributes inside one RDN
//   openssl req ... -multivalue-rdn \
//     -subj "/C=TW/CN=林大同+serialNumber=5555444433332222"
//   # duplicateCN: the same attribute twice
//   openssl req ... -subj "/C=TW/CN=第一個/CN=第二個"
//   # noCommonName: the attribute genuinely absent
//   openssl req ... -subj "/C=TW/serialNumber=1111222233334444"
//   # bmpString: string_mask=default makes OpenSSL choose BMPString for CJK
//   printf '[req]\ndistinguished_name=dn\nstring_mask=default\nprompt=no\n[dn]\nC=TW\nCN=舊憑證\n' > bmp.cnf
//   openssl req -new -x509 -key k.pem -sha256 -days 3650 -utf8 -config bmp.cnf
//
// The keys are throwaway P-256 pairs generated for these fixtures and used
// nowhere else; nothing here is a credential.

/// `C=TW, CN=王小明, serialNumber=1234567890123456` — the shape a real
/// 自然人憑證 has, measured on 2026-08-09.
private let moicaShapeDER = """
MIIBzDCCAXOgAwIBAgIUKtdGIqGhq1kPd+DganQoMtZKSuowCgYIKoZIzj0EAwIwPDELMAkGA1UEBhMCVFcxEjAQBgNV\
BAMMCeeOi+Wwj+aYjjEZMBcGA1UEBRMQMTIzNDU2Nzg5MDEyMzQ1NjAeFw0yNjA4MDkxMjE4MTBaFw0zNjA4MDYxMjE4\
MTBaMDwxCzAJBgNVBAYTAlRXMRIwEAYDVQQDDAnnjovlsI/mmI4xGTAXBgNVBAUTEDEyMzQ1Njc4OTAxMjM0NTYwWTAT\
BgcqhkjOPQIBBggqhkjOPQMBBwNCAASrEiJwI29Ul31RYxkHl5DrqerQ7cco4Aw2XlKdgNihsCGilYjuB3J6BfZD3kcZ\
DS/UuOCjaEkvUgL9s22kt9dco1MwUTAdBgNVHQ4EFgQUcj7p7CKSOeCKdoa6887klT1VZ4gwHwYDVR0jBBgwFoAUcj7p\
7CKSOeCKdoa6887klT1VZ4gwDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNHADBEAiB7UL4y1a/ieXFteMXcc12F\
uyF7dDcTns2iKLXcjRRVVAIgXxnN0f6Wu1PM8nnEDH9zlaCdwrXf4MSZTtFunJlA8FI=
"""

/// Subject `CN=王小明`, issuer `CN=內政部憑證管理中心`. The two DNs carry
/// *different* common names on purpose — this is the fixture that fails if
/// `subjectAttribute` ever reads `issuerName`.
private let leafSignedDER = """
MIIBxjCCAW2gAwIBAgIUDaTcIwfKy88HGAlwOxzo9V2f67EwCgYIKoZIzj0EAwIwRzELMAkGA1UEBhMCVFcxEjAQBgNV\
BAoMCeihjOaUv+mZojEkMCIGA1UEAwwb5YWn5pS/6YOo5oaR6K2J566h55CG5Lit5b+DMB4XDTI2MDgwOTEyMTgyNVoX\
DTM2MDgwNjEyMTgyNVowPDELMAkGA1UEBhMCVFcxEjAQBgNVBAMMCeeOi+Wwj+aYjjEZMBcGA1UEBRMQMTIzNDU2Nzg5\
MDEyMzQ1NjBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABKsSInAjb1SXfVFjGQeXkOup6tDtxyjgDDZeUp2A2KGwIaKV\
iO4HcnoF9kPeRxkNL9S44KNoSS9SAv2zbaS311yjQjBAMB0GA1UdDgQWBBRyPunsIpI54Ip2hrrzzuSVPVVniDAfBgNV\
HSMEGDAWgBRDdQrna5z4GCul2C7dMFd/EbbwzTAKBggqhkjOPQQDAgNHADBEAiApmFhdA0Ho280ai9lnc1qvAvTMRjrk\
7B7mPSq6k+45CgIge8S8PaTRqvHAK48rVbomEgSLvHwLqsRds4pBHNC1TNc=
"""

/// `CN=林大同 + serialNumber=5555444433332222` inside a single RDN.
private let multiValuedDER = """
MIIByTCCAW+gAwIBAgIUHyIBZ6P4uq/ZmLljFvF6JFTDhOUwCgYIKoZIzj0EAwIwOjELMAkGA1UEBhMCVFcxKzAQBgNV\
BAMMCeael+Wkp+WQjDAXBgNVBAUTEDU1NTU0NDQ0MzMzMzIyMjIwHhcNMjYwODA5MTIxODEwWhcNMzYwODA2MTIxODEw\
WjA6MQswCQYDVQQGEwJUVzErMBAGA1UEAwwJ5p6X5aSn5ZCMMBcGA1UEBRMQNTU1NTQ0NDQzMzMzMjIyMjBZMBMGByqG\
SM49AgEGCCqGSM49AwEHA0IABKsSInAjb1SXfVFjGQeXkOup6tDtxyjgDDZeUp2A2KGwIaKViO4HcnoF9kPeRxkNL9S4\
4KNoSS9SAv2zbaS311yjUzBRMB0GA1UdDgQWBBRyPunsIpI54Ip2hrrzzuSVPVVniDAfBgNVHSMEGDAWgBRyPunsIpI5\
4Ip2hrrzzuSVPVVniDAPBgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMCA0gAMEUCIGuX2vSf98MQbgQfkn3nnlkqcGIQ\
mXMy8FIUcbo0EHbDAiEAg7doTmZxxq78r+ArhXyrg3sop+dEq2PTAnghl1i2ioM=
"""

/// `CN=第一個` and `CN=第二個` in the same DN.
private let duplicateCommonNameDER = """
MIIBvzCCAWWgAwIBAgIUBHlbX0x5RRnz1VrVHPgOSGUoR4wwCgYIKoZIzj0EAwIwNTELMAkGA1UEBhMCVFcxEjAQBgNV\
BAMMCeesrOS4gOWAizESMBAGA1UEAwwJ56ys5LqM5YCLMB4XDTI2MDgwOTEyMTgxMFoXDTM2MDgwNjEyMTgxMFowNTEL\
MAkGA1UEBhMCVFcxEjAQBgNVBAMMCeesrOS4gOWAizESMBAGA1UEAwwJ56ys5LqM5YCLMFkwEwYHKoZIzj0CAQYIKoZI\
zj0DAQcDQgAEqxIicCNvVJd9UWMZB5eQ66nq0O3HKOAMNl5SnYDYobAhopWI7gdyegX2Q95HGQ0v1Ljgo2hJL1IC/bNt\
pLfXXKNTMFEwHQYDVR0OBBYEFHI+6ewikjnginaGuvPO5JU9VWeIMB8GA1UdIwQYMBaAFHI+6ewikjnginaGuvPO5JU9\
VWeIMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDSAAwRQIhAKXi+VazOEos0gM6l5IiDYsROSSP6EmU5+pGepHt\
h4+tAiAGZWURBLyjPsGIp33N0S0A9Zz9cdHfQ0gijCZ9PG8PnQ==
"""

/// `C=TW, serialNumber=1111222233334444` — no common name at all.
private let noCommonNameDER = """
MIIBpTCCAUugAwIBAgIUPVOjjhVj2SsGSTG14r2gFWvq4+MwCgYIKoZIzj0EAwIwKDELMAkGA1UEBhMCVFcxGTAXBgNV\
BAUTEDExMTEyMjIyMzMzMzQ0NDQwHhcNMjYwODA5MTIxODExWhcNMzYwODA2MTIxODExWjAoMQswCQYDVQQGEwJUVzEZ\
MBcGA1UEBRMQMTExMTIyMjIzMzMzNDQ0NDBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABKsSInAjb1SXfVFjGQeXkOup\
6tDtxyjgDDZeUp2A2KGwIaKViO4HcnoF9kPeRxkNL9S44KNoSS9SAv2zbaS311yjUzBRMB0GA1UdDgQWBBRyPunsIpI5\
4Ip2hrrzzuSVPVVniDAfBgNVHSMEGDAWgBRyPunsIpI54Ip2hrrzzuSVPVVniDAPBgNVHRMBAf8EBTADAQH/MAoGCCqG\
SM49BAMCA0gAMEUCIGRNwVNAtMbn6edbibMF95PK3sQOtNnsHx7uVjOWx7ctAiEAxll1bSJRI4JsKTIexw920ixqf+1o\
6Qfb/3ZRLBoaPP0=
"""

/// `CN=舊憑證` encoded as a BMPString rather than a UTF8String.
private let bmpStringDER = """
MIIBXzCCAQWgAwIBAgIUSgieO5Qpyoe6WAJIwwSjCCXJdgUwCgYIKoZIzj0EAwIwHjELMAkGA1UEBhMCVFcxDzANBgNV\
BAMeBoIKYZGLSTAeFw0yNjA4MDkxMjE4MjVaFw0zNjA4MDYxMjE4MjVaMB4xCzAJBgNVBAYTAlRXMQ8wDQYDVQQDHgaC\
CmGRi0kwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAASrEiJwI29Ul31RYxkHl5DrqerQ7cco4Aw2XlKdgNihsCGilYju\
B3J6BfZD3kcZDS/UuOCjaEkvUgL9s22kt9dcoyEwHzAdBgNVHQ4EFgQUcj7p7CKSOeCKdoa6887klT1VZ4gwCgYIKoZI\
zj0EAwIDSAAwRQIgGQMNgTLnLGqU/rj/PDQFGDyd8tKpAn5fjKO+0/rS+1YCIQC9OJKMRzFTShIeFs3VG4giTJaARgwU\
oIcTtVxW7zDL0A==
"""

// MARK: - Tests

struct DistinguishedNameTests {

    private func certificate(_ base64: String) throws -> X509Certificate {
        try X509Certificate.parse(base64DER: base64)
    }

    @Test func commonNameIsReadFromTheSubject() throws {
        let name = try certificate(moicaShapeDER).subjectAttribute(.commonName)
        #expect(name == "王小明")
    }

    @Test func serialNumberAttributeIsReadFromTheSubject() throws {
        let serial = try certificate(moicaShapeDER).subjectAttribute(.serialNumber)
        #expect(serial == "1234567890123456")
    }

    /// The mutation this file exists to catch.
    ///
    /// Reading the issuer DN instead of the subject would answer 內政部憑證管理中心
    /// for *every* cardholder — and a holder-binding check built on that would
    /// pass for every certificate MOICA has ever issued. Both DNs in this
    /// fixture carry a common name, so a parser reading the wrong one still
    /// returns a plausible string rather than nil.
    @Test func theSubjectIsRead_notTheIssuer() throws {
        let holder = try certificate(leafSignedDER)
        let subjectName = try holder.subjectAttribute(.commonName)
        let issuerName = try X509Certificate.value(of: .commonName, inName: holder.issuerName)

        #expect(subjectName == "王小明")
        // And the fixture really does differ, so the assertion above is not
        // passing because both DNs happen to say the same thing.
        #expect(issuerName == "內政部憑證管理中心")
        #expect(subjectName != issuerName)
    }

    /// A DN is a sequence of *sets*. Stopping at the first attribute of each set
    /// silently loses everything after a `+`.
    @Test func attributesInsideAMultiValuedRDNAreFound() throws {
        let holder = try certificate(multiValuedDER)
        let name = try holder.subjectAttribute(.commonName)
        let serial = try holder.subjectAttribute(.serialNumber)

        #expect(name == "林大同")
        #expect(serial == "5555444433332222")
    }

    /// Nothing says which of two common names wins, so answering with either
    /// would let two verifiers reach opposite conclusions about the same bytes.
    @Test func aDuplicatedAttributeIsRejectedRatherThanPicked() throws {
        let holder = try certificate(duplicateCommonNameDER)

        #expect(throws: (any Error).self) {
            _ = try holder.subjectAttribute(.commonName)
        }
    }

    @Test func anAbsentAttributeIsNilRatherThanAnError() throws {
        let holder = try certificate(noCommonNameDER)
        let name = try holder.subjectAttribute(.commonName)
        let serial = try holder.subjectAttribute(.serialNumber)

        #expect(name == nil)
        // The DN parses fine — the attribute is simply not in it.
        #expect(serial == "1111222233334444")
    }

    @Test func bmpStringValuesAreDecoded() throws {
        let name = try certificate(bmpStringDER).subjectAttribute(.commonName)
        #expect(name == "舊憑證")
    }

    /// Pins the measurement `DistinguishedNameAttribute` documents: the Subject
    /// DN's `serialNumber` on a real 自然人憑證 is a 16-digit number, which is
    /// not the shape of a 身分證統一編號 (one letter, nine digits). Anyone
    /// tempted to compare it against `credentialSubject.unifiedNo` should fail
    /// here first.
    @Test func theSubjectSerialNumberIsNotANationalIDNumber() throws {
        let parsed = try certificate(moicaShapeDER).subjectAttribute(.serialNumber)
        let serial = try #require(parsed)

        let isAllDigits = serial.allSatisfy { $0.isNumber }
        let looksLikeANationalID = serial.count == 10
            && serial.first?.isLetter == true
            && serial.dropFirst().allSatisfy { $0.isNumber }

        #expect(isAllDigits)
        #expect(looksLikeANationalID == false)
    }
}
