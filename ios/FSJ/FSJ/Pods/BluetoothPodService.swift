import CoreBluetooth
import Foundation
import Observation

/// Talks to the real pods over Bluetooth LE, following
/// arduino/fsj/protocol.h.
///
/// On connect the app subscribes to each pod's data characteristic and keeps
/// that subscription. Start writes `PodCommand.start` to both pods' control
/// characteristic, which makes them power the IMU and stream; Stop writes
/// `PodCommand.stop`. Writes use responses, so Start only returns once both
/// pods have acknowledged it.
///
/// Around each capture the app also syncs clocks with both pods (see
/// ClockSync.swift): a burst of pings before Start and another after Stop,
/// so every sample gets a time on the phone's clock.
@Observable
final class BluetoothPodService: NSObject, PodService {
    private static let serviceUUID = CBUUID(string: FSJProtocol.serviceUUID)
    private static let dataUUID = CBUUID(string: FSJProtocol.dataUUID)
    private static let infoUUID = CBUUID(string: FSJProtocol.infoUUID)
    private static let controlUUID = CBUUID(string: FSJProtocol.controlUUID)
    private static let syncUUID = CBUUID(string: FSJProtocol.syncUUID)
    private static let batteryServiceUUID = CBUUID(string: "180F")
    private static let batteryLevelUUID = CBUUID(string: "2A19")

    private static let connectTimeout: Duration = .seconds(15)
    private static let commandTimeout: Duration = .seconds(2)
    /// How long to keep taking packets after the pods acknowledge Stop.
    private static let drainTime: Duration = .milliseconds(150)
    /// Pings per pod in each sync burst; the shortest round trip wins.
    private static let pingsPerSync = 10
    private static let pingTimeout: Duration = .milliseconds(300)

    private var statuses: [PodSide: PodStatus] = [:]

