//
//  BluetoothLink.swift
//  backupTW
//
//  The radio. Framing and reassembly are `LinkTransport`'s; this only moves bytes.
//

import CoreBluetooth
import Foundation

// MARK: - Roles, and why they are this way round
//
// The **holder advertises** (peripheral) and the **verifier connects**
// (central). That is ISO 18013-5's "mdoc peripheral server mode", and it is the
// right way round here for reasons that have nothing to do with the standard:
//
//   * The verifier already put a code on screen, so it already has a channel to
//     say 「find me under this identifier」 — engagement is solved for free, and
//     `PresentationRequest.linkServiceID` is where it is said.
//   * A peripheral only exists while its owner is holding the phone up. The
//     holder decides when their identity becomes discoverable, which is the
//     same decision the 出示 screen already asks them to make.
//   * A verifier that advertised would be a fixed installation broadcasting all
//     day. A holder that advertises does so for the length of one exchange,
//     under a UUID minted for that exchange.
//
// # What is on the air
//
// The presentation, in frames, in the clear. This is not an oversight and it is
// not something to fix at this layer:
//
//   * the payload is signed and carries the verifier's challenge, so nothing
//     received here can be forged, replayed into a different check, or altered
//     — `OfflineVerifier` establishes all of that after it lands;
//   * an eavesdropper with a radio learns exactly what an eavesdropper with a
//     camera learns today, which is what the QR carousel has always broadcast to
//     anyone standing behind the checker;
//   * BLE's own pairing would not help. Two strangers at a counter cannot
//     compare a passkey that means anything, and a transport that invented its
//     own encryption would be a second security story nobody had reviewed.
//
// ISO 18013-5 does specify session encryption, and this app does not implement
// it. That is a real gap against that standard and it is named here rather than
// implied away. What it buys — confidentiality against a bystander — is worth
// having; what it costs is a key agreement whose engagement half has to be
// designed, and neither half exists yet.
//
// # Why this file is thin
//
// Every decision lives in `LinkTransport`, which needs no radio to test.
// CoreBluetooth cannot run in the simulator at all, so anything with a
// judgement in it that lived here would be a judgement nobody could exercise —
// the same split, for the same reason, as `RevocationCheck` and
// `OpenACRevocation`.

/// The characteristic frames travel on, and the one the receiver acknowledges
/// completion with.
///
/// Fixed UUIDs, unlike the service's: the *service* has to be unlinkable
/// because it is what gets broadcast, while these are only visible to a device
/// that has already connected to a service it was told about.
enum BluetoothLinkCharacteristic {
    /// Holder → verifier. Notifications, because the sender is the peripheral.
    static let frames = CBUUID(string: "2B1D0001-6B4E-4C3A-9E2F-4A7C51E0D9A1")
    /// Verifier → holder, one byte, so the holder's screen can stop.
    static let state = CBUUID(string: "2B1D0002-6B4E-4C3A-9E2F-4A7C51E0D9A1")

    /// The single byte the verifier writes when a payload reassembled.
    static let received: UInt8 = 0x01
}

/// What either end is doing, in words a screen can use.
enum BluetoothLinkState: Equatable {
    /// Bluetooth is off, unauthorised, or unsupported. `reason` is for a human.
    case unavailable(reason: String)
    /// Powering on and publishing the service — not yet on the air.
    case starting
    /// Advertising (holder) or scanning (verifier), nobody connected yet.
    case waiting
    /// Connected; `fraction` is 0...1 of the payload moved.
    case transferring(fraction: Double)
    /// Done. The verifier gets the payload; the holder gets an empty one.
    case finished(payload: Data)
    /// Gave up. `reason` is for a human.
    case failed(reason: String)
}

// MARK: - Holder side

/// Advertises one payload under a one-time service identifier, and sends it to
/// the first device that subscribes.
///
/// One payload, one service ID, one exchange. Nothing here is reused between
/// presentations — a peripheral that stayed up would keep broadcasting after the
/// holder had put their phone away.
final class BluetoothLinkPeripheral: NSObject {

    private let payload: Data
    private let serviceID: CBUUID
    private let onState: (BluetoothLinkState) -> Void

    private var manager: CBPeripheralManager?
    private var characteristic: CBMutableCharacteristic?
    private var frames: [Data] = []
    private var nextFrame = 0
    private var subscriber: CBCentral?

    init(payload: Data, serviceID: UUID, onState: @escaping (BluetoothLinkState) -> Void) {
        self.payload = payload
        self.serviceID = CBUUID(nsuuid: serviceID)
        self.onState = onState
        super.init()
    }

