//
//  EngagementExport.swift
//  backupTW
//
//  A development-only way to get the code off the screen without a camera.
//

import Foundation

#if DEBUG
/// Writes whatever code a verifier screen is currently showing to a file, so a
/// test rig can read it off the device.
///
/// # Why this exists
///
/// The Bluetooth exchange needs the holder to learn the verifier's service
/// identifier, and the only channel for that is the QR on the verifier's screen.
/// With one phone in the room, the other end is a Mac — and pointing a MacBook's
/// camera at a phone screen turned out to be the least reliable part of the
/// whole rig. It worked once and then did not, which is the worst kind of test
/// apparatus: one that fails in a way that looks like the thing under test
/// failing.
///
/// So this writes the same string the QR encodes, byte for byte, to the app's
/// Documents directory, where `xcrun devicectl device copy from` can fetch it.
/// Nothing about the exchange changes — the rig still learns the identifier the
/// way a holder would, it just reads it through a cable instead of a lens.
///
/// `#if DEBUG` around the whole file, and the call sites are guarded too. A
/// Release build has no code that writes a live verification request to a
/// world-readable directory, and that is not a detail to leave to a linker.
enum EngagementExport {

    /// Named for the screen rather than the format: two screens export two
    /// different things (a `PresentationRequest` and a `ZKLinkEngagement`) and a
    /// rig pointed at the wrong one should notice.
    enum Kind: String {
        case credential = "engagement-credential.json"
        case zeroKnowledge = "engagement-zk.json"
    }

    static func write(_ text: String, kind: Kind) {
        guard let directory = try? FileManager.default.url(for: .documentDirectory,
                                                           in: .userDomainMask,
                                                           appropriateFor: nil,
                                                           create: true) else { return }
        // Failure is silent on purpose: this is scaffolding, and a screen that
        // refused to show a QR because a debug file could not be written would
        // be scaffolding that broke the thing it was built to observe.
        try? Data(text.utf8).write(to: directory.appendingPathComponent(kind.rawValue),
                                   options: [.atomic])
    }
}
#endif
