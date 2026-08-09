//
//  SelectiveDisclosureTests.swift
//  backupTWTests
//

import Foundation
import Testing
@testable import backupTW

@Suite("選擇性揭露")
struct SelectiveDisclosureTests {

    private static let claims = [
        (name: "nationality", value: "中華民國"),
        (name: "unifiedNo", value: "A123456789"),
        (name: "name", value: "王小明"),
        (name: "birthdate", value: "1990-01-01"),
        (name: "addressOfHousehold", value: "臺北市中正區某路 1 號")
    ]

    /// The point of the whole mechanism: show one field, and the rest stay
    /// hidden — including from a verifier holding every committed digest.
    @Test("只揭露一個欄位，其餘不會外洩")
    func revealsOnlyWhatWasChosen() throws {
        let (digests, disclosures) = SelectiveDisclosure.commit(Self.claims)
        let birthdate = try #require(disclosures.first { $0.claimName == "birthdate" })

        let revealed = try SelectiveDisclosure.reveal(disclosures: [birthdate.encoded],
                                                      committedDigests: digests)
        #expect(revealed.count == 1)
        #expect(revealed[0].name == "birthdate")
        #expect(revealed[0].value == "1990-01-01")

        // The verifier holds all five digests and one disclosure. Nothing about
        // the other four may be recoverable from what it holds.
        let material = digests.joined() + birthdate.encoded
        for hidden in ["A123456789", "王小明", "臺北市中正區某路 1 號", "中華民國"] {
            #expect(!material.contains(hidden), "\(hidden) 從承諾值裡漏出來了")
        }
        #expect(SelectiveDisclosure.withheldCount(committedDigests: digests, revealed: 1) == 4)
    }

    /// Without a salt, a digest over a value from a small domain is recoverable
    /// by brute force. `nationality` has a handful of plausible values;
    /// `birthdate` about forty thousand. This is the property that makes the
    /// commitments safe to hand over at all.
    @Test("相同的欄位值，兩次承諾不會產生相同的摘要")
    func saltsMakeDigestsUnguessable() throws {
        let a = Disclosure(claimName: "nationality", claimValue: "中華民國")
        let b = Disclosure(claimName: "nationality", claimValue: "中華民國")
        #expect(a.digest != b.digest, "沒加鹽——查驗方可以暴力枚舉猜出未揭露的欄位")
        #expect(a.salt != b.salt)

        // 128 bits, base64url of 16 bytes.
        let saltBytes = try #require(Data(base64URLEncoded: a.salt))
        #expect(saltBytes.count == 16)
    }

    /// Left in claim order, position would leak which digest belongs to which
    /// field: a verifier receiving only the second disclosure would learn that
    /// the first, undisclosed entry is whatever the issuer always puts first.
    @Test("承諾摘要是排序過的，位置不洩漏對應關係")
    func digestOrderDoesNotTrackClaimOrder() {
        let (digests, _) = SelectiveDisclosure.commit(Self.claims)
        #expect(digests == digests.sorted())

        // Same claims in a different order must produce the same *set*, so a
        // verifier cannot compare orderings across two credentials either.
        let (shuffled, _) = SelectiveDisclosure.commit(Self.claims.reversed())
        #expect(shuffled == shuffled.sorted())
    }

    /// The entire value of the credential rests on this: a holder who could
    /// present a disclosure the issuer never committed to could assert anything.
    @Test("偽造一個沒被承諾過的欄位會被拒絕")
    func refusesAClaimTheIssuerNeverCommittedTo() throws {
        let (digests, _) = SelectiveDisclosure.commit(Self.claims)
        let forged = Disclosure(claimName: "isOver18", claimValue: "true")

        #expect(throws: SelectiveDisclosure.DisclosureError.undisclosedDigest(forged.digest)) {
            _ = try SelectiveDisclosure.reveal(disclosures: [forged.encoded],
                                               committedDigests: digests)
        }
    }

    /// Tampering with the value has to break the digest, or the holder could
    /// change what a committed claim says.
    @Test("改掉已承諾欄位的值也會被拒絕")
    func refusesATamperedValue() throws {
        let (digests, disclosures) = SelectiveDisclosure.commit(Self.claims)
        let original = try #require(disclosures.first { $0.claimName == "birthdate" })
        let tampered = Disclosure(claimName: "birthdate", claimValue: "2010-01-01",
                                  salt: original.salt)

        #expect(tampered.digest != original.digest)
        #expect(throws: SelectiveDisclosure.DisclosureError.undisclosedDigest(tampered.digest)) {
            _ = try SelectiveDisclosure.reveal(disclosures: [tampered.encoded],
                                               committedDigests: digests)
        }
    }

    /// Two disclosures for one claim name can carry different values, and which
    /// one wins would otherwise depend on iteration order.
    @Test("同一個欄位揭露兩次會被拒絕")
    func refusesDuplicateClaimNames() throws {
        let a = Disclosure(claimName: "name", claimValue: "王小明")
        let b = Disclosure(claimName: "name", claimValue: "李小華")
        let digests = [a.digest, b.digest].sorted()

        #expect(throws: SelectiveDisclosure.DisclosureError.duplicateClaim("name")) {
            _ = try SelectiveDisclosure.reveal(disclosures: [a.encoded, b.encoded],
                                               committedDigests: digests)
        }
    }

    /// Withholding is the point. A verifier that demanded a disclosure for every
    /// committed digest would have abolished selective disclosure while
    /// appearing to implement it.
    @Test("沒揭露的欄位不是錯誤，那正是重點")
    func withholdingIsNotAnError() throws {
        let (digests, disclosures) = SelectiveDisclosure.commit(Self.claims)
        #expect(throws: Never.self) {
            _ = try SelectiveDisclosure.reveal(disclosures: [], committedDigests: digests)
        }
        let two = disclosures.prefix(2).map(\.encoded)
        let revealed = try SelectiveDisclosure.reveal(disclosures: Array(two),
                                                      committedDigests: digests)
        #expect(revealed.count == 2)
        #expect(SelectiveDisclosure.withheldCount(committedDigests: digests,
                                                  revealed: revealed.count) == 3)
    }

    @Test("壞掉的揭露字串會被擋下，不會被當成空欄位")
    func refusesMalformedDisclosures() {
        for junk in ["not-base64url!!", Data("[1,2,3]".utf8).base64URLEncodedString(),
                     Data(#"["salt","name"]"#.utf8).base64URLEncodedString(),
                     Data(#"["","name","v"]"#.utf8).base64URLEncodedString()] {
            #expect(throws: (any Error).self) {
                _ = try SelectiveDisclosure.reveal(disclosures: [junk], committedDigests: [])
            }
        }
    }

    /// The digest is over the encoded string, not the decoded array, so a
    /// disclosure survives a round trip through the wire unchanged.
    @Test("編碼字串來回一趟，摘要不變")
    func digestIsStableAcrossTheWire() throws {
        let original = Disclosure(claimName: "birthdate", claimValue: "1990-01-01")
        let rebuilt = try #require(Disclosure(encoded: original.encoded))
        #expect(rebuilt == original)
        #expect(rebuilt.digest == original.digest)
    }
}