    func start() {
        // The manager is created here rather than in `init` so that nothing is
        // powered on — and no permission prompt appears — until the holder has
        // actually chosen to present.
        // Reported before CoreBluetooth has said anything: if this line never
        // runs, every sentence below is unreachable and the screen keeping its
        // opening text is the only symptom.
        onState(.starting)
        manager = CBPeripheralManager(delegate: self, queue: .main)
    }

    func stop() {
        manager?.stopAdvertising()
        manager?.removeAllServices()
        manager = nil
        subscriber = nil
    }

    deinit { stop() }

    /// Pushes frames until CoreBluetooth's queue is full, then waits to be
    /// called again from `peripheralManagerIsReady`.
    ///
    /// `updateValue` returning false is normal back-pressure, not an error: the
    /// frame that failed must be retried, which is why `nextFrame` is only
    /// advanced on success. Getting that wrong drops a frame silently and the
    /// receiver waits forever for a chunk that was never resent.
    private func pump() {
        guard let manager, let characteristic, let subscriber else { return }
        while nextFrame < frames.count {
            let sent = manager.updateValue(frames[nextFrame],
                                           for: characteristic,
                                           onSubscribedCentrals: [subscriber])
            guard sent else { return }
            nextFrame += 1
            onState(.transferring(fraction: Double(nextFrame) / Double(frames.count)))
        }
    }
}

extension BluetoothLinkPeripheral: CBPeripheralManagerDelegate {

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            let frames = CBMutableCharacteristic(type: BluetoothLinkCharacteristic.frames,
                                                 properties: [.notify],
                                                 value: nil,
                                                 permissions: [.readable])
            let state = CBMutableCharacteristic(type: BluetoothLinkCharacteristic.state,
                                                properties: [.write, .writeWithoutResponse],
                                                value: nil,
                                                permissions: [.writeable])
            let service = CBMutableService(type: serviceID, primary: true)
            service.characteristics = [frames, state]
            self.characteristic = frames
            // Advertising starts in `didAdd`, not here. Publishing a service is
            // asynchronous, and advertising a service the stack has not finished
            // registering is how the first device attempt failed: the phone said
            // 「waiting」 and no scanner ever saw it, because there was nothing on
            // the air. Measured 2026-08-12 — the Mac peer scanned for fifteen
            // minutes and never discovered a peripheral.
            peripheral.add(service)
            onState(.starting)
        case .poweredOff:
            onState(.unavailable(reason: NSLocalizedString("Bluetooth is switched off.", comment: "")))
        case .unauthorized:
            onState(.unavailable(reason: NSLocalizedString("This app is not allowed to use Bluetooth. You can change that in Settings.", comment: "")))
        case .unsupported:
            onState(.unavailable(reason: NSLocalizedString("This device cannot use Bluetooth for this.", comment: "")))
        case .unknown, .resetting:
            onState(.unavailable(reason: String(format: NSLocalizedString("Bluetooth is not ready (state %d).", comment: ""),
                                                peripheral.state.rawValue)))
        @unknown default:
            onState(.unavailable(reason: String(format: NSLocalizedString("Bluetooth is not ready (state %d).", comment: ""),
                                                peripheral.state.rawValue)))
        }
    }

    /// Both of these were missing, and their absence is the whole reason the
    /// first attempt could not be diagnosed: a service that fails to publish and
    /// an advertisement that fails to start are both *silent*, and the screen
    /// went on saying the same reassuring sentence either way.
    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didAdd service: CBService,
                           error: Error?) {
        if let error {
            onState(.failed(reason: String(format: NSLocalizedString("Bluetooth could not be set up on this phone (%@).", comment: ""),
                                           error.localizedDescription)))
            return
        }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [serviceID]])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            onState(.failed(reason: String(format: NSLocalizedString("This phone could not make itself discoverable (%@).", comment: ""),
                                           error.localizedDescription)))
            return
        }
        onState(.waiting)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        // Framed only now, because only now is the MTU known. Framing at
        // `start()` against a guessed MTU is how a transfer ends up split for a
        // link that turned out to be able to carry four times as much.
        guard subscriber == nil else { return }
        subscriber = central
        do {
            frames = try LinkTransport.frames(for: payload,
                                              maximumFrameBytes: central.maximumUpdateValueLength)
            nextFrame = 0
            onState(.transferring(fraction: 0))
            pump()
        } catch {
            onState(.failed(reason: NSLocalizedString("This document could not be prepared for sending.", comment: "")))
        }
    }

    /// The checker went away.
    ///
    /// Without this method, a disconnect mid-transfer meant `pump()` was simply
    /// never called again — the holder's screen kept 「傳送… 47%」 for as long as
    /// they were willing to hold the phone up, and nothing on either device said
    /// otherwise. It is the plainest example of the failure the audit went
    /// looking for: a state with no screen at all.
    ///
    /// Clearing `subscriber` is the other half. `didSubscribeTo` guards on
    /// `subscriber == nil`, so a stale one meant the checker could not reconnect
    /// and try again either — the transfer was over, permanently, and the app
    /// still looked busy.
    func peripheralManager(_ peripheral: CBPeripheralManager,
                           central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard central.identifier == subscriber?.identifier else { return }
        let wasIncomplete = nextFrame < frames.count
        subscriber = nil
        nextFrame = 0
        if wasIncomplete {
            onState(.failed(reason: NSLocalizedString(
                "The other phone disconnected before the whole proof had been sent. Ask them to scan the code again.",
                comment: "Bluetooth send failure")))
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        pump()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didReceiveWrite requests: [CBATTRequest]) {
        for request in requests where request.characteristic.uuid == BluetoothLinkCharacteristic.state {
            if request.value?.first == BluetoothLinkCharacteristic.received {
                onState(.finished(payload: Data()))
            }
        }
        peripheral.respond(to: requests[0], withResult: .success)
    }
}

