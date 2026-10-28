import CoreBluetooth
import UIKit

/// The WHOOP 5.0 / MG strap: a standing Bluetooth link plus the history download.
///
/// Pairing: on iPhone only the official WHOOP app can create the strap's encrypted
/// bond (the strap exposes nothing readable that would make iOS start pairing for
/// us). iOS shares that bond with every app on the phone, so this app adopts the
/// already-paired strap. If the strap is ever "Forgotten" in Bluetooth settings, the
/// WHOOP app has to pair it again.
///
/// Each connection: subscribe, CLIENT_HELLO, set the strap's clock (a strap without
/// one stores nothing), then drain its history. The strap keeps about two weeks, so
/// time away from the phone (a run) arrives on the next connect. The drain stores
/// every chunk before acknowledging it, because an acknowledged chunk may be erased.
/// While connected it drains again every 15 minutes; like RingWatcher, a pending
/// connect plus state restoration wakes the app when the strap comes back in range.
final class WhoopLink: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    static let shared = WhoopLink()
    private static let restoreID = "md.thomas.openoura.whoop"
    private static let peripheralKey = "whoop.peripheral-uuid"
    static let drainGap: TimeInterval = 15 * 60
    /// A strap's attempt can end while a backlog remains; keep asking, within reason.
    private static let maxPasses = 40

    enum LinkState: String {
        case none = "Not set up"
        case off = "Bluetooth off"
        case searching = "Looking for the strap"
        case waiting = "Waiting for the strap"
        case connecting = "Connecting"
        case ready = "Connected"
        case downloading = "Downloading history"
    }

    // UI state, main thread only.
    @Published private(set) var state: LinkState = .none
    @Published private(set) var known = UserDefaults.standard.string(forKey: WhoopLink.peripheralKey) != nil
    @Published private(set) var battery: Int?
    @Published private(set) var firmware: String? = UserDefaults.standard.string(forKey: "whoop.firmware")
    @Published private(set) var clockSet: Bool?
    @Published private(set) var issue: String?
    @Published private(set) var liveBPM: Int?
    @Published private(set) var skinTemp: Double?
    @Published private(set) var lastDrainAt: Date? = UserDefaults.standard.object(forKey: "whoop.drain.at") as? Date
    @Published private(set) var lastDrainSeconds = UserDefaults.standard.integer(forKey: "whoop.drain.n")

    // Link state, `queue` only.
    private let queue = DispatchQueue(label: "md.thomas.openoura.whoop", qos: .utility)
    private var central: CBCentralManager?
    private var strap: CBPeripheral?
    private var commandChar: CBCharacteristic?
    private var subscribed: Set<CBUUID> = []
    private var assemblers: [CBUUID: WhoopWire.Reassembler] = [:]
    private var helloSent = false
    private var ready = false
    private var seq: UInt8 = 1
    private var waiting: [UInt16: (WhoopResponse?) -> Void] = [:]
    private var scanTimeout: DispatchWorkItem?

    private var draining = false
    private var drainReason = ""
    private var chunk: [WhoopSample] = []
    private var passSeconds = 0
    private var totalSeconds = 0
    private var passes = 0
    private var watchdog: DispatchWorkItem?
    private var lastDrainEnded = Date.distantPast
    private var lastLivePublish = Date.distantPast

    private static let serviceUUID = CBUUID(string: WhoopWire.service)
    private static let commandUUID = CBUUID(string: WhoopWire.commandChar)
    private static let notifyUUIDs = Set(WhoopWire.notifyChars.map { CBUUID(string: $0) })
    private static let batteryService = CBUUID(string: "180F")
    private static let batteryLevel = CBUUID(string: "2A19")

    // MARK: Entry points

    /// Call at launch, before the app finishes launching, so a restoration relaunch
    /// finds a central with the same identifier.
    func start() {
        queue.async { [self] in
            guard central == nil else { return }
            central = CBCentralManager(delegate: self, queue: queue,
                                       options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreID,
                                                 CBCentralManagerOptionShowPowerAlertKey: false])
        }
    }

    /// "Connect WHOOP": adopt the strap the WHOOP app paired, or find it by scanning.
    /// Whether a strap has been connected; background scheduling keys off it too.
    static var isSetUp: Bool { UserDefaults.standard.string(forKey: peripheralKey) != nil }

    func connectNew() {
        WhoopHealth.shared.authorize()
        queue.async { [self] in
            guard let central, central.state == .poweredOn else {
                ui { self.issue = "Turn Bluetooth on, then try again." }
                return
            }
            if let paired = central.retrieveConnectedPeripherals(withServices: [Self.serviceUUID]).first {
                adopt(paired)
                return
            }
            ui { self.state = .searching; self.issue = nil }
            central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
            let timeout = DispatchWorkItem { [self] in
                guard central.isScanning else { return }
                central.stopScan()
                ui {
                    self.state = self.known ? .waiting : .none
                    self.issue = "No WHOOP strap found. Keep it close, make sure the WHOOP app has paired it with this iPhone, and try again."
                }
            }
            scanTimeout = timeout
            queue.asyncAfter(deadline: .now() + 30, execute: timeout)
        }
    }

    /// Stop using the strap (the bond itself stays with iOS).
    func forget() {
        queue.async { [self] in
            if let strap { central?.cancelPeripheralConnection(strap) }
            strap = nil
            ready = false
            UserDefaults.standard.removeObject(forKey: Self.peripheralKey)
            ui { self.known = false; self.state = .none; self.battery = nil; self.liveBPM = nil }
        }
    }

    /// A wake from elsewhere (background task, Health update, "Download now").
    func kick(reason: String, force: Bool = false) {
        queue.async { [self] in
            if ready { maybeDrain(reason: reason, force: force) } else { watchKnownStrap() }
        }
    }

    // MARK: Connection

    private func adopt(_ peripheral: CBPeripheral) {
        scanTimeout?.cancel()
        if central?.isScanning == true { central?.stopScan() }
        if let strap, strap !== peripheral { central?.cancelPeripheralConnection(strap) }
        strap = peripheral
        peripheral.delegate = self
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.peripheralKey)
        ui { self.known = true; self.state = .connecting; self.issue = nil }
        dlog("whoop", "adopting strap \(peripheral.identifier.uuidString.suffix(12))")
        if peripheral.state == .connected { setUp(peripheral) } else { central?.connect(peripheral, options: nil) }
    }

    private func watchKnownStrap() {
        guard let central, central.state == .poweredOn,
              let id = UserDefaults.standard.string(forKey: Self.peripheralKey).flatMap(UUID.init(uuidString:)) else { return }
        if let strap, strap.identifier == id, strap.state == .connected || strap.state == .connecting { return }
        let found = central.retrievePeripherals(withIdentifiers: [id]).first
            ?? central.retrieveConnectedPeripherals(withServices: [Self.serviceUUID]).first { $0.identifier == id }
        guard let peripheral = found else {
            dlog("whoop", "strap unknown to iOS; tap Connect WHOOP")
            ui { self.state = .waiting }
            return
        }
        strap = peripheral
        peripheral.delegate = self
        if peripheral.state == .connected { setUp(peripheral) } else { central.connect(peripheral, options: nil) }
        ui { self.state = .waiting }
    }

    private func setUp(_ peripheral: CBPeripheral) {
        resetSession()
        ui { self.state = .connecting }
        peripheral.discoverServices([Self.serviceUUID, Self.batteryService])
    }

    private func resetSession() {
        ready = false
        helloSent = false
        commandChar = nil
        subscribed = []
        assemblers = [:]
        let pending = waiting.values
        waiting = [:]
        pending.forEach { $0(nil) }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        strap = restored.first
        strap?.delegate = self
        dlog("whoop", "restored by iOS with \(restored.count) peripheral(s)")
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            ready = false
            ui { self.state = self.known ? .off : .none }
            return
        }
        if let strap, strap.state == .connected { setUp(strap) } else { watchKnownStrap() }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        dlog("whoop", "found \(peripheral.name ?? "strap") rssi \(RSSI)")
        adopt(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        dlog("whoop", "connected")
        guard peripheral === strap else { return }
        setUp(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === strap else { return }
        dlog("whoop", "disconnected: \(error.map { String(describing: $0) } ?? "clean"); re-arming")
        if draining { finishDrain(note: "link dropped") }
        resetSession()
        ui { self.state = .waiting; self.liveBPM = nil }
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === strap else { return }
        dlog("whoop", "connect failed: \(error.map { String(describing: $0) } ?? "no error"); re-arming")
        central.connect(peripheral, options: nil)
    }

    // MARK: GATT

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { dlog("whoop", "service discovery: \(error)") }
        for service in peripheral.services ?? [] where [Self.serviceUUID, Self.batteryService].contains(service.uuid) {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            if c.uuid == Self.commandUUID { commandChar = c }
            if Self.notifyUUIDs.contains(c.uuid) {
                assemblers[c.uuid] = WhoopWire.Reassembler()
                peripheral.setNotifyValue(true, for: c)
            }
            if c.uuid == Self.batteryLevel {
                peripheral.readValue(for: c)
                peripheral.setNotifyValue(true, for: c)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        guard Self.notifyUUIDs.contains(c.uuid) else { return }
        if let error {
            notPaired(error)
            return
        }
        if c.isNotifying { subscribed.insert(c.uuid) }
        guard subscribed == Self.notifyUUIDs, !helloSent, let commandChar else { return }
        helloSent = true
        // CLIENT_HELLO is GET_HELLO with sequence 1; its final reply carries the firmware.
        waiting[UInt16(WhoopCommand.getHello.rawValue) << 8 | 1] = { [self] response in
            guard let fw = response?.helloFirmware else { return }
            UserDefaults.standard.set(fw, forKey: "whoop.firmware")
            ui { self.firmware = fw }
        }
        peripheral.writeValue(Data(WhoopWire.clientHello), for: commandChar, type: .withResponse)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        guard c.uuid == Self.commandUUID else { return }
        if let error {
            if ready { dlog("whoop", "command write: \(error)") } else { notPaired(error) }
            return
        }
        guard !ready else { return }
        ready = true
        dlog("whoop", "link ready")
        ui { self.state = .ready; self.issue = nil }
        setClock { [self] in maybeDrain(reason: "Strap connected", force: false) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard error == nil, let value = c.value else { return }
        if c.uuid == Self.batteryLevel, let pct = value.first {
            ui { self.battery = Int(pct) }
            return
        }
        guard var assembler = assemblers[c.uuid] else { return }
        let frames = assembler.append(value)
        assemblers[c.uuid] = assembler
        frames.forEach(handle)
        if ready, !draining { maybeDrain(reason: "Strap connected", force: false) }
    }

    /// Writes to the WHOOP service need the encrypted bond only the WHOOP app can create.
    private func notPaired(_ error: Error) {
        dlog("whoop", "not paired with this iPhone: \(error)")
        ui {
            self.state = .waiting
            self.issue = "This iPhone isn't paired with the strap (\(error.localizedDescription)). Open the WHOOP app so it pairs the strap, then tap Connect WHOOP again."
        }
    }

    // MARK: Commands

    private func send(_ command: WhoopCommand, body: [UInt8], timeout: TimeInterval = 8,
                      completion: @escaping (WhoopResponse?) -> Void = { _ in }) {
        guard let strap, let commandChar else { completion(nil); return }
        seq = seq == 255 ? 2 : seq + 1
        let key = UInt16(command.rawValue) << 8 | UInt16(seq)
        waiting[key] = completion
        strap.writeValue(Data(WhoopWire.command(command.rawValue, seq: seq, body: body)), for: commandChar, type: .withResponse)
        queue.asyncAfter(deadline: .now() + timeout) { [self] in
            waiting.removeValue(forKey: key)?(nil)
        }
    }

    /// The strap only records while it has a clock, and the WHOOP app that used to
    /// set it is going away, so set it on every connect.
    private func setClock(then next: @escaping () -> Void) {
        send(.setClock, body: WhoopCommand.clockBody(Date())) { [self] response in
            if response?.result == .success {
                ui { self.clockSet = true }
                next()
                return
            }
            send(.setClockLegacy, body: WhoopCommand.legacyClockBody(Date())) { [self] legacy in
                let ok = legacy?.result == .success
                dlog("whoop", "clock: 146 → \(response.map { String($0.resultByte) } ?? "no reply"), 10 → \(legacy.map { String($0.resultByte) } ?? "no reply")")
                ui { self.clockSet = ok }
                next()
            }
        }
    }

    // MARK: Frames

    private func handle(_ frame: [UInt8]) {
        let type = frame[8]
        if let response = WhoopResponse(frame: frame) {
            guard response.result != .pending else { return }
            let key = UInt16(response.command) << 8 | UInt16(response.originSeq)
            waiting.removeValue(forKey: key)?(response)
            return
        }
        if draining, WhoopPacket.isOffload(type) { armWatchdog() }
        if type == WhoopPacket.historical, draining {
            if let sample = WhoopSample(r18: frame) { chunk.append(sample) }
        } else if let meta = WhoopMeta(frame: frame), draining {
            handleMeta(meta)
        } else if let beat = WhoopLiveBeat(frame: frame), Date().timeIntervalSince(lastLivePublish) >= 5 {
            lastLivePublish = Date()
            ui { self.liveBPM = beat.bpm }
        }
    }

    private func handleMeta(_ meta: WhoopMeta) {
        switch meta {
        case .start:
            break
        case .end(let block):
            do {
                try WhoopStore.shared.append(chunk)
            } catch {
                // Not acknowledged, so the strap keeps the chunk and resends it.
                dlog("whoop", "couldn't store a chunk: \(error)")
                finishDrain(note: "couldn't save to the phone")
                return
            }
            passSeconds += chunk.count
            if let oldest = chunk.map(\.unix).min() { WhoopHealth.shared.noteArrival(oldest: oldest) }
            if let temp = chunk.last(where: { $0.skinTempCenti > 0 })?.skinTempCenti {
                ui { self.skinTemp = Double(temp) / 100 }
            }
            chunk = []
            if let block { send(.historyResult, body: WhoopMeta.ackBody(block)) }
        case .complete:
            // Records after the last END have no token; they'll be sent again.
            chunk = []
            totalSeconds += passSeconds
            let more = passSeconds > 0 && passes < Self.maxPasses
            passSeconds = 0
            if more {
                queue.asyncAfter(deadline: .now() + 1) { [self] in if draining { startPass() } }
            } else {
                finishDrain(note: nil)
            }
        }
    }

    // MARK: History drain

    private func maybeDrain(reason: String, force: Bool) {
        guard ready, !draining, force || Date().timeIntervalSince(lastDrainEnded) >= Self.drainGap else { return }
        draining = true
        drainReason = reason
        passes = 0
        totalSeconds = 0
        ui { self.state = .downloading }
        dlog("whoop", "history drain: \(reason)")
        startPass()
    }

    private func startPass() {
        passes += 1
        chunk = []
        passSeconds = 0
        armWatchdog()
        send(.sendHistory, body: [0x00]) { [self] response in
            if response?.result == .failure { finishDrain(note: "the strap refused the download") }
        }
    }

    private func armWatchdog() {
        watchdog?.cancel()
        let item = DispatchWorkItem { [self] in
            guard draining else { return }
            send(.abortHistory, body: [0x00])
            finishDrain(note: "the strap went quiet")
        }
        watchdog = item
        queue.asyncAfter(deadline: .now() + 60, execute: item)
    }

    private func finishDrain(note: String?) {
        guard draining else { return }
        draining = false
        watchdog?.cancel()
        totalSeconds += passSeconds
        passSeconds = 0
        chunk = []
        lastDrainEnded = Date()
        let seconds = totalSeconds
        let reason = drainReason
        dlog("whoop", "history drain done: \(seconds) s of data in \(passes) pass(es)\(note.map { ", \($0)" } ?? "")")
        UserDefaults.standard.set(lastDrainEnded, forKey: "whoop.drain.at")
        UserDefaults.standard.set(seconds, forKey: "whoop.drain.n")
        let firmware = UserDefaults.standard.string(forKey: "whoop.firmware")
        let at = lastDrainEnded
        ui {
            self.lastDrainAt = at
            self.lastDrainSeconds = seconds
            self.state = self.ready ? .ready : .waiting
            // Keep the background run alive until Health has the data.
            var task = UIBackgroundTaskIdentifier.invalid
            task = UIApplication.shared.beginBackgroundTask(withName: "whoop-health") {
                UIApplication.shared.endBackgroundTask(task); task = .invalid
            }
            WhoopHealth.shared.export(firmware: firmware) { exported in
                let minutes = seconds / 60
                let parts = ["\(minutes) min of data", note, exported ? nil : "Health write pending (phone locked?)"]
                BackgroundLog.record(reason: "WHOOP: \(reason)", synced: note == nil || seconds > 0, exported: exported,
                                     note: parts.compactMap { $0 }.joined(separator: " · "))
                WhoopStore.shared.prune()
                if task != .invalid { UIApplication.shared.endBackgroundTask(task); task = .invalid }
            }
        }
    }

    private func ui(_ update: @escaping () -> Void) { DispatchQueue.main.async(execute: update) }
}
