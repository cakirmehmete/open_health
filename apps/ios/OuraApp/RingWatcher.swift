import CoreBluetooth
import UIKit

/// Holds a standing Bluetooth link to the paired ring so iOS wakes the app when
/// the ring connects, the way the official app syncs "on connect" rather than on
/// a timer (open_oura docs/sync-orchestration.md).
///
/// It never talks to the ring itself: it keeps a pending `connect` (which iOS
/// services in the background with no timeout, and which survives the app being
/// terminated by the system thanks to state restoration), and each connect is a
/// cue for `BackgroundSync`. Syncs reuse the link through BLETransport.
///
/// The ring decides how often that is: it drops idle links, and every reconnect
/// after a drop wakes us again. A reconnect soon after a sync is left idle.
final class RingWatcher: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    static let shared = RingWatcher()
    private static let restoreID = "md.thomas.openoura.watch"
    /// Must match RingSync's preferredPeripheralKey.
    private static let peripheralKey = "ring.peripheral-uuid"

    private let queue = DispatchQueue(label: "md.thomas.openoura.watch", qos: .utility)
    private var central: CBCentralManager?
    private var ring: CBPeripheral?

    /// Call at launch, before the app finishes launching, so a restoration
    /// relaunch finds a central with the same identifier.
    func start() {
        queue.async { [self] in
            guard central == nil else { return }
            central = CBCentralManager(delegate: self, queue: queue,
                                       options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreID,
                                                 CBCentralManagerOptionShowPowerAlertKey: false])
        }
    }

    /// After pairing or a manual sync picks a ring, watch that one.
    func refresh() { queue.async { [self] in watchKnownRing() } }

    private func watchKnownRing() {
        guard let central, central.state == .poweredOn,
              let id = UserDefaults.standard.string(forKey: Self.peripheralKey).flatMap(UUID.init(uuidString:)) else { return }
        if let ring, ring.identifier == id, ring.state == .connected || ring.state == .connecting { return }
        if let ring, ring.identifier != id { central.cancelPeripheralConnection(ring) }
        guard let peripheral = central.retrievePeripherals(withIdentifiers: [id]).first else {
            dlog("watch", "ring \(id.uuidString.suffix(12)) unknown to iOS; waiting for a sync to find it")
            return
        }
        ring = peripheral
        central.connect(peripheral, options: nil)
        dlog("watch", "pending connect to \(id.uuidString.suffix(12))")
    }

    // ── CBCentralManagerDelegate ──
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        ring = restored.first
        dlog("watch", "restored by iOS with \(restored.count) peripheral(s)")
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        watchKnownRing()
        if ring?.state == .connected { cue("restored link") }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        dlog("watch", "ring connected")
        cue("ring connected")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        dlog("watch", "ring disconnected: \(error.map { String(describing: $0) } ?? "clean"); re-arming")
        if peripheral === ring { central.connect(peripheral, options: nil) }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        dlog("watch", "connect failed: \(error.map { String(describing: $0) } ?? "no error"); re-arming")
        if peripheral === ring { central.connect(peripheral, options: nil) }
    }

    private func cue(_ reason: String) {
        Task { @MainActor in BackgroundSync.wake(reason: reason) }
    }
}