    @ObservationIgnored private var central: CBCentralManager?
    /// Sides the user asked to connect and has not disconnected.
    @ObservationIgnored private var wanted: Set<PodSide> = []
    @ObservationIgnored private var peripherals: [PodSide: CBPeripheral] = [:]
    @ObservationIgnored private var dataCharacteristics: [PodSide: CBCharacteristic] = [:]
    @ObservationIgnored private var controlCharacteristics: [PodSide: CBCharacteristic] = [:]
    @ObservationIgnored private var syncCharacteristics: [PodSide: CBCharacteristic] = [:]
    /// Sides whose data characteristic is confirmed subscribed.
    @ObservationIgnored private var subscribed: Set<PodSide> = []
    @ObservationIgnored private var pendingWrites: [PodSide: PendingWrite] = [:]
    @ObservationIgnored private var nextWriteID = 0
    @ObservationIgnored private var timeouts: [PodSide: Task<Void, Never>] = [:]
    @ObservationIgnored private var collecting = false
    @ObservationIgnored private var buffers: [PodSide: [ImuSample]] = [:]
    @ObservationIgnored private var lastSeq: [PodSide: UInt16] = [:]
    @ObservationIgnored private var sampleTimes: [PodSide: [Int64]] = [:]
    @ObservationIgnored private var unwrappers: [PodSide: MicrosUnwrapper] = [:]
    @ObservationIgnored private var syncBefore: [PodSide: ClockSample] = [:]
    @ObservationIgnored private var pendingPings: [PodSide: PendingPing] = [:]
    @ObservationIgnored private var nextPingID: UInt8 = 0
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
        guard bothConnected else { throw PodServiceError.notConnected }
        buffers = [:]
        sampleTimes = [:]
        lastSeq = [:]
        unwrappers = [:]
        droppedPackets = 0
        syncBefore = await syncClocks()
        collecting = true
        do {
            for side in PodSide.allCases {
                try await send(.start, to: side)
            }
        } catch {
            collecting = false
            for side in PodSide.allCases {
                try? await send(.stop, to: side)
            }
            throw error
        }
    }

    func stopStreaming() async throws -> PodCapture {
        for side in PodSide.allCases {
            do {
                try await send(.stop, to: side)
            } catch {
                // The pod also stops by itself when the link drops.
                print("BluetoothPodService: Stop not acknowledged by \(side.advertisedName): \(error)")
            }
        }
        try? await Task.sleep(for: Self.drainTime)
        collecting = false
        let syncAfter = await syncClocks()
        var clocks: [PodSide: PodClock] = [:]
        for side in PodSide.allCases {
            clocks[side] = PodClock.fit(before: syncBefore[side], after: syncAfter[side])
        }
        let capture = PodCapture(
            sampleRateHz: FSJProtocol.sampleRateHz,
            samples: buffers,
            times: sampleTimes,
            clocks: clocks
        )
        buffers = [:]
        sampleTimes = [:]
        if droppedPackets > 0 {
            print("BluetoothPodService: \(droppedPackets) packets dropped during capture")
        }
        return capture
    }

    // MARK: Commands

    private struct PendingWrite {
        var id: Int
        var continuation: CheckedContinuation<Void, Error>
    }

    /// Write a command to one pod and wait for its acknowledgement.
    private func send(_ command: PodCommand, to side: PodSide) async throws {
        guard let peripheral = peripherals[side], let control = controlCharacteristics[side] else {
            throw PodServiceError.notConnected
        }
        nextWriteID += 1
        let id = nextWriteID
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            finishWrite(on: side, error: PodServiceError.podDidNotRespond(side))
            pendingWrites[side] = PendingWrite(id: id, continuation: continuation)
            peripheral.writeValue(Data([command.rawValue]), for: control, type: .withResponse)
            Task { [weak self] in
                try? await Task.sleep(for: Self.commandTimeout)
                guard let self, self.pendingWrites[side]?.id == id else { return }
                self.finishWrite(on: side, error: PodServiceError.podDidNotRespond(side))
            }
        }
    }

    private func finishWrite(on side: PodSide, error: Error?) {
        guard let pending = pendingWrites.removeValue(forKey: side) else { return }
        if let error {
            pending.continuation.resume(throwing: error)
        } else {
            pending.continuation.resume()
        }
    }

    // MARK: Clock sync

    private struct PendingPing {
        var id: UInt8
        var sentAt: Double
        var continuation: CheckedContinuation<ClockSample?, Never>
    }

    /// A burst of pings to both pods at once. Returns the best ping per pod;
    /// a pod without the sync characteristic (older firmware) is left out.
    private func syncClocks() async -> [PodSide: ClockSample] {
        async let left = bestPing(.left)
        async let right = bestPing(.right)
        var out: [PodSide: ClockSample] = [:]
        out[.left] = await left
        out[.right] = await right
        return out
    }

    private func bestPing(_ side: PodSide) async -> ClockSample? {
        var samples: [ClockSample] = []
        for _ in 0..<Self.pingsPerSync {
            guard syncCharacteristics[side] != nil else { break }
            if let sample = await ping(side) { samples.append(sample) }
        }
        return ClockSample.best(samples)
    }

    /// One ping. Nil if the pod didn't answer in time.
    private func ping(_ side: PodSide) async -> ClockSample? {
        guard let peripheral = peripherals[side], let sync = syncCharacteristics[side] else { return nil }
        nextPingID &+= 1
        let id = nextPingID
        return await withCheckedContinuation { (continuation: CheckedContinuation<ClockSample?, Never>) in
            finishPing(on: side, with: nil)
            let sentAt = HostClock.now()
            pendingPings[side] = PendingPing(id: id, sentAt: sentAt, continuation: continuation)
            peripheral.writeValue(Data([id]), for: sync, type: .withoutResponse)
            Task { [weak self] in
                try? await Task.sleep(for: Self.pingTimeout)
                guard let self, self.pendingPings[side]?.id == id else { return }
                self.finishPing(on: side, with: nil)
            }
        }
    }

    private func finishPing(on side: PodSide, with sample: ClockSample?) {
        pendingPings.removeValue(forKey: side)?.continuation.resume(returning: sample)
    }

    private func answered(_ reply: SyncReply, from side: PodSide, at host: Double) {
        guard let pending = pendingPings[side], pending.id == reply.id else { return }
        let podMicros = unwrappers[side, default: MicrosUnwrapper()].unwrap(reply.tMicros)
        finishPing(on: side, with: ClockSample(
            podMicros: podMicros,
            hostSeconds: (pending.sentAt + host) / 2,
            roundTrip: host - pending.sentAt
        ))
    }

    // MARK: Internals

    private func setConnection(_ connection: PodConnection, for side: PodSide) {
        statuses[side, default: PodStatus()].connection = connection
    }

    private func side(of peripheral: CBPeripheral) -> PodSide? {
        peripherals.first { $0.value === peripheral }?.key
    }

    private func forget(_ side: PodSide) {
        finishWrite(on: side, error: PodServiceError.notConnected)
        finishPing(on: side, with: nil)
        peripherals[side] = nil
        dataCharacteristics[side] = nil
        controlCharacteristics[side] = nil
        syncCharacteristics[side] = nil
        subscribed.remove(side)
        statuses[side] = PodStatus()
    }

    /// Connected once the data subscription is confirmed and the control
    /// characteristic is known.
    private func markConnectedIfReady(_ side: PodSide) {
        guard subscribed.contains(side), controlCharacteristics[side] != nil,
              status(of: side).connection == .connecting else { return }
        timeouts[side]?.cancel()
        setConnection(.connected, for: side)
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
                peripheral.setNotifyValue(true, for: c)
            case Self.controlUUID:
                controlCharacteristics[side] = c
                markConnectedIfReady(side)
            case Self.syncUUID:
                syncCharacteristics[side] = c
                peripheral.setNotifyValue(true, for: c)
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

    private func notificationStateChanged(for uuid: CBUUID, on peripheral: CBPeripheral, isNotifying: Bool, error: Error?) {
        guard uuid == Self.dataUUID, let side = side(of: peripheral) else { return }
        if let error {
            print("BluetoothPodService: could not subscribe to \(side.advertisedName): \(error)")
            return
        }
        if isNotifying {
            subscribed.insert(side)
            markConnectedIfReady(side)
        } else {
            subscribed.remove(side)
        }
    }

    private func wrote(_ uuid: CBUUID, on peripheral: CBPeripheral, error: Error?) {
        guard uuid == Self.controlUUID, let side = side(of: peripheral) else { return }
        finishWrite(on: side, error: error.map { _ in PodServiceError.podDidNotRespond(side) })
    }

    private func received(_ value: Data, from uuid: CBUUID, on peripheral: CBPeripheral, at host: Double) {
        guard let side = side(of: peripheral) else { return }
        switch uuid {
        case Self.dataUUID:
            guard collecting, let packet = DataPacket(value) else { return }
            if let last = lastSeq[side] {
                droppedPackets += Int(packet.seq &- last &- 1)
            }
            lastSeq[side] = packet.seq
            buffers[side, default: []].append(contentsOf: packet.samples)
            let t0 = unwrappers[side, default: MicrosUnwrapper()].unwrap(packet.t0Micros)
            let step = Int64((1_000_000 / FSJProtocol.sampleRateHz).rounded())
            sampleTimes[side, default: []].append(contentsOf: packet.samples.indices.map { t0 + Int64($0) * step })
        case Self.syncUUID:
            if let reply = SyncReply(value) { answered(reply, from: side, at: host) }
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
                    peripheral.discoverCharacteristics(
                        [Self.dataUUID, Self.infoUUID, Self.controlUUID, Self.syncUUID],
                        for: service
                    )
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
        // Read the clock first: for sync replies, every step before this adds error.
        let host = HostClock.now()
        guard error == nil, let value = characteristic.value else { return }
        let uuid = characteristic.uuid
        MainActor.assumeIsolated { self.received(value, from: uuid, on: peripheral, at: host) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = characteristic.uuid
        let isNotifying = characteristic.isNotifying
        MainActor.assumeIsolated {
            self.notificationStateChanged(for: uuid, on: peripheral, isNotifying: isNotifying, error: error)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = characteristic.uuid
        MainActor.assumeIsolated { self.wrote(uuid, on: peripheral, error: error) }
    }
}
