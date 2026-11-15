import CoreBluetooth
import Foundation
import Observation

/// Talks to the real pods over Bluetooth LE, following
/// arduino/fsj/protocol.h.
///
/// The current firmware streams while a central is subscribed to the data
/// characteristic, so Start subscribes on both pods and Stop unsubscribes.
/// When the firmware gets explicit start/stop commands, only
/// `startStreaming` / `stopStreaming` here need to change.
@Observable
final class BluetoothPodService: NSObject, PodService {
    private static let serviceUUID = CBUUID(string: FSJProtocol.serviceUUID)
    private static let dataUUID = CBUUID(string: FSJProtocol.dataUUID)
    private static let infoUUID = CBUUID(string: FSJProtocol.infoUUID)
    private static let batteryServiceUUID = CBUUID(string: "180F")
    private static let batteryLevelUUID = CBUUID(string: "2A19")

    private static let connectTimeout: Duration = .seconds(15)
    /// How long to keep taking packets after unsubscribing.
    private static let drainTime: Duration = .milliseconds(200)

    private var statuses: [PodSide: PodStatus] = [:]

    @ObservationIgnored private var central: CBCentralManager?
    /// Sides the user asked to connect and has not disconnected.
    @ObservationIgnored private var wanted: Set<PodSide> = []
    @ObservationIgnored private var peripherals: [PodSide: CBPeripheral] = [:]
    @ObservationIgnored private var dataCharacteristics: [PodSide: CBCharacteristic] = [:]
    @ObservationIgnored private var timeouts: [PodSide: Task<Void, Never>] = [:]
    @ObservationIgnored private var collecting = false
    @ObservationIgnored private var buffers: [PodSide: [ImuSample]] = [:]
    @ObservationIgnored private var lastSeq: [PodSide: UInt16] = [:]
    @ObservationIgnored private(set) var droppedPackets = 0

    // MARK: PodService

    func status(of side: PodSide) -> PodStatus {
        statuses[side] ?? PodStatus()
    }

    func connect(_ side: PodSide) {
        guard status(of: side).connection == .disconnected else { return }
        wanted.insert(side)
        setConnection(.connecting, for: side)

        timeouts[side]?.cancel()
        timeouts[side] = Task { [weak self] in
            try? await Task.sleep(for: Self.connectTimeout)
            guard !Task.isCancelled else { return }
            self?.giveUp(on: side)
        }

        if let central {
            scanIfNeeded(central)
        } else {
            // Creating the manager shows the Bluetooth permission prompt the
            // first time; scanning starts from centralManagerDidUpdateState.
            central = CBCentralManager(delegate: self, queue: nil)
        }
    }

    func disconnect(_ side: PodSide) {
        wanted.remove(side)
        timeouts[side]?.cancel()
        if let peripheral = peripherals[side] {
            central?.cancelPeripheralConnection(peripheral)
        }
        forget(side)
        if let central { scanIfNeeded(central) }
    }

    func startStreaming() async throws {
        guard central?.state == .poweredOn else { throw PodServiceError.bluetoothUnavailable }
        guard bothConnected, PodSide.allCases.allSatisfy({ dataCharacteristics[$0] != nil }) else {
            throw PodServiceError.notConnected
        }
        buffers = [:]
        lastSeq = [:]
        droppedPackets = 0
        collecting = true
        for side in PodSide.allCases {
            if let p = peripherals[side], let c = dataCharacteristics[side] {
                p.setNotifyValue(true, for: c)
            }
        }
    }

    func stopStreaming() async throws -> PodCapture {
        for side in PodSide.allCases {
            if let p = peripherals[side], let c = dataCharacteristics[side] {
                p.setNotifyValue(false, for: c)
            }
        }
        try? await Task.sleep(for: Self.drainTime)
        collecting = false
        let capture = PodCapture(sampleRateHz: FSJProtocol.sampleRateHz, samples: buffers)
        buffers = [:]
        return capture
    }

    // MARK: Internals

    private func setConnection(_ connection: PodConnection, for side: PodSide) {
        statuses[side, default: PodStatus()].connection = connection
    }

