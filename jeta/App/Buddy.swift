import AudioToolbox
import CoreBluetooth
import UIKit

/// Advertises the pad as a Claude Hardware Buddy on the Nordic UART Service and lets the desktop drive the face.
/// While a prompt waits, a tap on the top half approves it and one on the bottom half denies it.
final class BuddyLink: NSObject, CBPeripheralManagerDelegate {
    private static let service = CBUUID(string: "6e400001-b5a3-f393-e0a9-e50e24dcca9e")
    // Encryption-only characteristics make the first access trigger iOS pairing with a passkey.
    private let rx = CBMutableCharacteristic(type: CBUUID(string: "6e400002-b5a3-f393-e0a9-e50e24dcca9e"),
                                             properties: [.write, .writeWithoutResponse], value: nil, permissions: [.writeEncryptionRequired])
    private let tx = CBMutableCharacteristic(type: CBUUID(string: "6e400003-b5a3-f393-e0a9-e50e24dcca9e"),
                                             properties: [.notify], value: nil, permissions: [.readEncryptionRequired])
    private let buddy = Buddy(name: "Claude-yapa", now: CACurrentMediaTime())
    private let view: FaceView
    private var manager: CBPeripheralManager!
    private var timer: Timer?
    private var outbox: [Data] = [], mtu = 20, wasConnected = false, promptID: String?

    init(view: FaceView) {
        self.view = view
        super.init()
        UIDevice.current.isBatteryMonitoringEnabled = true
        manager = CBPeripheralManager(delegate: self, queue: nil)
        view.onTap = { [weak self] p in self?.tap(at: p) ?? false }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.update() }
    }

    private func update() {
        let t = CACurrentMediaTime(), connected = buddy.connected(at: t), d = UIDevice.current
        if d.batteryLevel >= 0 { buddy.battery = (Int(d.batteryLevel * 100), d.batteryState == .charging || d.batteryState == .full) }
        // Once the link drops the face sleeps, and taps go back to showing moods.
        if connected || wasConnected { view.face.set(buddy.mood(at: t), at: t) }
        if connected != wasConnected { log(connected ? "heartbeats" : "no heartbeat for 30 s") }
        wasConnected = connected
        let id = buddy.prompt(at: t)?.id
        if let id, id != promptID { AudioServicesPlaySystemSound(kSystemSoundID_Vibrate) }
        promptID = id
    }

    private func tap(at p: CGPoint) -> Bool {
        let t = CACurrentMediaTime()
        guard buddy.connected(at: t) else { return false }
        if let line = buddy.decide(p.y < view.bounds.midY, at: t) {
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            send(line)
            update()
        }
        return true
    }

    private func send(_ line: String) {
        let data = Data(line.utf8)
        outbox += stride(from: 0, to: data.count, by: mtu).map { data.subdata(in: $0..<min($0 + mtu, data.count)) }
        flush()
    }

    private func flush() {
        while let d = outbox.first, manager.updateValue(d, for: tx, onSubscribedCentrals: nil) { outbox.removeFirst() }
    }

    /// Appends to Documents/buddy.log, which is how to see the link's state on the phone (over SSH).
    private func log(_ s: String) {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("buddy.log")
        let line = Data("\(Date()) \(s)\n".utf8)
        if let h = try? FileHandle(forWritingTo: url), (try? h.seekToEnd()) ?? 0 < 1_000_000 { h.write(line); try? h.close() }
        else { try? line.write(to: url) }
    }

    func peripheralManagerDidUpdateState(_ m: CBPeripheralManager) {
        log("bluetooth state \(m.state.rawValue)")
        guard m.state == .poweredOn else { return }
        let s = CBMutableService(type: Self.service, primary: true)
        s.characteristics = [rx, tx]
        m.removeAllServices()
        m.add(s)
    }

    func peripheralManager(_ m: CBPeripheralManager, didAdd _: CBService, error: Error?) {
        log("service added \(error.map { "\($0)" } ?? "ok")")
        guard error == nil else { return }
        m.startAdvertising([CBAdvertisementDataLocalNameKey: "Claude-yapa", CBAdvertisementDataServiceUUIDsKey: [Self.service]])
    }

    func peripheralManagerDidStartAdvertising(_: CBPeripheralManager, error: Error?) {
        log("advertising \(error.map { "\($0)" } ?? "ok")")
    }

    func peripheralManager(_ m: CBPeripheralManager, central: CBCentral, didSubscribeTo _: CBCharacteristic) {
        log("subscribed, mtu \(central.maximumUpdateValueLength)")
        mtu = central.maximumUpdateValueLength
    }

    func peripheralManager(_ m: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        // RX only accepts encrypted writes, so any write that arrives came over an encrypted link.
        buddy.secure = true
        let t = CACurrentMediaTime()
        for r in requests where r.characteristic.uuid == rx.uuid {
            buddy.receive([UInt8](r.value ?? Data()), at: t).forEach(send)
        }
        if let r = requests.first { m.respond(to: r, withResult: .success) }
        update()
    }

    func peripheralManagerIsReady(toUpdateSubscribers _: CBPeripheralManager) { flush() }
}
