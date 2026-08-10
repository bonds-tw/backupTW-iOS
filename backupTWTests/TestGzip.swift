//
//  TestGzip.swift
//  backupTWTests
//
//  Building gzip streams without a compressor.
//

import Foundation

/// Produces gzip fixtures from first principles: RFC 1952 header, RFC 1951
/// *stored* blocks, hand-rolled CRC32.
///
/// Deliberately not zlib's compressor. Testing an inflater against a deflater
/// from the same library proves only that the two agree with each other, and the
/// checksum a fixture carries must not be computed by the same code that later
/// verifies it. Stored blocks also let a payload of any size become a fixture
/// without a compressor being involved at all.
///
/// The construction was checked against `/usr/bin/gunzip` for empty, 12-byte,
/// 65535-byte and 1 MiB payloads before being written here — which is why this
/// lives in the test target rather than being generated at runtime: `Process`
/// does not exist on iOS, so a simulator test cannot shell out to `gzip`.
enum TestGzip {

    static func stored(_ payload: Data) -> Data {
        // RFC 1952 header: magic, CM=deflate, no flags, no mtime, OS=Unix.
        var output = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03])

        if payload.isEmpty {
            // One final, empty stored block.
            output.append(contentsOf: [0x01, 0x00, 0x00, 0xff, 0xff])
        } else {
            var offset = payload.startIndex
            while offset < payload.endIndex {
                let end = payload.index(offset, offsetBy: 65_535, limitedBy: payload.endIndex)
                    ?? payload.endIndex
                let block = payload[offset..<end]
                offset = end

                // BFINAL in bit 0, BTYPE=00 in bits 1-2, remaining bits padding.
                output.append(offset >= payload.endIndex ? 0x01 : 0x00)
                let length = UInt16(block.count)
                output.append(contentsOf: [UInt8(length & 0xff), UInt8(length >> 8)])
                let complement = ~length
                output.append(contentsOf: [UInt8(complement & 0xff), UInt8(complement >> 8)])
                output.append(contentsOf: block)
            }
        }

        appendLittleEndian(crc32(payload), to: &output)
        appendLittleEndian(UInt32(truncatingIfNeeded: payload.count), to: &output)
        return output
    }

    /// Deterministic, mildly compressible filler.
    static func pattern(count: Int) -> Data {
        var data = Data(capacity: count)
        for index in 0..<count {
            data.append(UInt8(truncatingIfNeeded: index &* 31 &+ (index >> 8)))
        }
        return data
    }

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: [
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff),
        ])
    }

    /// Textbook CRC-32/ISO-HDLC, written out rather than borrowed from zlib.
    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