    private func side(of peripheral: CBPeripheral) -> PodSide? {
        peripherals.first { $0.value === peripheral }?.key
    }

    private func forget(_ side: PodSide) {
        peripherals[side] = nil
        dataCharacteristics[side] = nil
        statuses[side] = PodStatus()
    }

    private func giveUp(on side: PodSide) {
        guard status(of: side).connection == .connecting else { return }
        disconnect(side)
    }

    /// Scan while some wanted side has no peripheral yet.
    private func scanIfNeeded(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        let searching = wanted.contains { peripherals[$0] == nil }
        if searching, !central.isScanning {
            central.scanForPeripherals(withServices: [Self.serviceUUID])
        } else if !searching, central.isScanning {
            central.stopScan()
        }
    }

    private func centralStateChanged(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            scanIfNeeded(central)
        case .poweredOff, .unauthorized, .unsupported:
            for side in PodSide.allCases {
                timeouts[side]?.cancel()
                forget(side)
            }
            wanted.removeAll()
        default:
            break
        }
    }

    private func discovered(_ peripheral: CBPeripheral, name: String?, central: CBCentralManager) {
        guard let name, let side = PodSide(advertisedName: name),
              wanted.contains(side), peripherals[side] == nil else { return }
        peripherals[side] = peripheral
        peripheral.delegate = self
        central.connect(peripheral)
        scanIfNeeded(central)
    }

    private func lost(_ peripheral: CBPeripheral) {
        guard let side = side(of: peripheral) else { return }
        timeouts[side]?.cancel()
        wanted.remove(side)
        forget(side)
    }

    private func discoveredCharacteristics(of service: CBService, on peripheral: CBPeripheral) {
        guard let side = side(of: peripheral) else { return }
        for c in service.characteristics ?? [] {
            switch c.uuid {
            case Self.dataUUID:
                dataCharacteristics[side] = c
                timeouts[side]?.cancel()
                setConnection(.connected, for: side)
            case Self.infoUUID:
                peripheral.readValue(for: c)
            case Self.batteryLevelUUID:
                peripheral.readValue(for: c)
                peripheral.setNotifyValue(true, for: c)
            default:
                break
            }
        }
    }

    private func received(_ value: Data, from uuid: CBUUID, on peripheral: CBPeripheral) {
        guard let side = side(of: peripheral) else { return }
        switch uuid {
        case Self.dataUUID:
            guard collecting, let packet = DataPacket(value) else { return }
            if let last = lastSeq[side] {
                droppedPackets += Int(packet.seq &- last &- 1)
            }
            lastSeq[side] = packet.seq
            buffers[side, default: []].append(contentsOf: packet.samples)
        case Self.batteryLevelUUID:
            if let level = value.first {
                statuses[side, default: PodStatus()].batteryPercent = Int(level)
            }
        case Self.infoUUID:
            if let info = InfoPacket(value), info.version != FSJProtocol.version {
                print("BluetoothPodService: \(side.advertisedName) speaks protocol v\(info.version), app expects v\(FSJProtocol.version)")
            }
        default:
            break
        }
    }
}

// CoreBluetooth calls these on the main queue (the manager was created with
// queue: nil), so it is safe to hop straight onto the main actor.

extension BluetoothPodService: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated { self.centralStateChanged(central) }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        MainActor.assumeIsolated { self.discovered(peripheral, name: name, central: central) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            peripheral.discoverServices([Self.serviceUUID, Self.batteryServiceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { self.lost(peripheral) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { self.lost(peripheral) }
    }
}

extension BluetoothPodService: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            for service in peripheral.services ?? [] {
                switch service.uuid {
                case Self.serviceUUID:
                    peripheral.discoverCharacteristics([Self.dataUUID, Self.infoUUID], for: service)
                case Self.batteryServiceUUID:
                    peripheral.discoverCharacteristics([Self.batteryLevelUUID], for: service)
                default:
                    break
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated { self.discoveredCharacteristics(of: service, on: peripheral) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value else { return }
        let uuid = characteristic.uuid
        MainActor.assumeIsolated { self.received(value, from: uuid, on: peripheral) }
    }
}