// MARK: - Verifier side

/// Scans for one service identifier, connects, and collects frames until the
/// payload is whole.
final class BluetoothLinkCentral: NSObject {

    private let serviceID: CBUUID
    private let onState: (BluetoothLinkState) -> Void
    private let collector = LinkCollector()

    private var manager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var stateCharacteristic: CBCharacteristic?

    /// Held between reassembly and the acknowledgement resolving. Non-nil means
    /// 「complete, not yet reported」; clearing it is what makes delivery
    /// happen exactly once whichever of the two paths gets there first.
    private var pendingPayload: Data?

    /// How long to wait for the acknowledgement write before reporting anyway.
    /// Short, because the alternative to waiting is a verifier holding a
    /// finished document and saying nothing.
    private static let acknowledgementTimeout: TimeInterval = 1.5

    init(serviceID: UUID, onState: @escaping (BluetoothLinkState) -> Void) {
        self.serviceID = CBUUID(nsuuid: serviceID)
        self.onState = onState
        super.init()
    }

    func start() {
        manager = CBCentralManager(delegate: self, queue: .main)
    }

    func stop() {
        if let peripheral { manager?.cancelPeripheralConnection(peripheral) }
        manager?.stopScan()
        manager = nil
        peripheral = nil
    }

    deinit { stop() }
}

extension BluetoothLinkCentral: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            // Scoped to the one service the request named. A scan with no
            // service filter is a scan that sees every BLE device in the room,
            // and there is no reason for this app to have that view.
            central.scanForPeripherals(withServices: [serviceID], options: nil)
            onState(.waiting)
        case .poweredOff:
            onState(.unavailable(reason: NSLocalizedString("Bluetooth is switched off.", comment: "")))
        case .unauthorized:
            onState(.unavailable(reason: NSLocalizedString("This app is not allowed to use Bluetooth. You can change that in Settings.", comment: "")))
        case .unsupported:
            onState(.unavailable(reason: NSLocalizedString("This device cannot use Bluetooth for this.", comment: "")))
        case .unknown, .resetting:
            onState(.unavailable(reason: String(format: NSLocalizedString("Bluetooth is not ready (state %d).", comment: ""),
                                                central.state.rawValue)))
        @unknown default:
            onState(.unavailable(reason: String(format: NSLocalizedString("Bluetooth is not ready (state %d).", comment: ""),
                                                central.state.rawValue)))
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        guard self.peripheral == nil else { return }
        // Held before connecting: `CBCentralManager` does not retain the
        // peripherals it hands out, and one that is released mid-connect
        // produces a connection that never calls back.
        self.peripheral = peripheral
        central.stopScan()
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([serviceID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        onState(.failed(reason: NSLocalizedString("The other phone could not be reached.", comment: "")))
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        // Only a failure if the payload had not arrived. A holder whose screen
        // moves on the moment the transfer finishes disconnects normally.
        //
        // `error != nil` used to be part of this condition, and it meant a
        // *clean* disconnect halfway through said nothing at all — which is the
        // common case, because the holder pressing Done is a clean disconnect.
        // Whether the other end hung up politely is not a fact the checker
        // needs; whether the proof arrived is.
        if collector.progress != nil {
            onState(.failed(reason: NSLocalizedString("The connection ended before the whole document arrived.", comment: "")))
        }
    }
}

