import AudioToolbox
import CoreBluetooth
import UIKit

/// Advertises the pad as a Claude Hardware Buddy on the Nordic UART Service and lets the desktop drive the face,
/// or Claude Code's hooks over Wi-Fi when a session reports through them (Bluetooth is ignored then).
/// While a prompt waits, the screen shows it with Allow and Deny; a tap on one answers it, and so does a two-finger
/// drag up or down.
final class BuddyLink: NSObject, CBPeripheralManagerDelegate {
    private static let service = CBUUID(string: "6e400001-b5a3-f393-e0a9-e50e24dcca9e")
    // Encryption-only characteristics make the first access trigger iOS pairing with a passkey.
    private let rx = CBMutableCharacteristic(type: CBUUID(string: "6e400002-b5a3-f393-e0a9-e50e24dcca9e"),
                                             properties: [.write, .writeWithoutResponse], value: nil, permissions: [.writeEncryptionRequired])
    private let tx = CBMutableCharacteristic(type: CBUUID(string: "6e400003-b5a3-f393-e0a9-e50e24dcca9e"),
                                             properties: [.notify], value: nil, permissions: [.readEncryptionRequired])
    private let buddy = Buddy(name: "Claude-yapa", now: CACurrentMediaTime())
    private let view: FaceView
    // While a Claude Code session reports through the hooks they drive the face and Bluetooth is ignored.
    private let hooks = HookListener()
    private var hooked = false
    private var manager: CBPeripheralManager!
    private var timer: Timer?
    private var outbox: [Data] = [], mtu = 20, wasConnected = false, wasWaiting = false, shown: Mood?, promptID: String?

    init(view: FaceView) {
        self.view = view
        super.init()
        UIDevice.current.isBatteryMonitoringEnabled = true
        manager = CBPeripheralManager(delegate: self, queue: nil)
        hooks.onChange = { [weak self] in
            guard let self else { return }
            let t = CACurrentMediaTime(), active = self.hooks.desk.active
            if active != self.hooked { self.log(active ? "hooks from the Mac" : "no hook sessions left") }
            self.hooked = active
            if active { self.buddy.receive(self.hooks.desk.line(at: t), at: t).forEach(self.send) }
            self.view.crowd.update(self.hooks.desk.members(at: t), at: t)
            self.view.show(replies: self.hooks.desk.replies())
            self.update()
        }
        view.onDecide = { [weak self] in self?.decide($0) ?? false }
        view.onAnswer = { [weak self] answers in
            guard let self, let id = self.hooks.desk.asked()?.id, self.hooks.answer(id, answers) else { return false }
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            self.log("answered \(id) \(Self.ms())")
            return true
        }
        view.canDecide = { [weak self] in self?.buddy.prompt(at: CACurrentMediaTime()) != nil }
        // A tap on a session's face brings its prompt forward, so the next tap answers that session's hook.
        view.onFocus = { [weak self] id in
            self?.hooks.desk.focus = id
            self?.hooks.onChange?()
        }
        // Every session's turn events go to the face's notice board; the time each notice lands is logged.
        buddy.onTurn = { [weak self] line in self?.notice(Data(line.utf8)) }
        hooks.onTurn = { [weak self] in self?.notice($0) }
        hooks.onLog = { [weak self] in self?.log($0) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.update() }
        // The sessions kept from before the app last quit come back as faces straight away.
        hooks.onChange?()
    }

    private func update() {
        let t = CACurrentMediaTime(), connected = buddy.connected(at: t), d = UIDevice.current
        var info = task_vm_info_data_t(), n = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        if withUnsafeMutablePointer(to: &info, { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n) } }) == KERN_SUCCESS {
            buddy.heap = Int(info.phys_footprint)
        }
        if d.batteryLevel >= 0 { buddy.battery = (Int(d.batteryLevel * 100), d.batteryState == .charging || d.batteryState == .full) }
        // Once the link drops the face sleeps, and taps go back to showing moods.
        // Only a change of mood reaches the face, so a face that dozed off on its own stays asleep through idle heartbeats.
        let mood = connected || wasConnected ? buddy.mood(at: t) : nil
        // Boredom never wakes a face that has dozed off.
        if let mood, mood != shown, !(mood == .bored && view.face.mood == .sleep) { view.face.set(mood, at: t) }
        shown = mood
        if connected != wasConnected { log(connected ? "heartbeats" : "no heartbeat for 30 s") }
        wasConnected = connected
        // Buzz when a session starts waiting, and again for each prompt a tap can answer.
        let id = buddy.prompt(at: t)?.id, waiting = buddy.waiting(at: t)
        if (waiting && !wasWaiting) || (id != nil && id != promptID) {
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            log(id.map { "prompt \($0) \(Self.ms())" } ?? "waiting, answer at the desktop")
        }
        promptID = id; wasWaiting = waiting
        if hooks.desk.active { view.ask(hooks.desk.asked()) } else { view.ask(buddy.prompt(at: t)) }
    }

    private func notice(_ event: Data) {
        for s in view.take(event) { log("notice \(s) \(Self.ms())") }
    }

    /// Answers the waiting prompt; false when none can be answered.
    private func decide(_ approve: Bool) -> Bool {
        let t = CACurrentMediaTime()
        guard let line = buddy.decide(approve, at: t) else { return false }
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        send(line)
        log("decided \(line.contains("\"once\"") ? "once" : "deny") \(Self.ms())")
        update()
        return true
    }

    private func send(_ line: String) {
        if hooks.decide(line) { return }
        let data = Data(line.utf8)
        outbox += stride(from: 0, to: data.count, by: mtu).map { data.subdata(in: $0..<min($0 + mtu, data.count)) }
        flush()
    }

    private func flush() {
        while let d = outbox.first, manager.updateValue(d, for: tx, onSubscribedCentrals: nil) { outbox.removeFirst() }
    }

    static func ms() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

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
        for r in requests where r.characteristic.uuid == rx.uuid && !hooks.desk.active {
            buddy.receive([UInt8](r.value ?? Data()), at: t).forEach(send)
        }
        if let r = requests.first { m.respond(to: r, withResult: .success) }
        update()
    }

    func peripheralManagerIsReady(toUpdateSubscribers _: CBPeripheralManager) { flush() }
}