extension BluetoothLinkCentral: CBPeripheralDelegate {

    /// Reports the finished payload at most once.
    ///
    /// Three things can reach here — the acknowledgement's write callback, its
    /// timeout, and the no-acknowledgement path — and a caller that tears down
    /// on `.finished` must not be handed a second one. `pendingPayload` is both
    /// the value and the flag: clearing it is what closes the door.
    ///
    /// The first version of this was a single guard trying to serve both
    /// `.finished` and every other state, and it got the no-acknowledgement path
    /// backwards — that call set no `pendingPayload`, so the guard swallowed it
    /// and a peripheral offering no state characteristic would have delivered
    /// its bytes and then said nothing at all. Two lines and one job instead.
    fileprivate func deliverFinished() {
        guard let payload = pendingPayload else { return }
        pendingPayload = nil
        onState(.finished(payload: payload))
    }

    /// The other end has been told — or telling it failed, which is reported the
    /// same way because the document is here either way and the checker is
    /// waiting on a verdict, not on a receipt.
    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == BluetoothLinkCharacteristic.state else { return }
        deliverFinished()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceID }) else {
            onState(.failed(reason: NSLocalizedString("The other phone is not offering a document.", comment: "")))
            return
        }
        peripheral.discoverCharacteristics([BluetoothLinkCharacteristic.frames,
                                            BluetoothLinkCharacteristic.state], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == BluetoothLinkCharacteristic.frames {
                peripheral.setNotifyValue(true, for: characteristic)
            } else if characteristic.uuid == BluetoothLinkCharacteristic.state {
                stateCharacteristic = characteristic
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == BluetoothLinkCharacteristic.frames,
              let frame = characteristic.value else { return }
        do {
            switch try collector.accept(frame) {
            case .accepted(let progress), .duplicate(let progress):
                onState(.transferring(fraction: progress.fraction))
            case .completed(let payload):
                // The acknowledgement is written **and waited for** before
                // `.finished` is reported, and that ordering is a bug fix with
                // a device run behind it.
                //
                // It used to write and report in the same breath. Every caller
                // tears the link down on `.finished` — correctly, so that a
                // second transfer cannot stack a second result — and tearing it
                // down cancels the connection the write was still travelling
                // on. Measured 2026-08-13, Mac↔iPhone: the phone reassembled all
                // twelve frames and rendered a verdict, and the sender's log
                // never printed its acknowledgement line. On a real holder's
                // phone that is a screen stuck at 「傳送中… 100%」 for a document
                // that arrived.
                //
                // So the contract is now: when a caller sees `.finished`, the
                // other end has been told, or telling it has definitively
                // failed. Either way the caller may tear down.
                pendingPayload = payload
                guard let stateCharacteristic else {
                    // Nothing to acknowledge to, so nothing to wait for.
                    deliverFinished()
                    return
                }
                peripheral.writeValue(Data([BluetoothLinkCharacteristic.received]),
                                      for: stateCharacteristic,
                                      type: .withResponse)
                // A write that is never answered must not hold the result
                // hostage: the payload is complete and checkable regardless of
                // whether the sender ever learns so.
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.acknowledgementTimeout) { [weak self] in
                    self?.deliverFinished()
                }
            }
        } catch let error as LinkTransportError {
            // Two layers, because they mean opposite things.
            //
            // A frame that will not parse is noise — a stray packet from
            // another phone in the room is the expected reason to be here, and
            // reporting it would make a working transfer look broken.
            //
            // A failure at *reassembly* is not noise. Every frame arrived, the
            // collector emptied itself (see `LinkCollector`), and there is now
            // nothing on screen to say so: without this the checker watches
            // 「接收中… 100%」 for ever. It matters most on the ZK path, which is
            // 597 frames and has no camera to fall back to.
            switch error {
            case .reassemblyDigestMismatch, .payloadTooLarge:
                onState(.failed(reason: NSLocalizedString(
                    "The proof arrived damaged. Ask them to send it again.",
                    comment: "Bluetooth reassembly failure")))
            default:
                return
            }
        } catch {
            return
        }
    }
}
