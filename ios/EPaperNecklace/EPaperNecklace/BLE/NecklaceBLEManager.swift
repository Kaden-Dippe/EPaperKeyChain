import CoreBluetooth
import Foundation

/// Drives the BLE side of the necklace: scan, connect, subscribe, and run the
/// START / chunks / END transfer state machine.
///
/// Concurrency note: the central manager is created with `queue: nil`, so every
/// CoreBluetooth delegate callback lands on the main queue, and the public
/// async API is `@MainActor`. That means all of the mutable state below is
/// touched from exactly one place and needs no extra locking. The transfer is
/// tiny (a few dozen packets), so nothing here benefits from a private queue.
final class NecklaceBLEManager: NSObject, ObservableObject {

    enum ConnectionState: Equatable {
        case unknown
        case unsupported
        case unauthorized
        case poweredOff
        case disconnected
        case scanning
        case connecting
        case ready

        var isReady: Bool { self == .ready }

        var isBusy: Bool { self == .scanning || self == .connecting }
    }

    struct TransferProgress: Equatable {
        var bytesSent: Int
        var totalBytes: Int
        var packetsSent: Int
        var totalPackets: Int

        var fraction: Double {
            guard totalBytes > 0 else { return 0 }
            return min(1, Double(bytesSent) / Double(totalBytes))
        }
    }

    // MARK: - Published state

    @Published private(set) var state: ConnectionState = .unknown
    @Published private(set) var connectedName: String?
    @Published private(set) var progress: TransferProgress?

    // MARK: - CoreBluetooth

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var controlCharacteristic: CBCharacteristic?
    private var imageCharacteristic: CBCharacteristic?

    // MARK: - Pending work

    private var powerWaiter: CheckedContinuation<Void, Error>?
    private var powerTimeout: DispatchWorkItem?

    private var scanWaiter: CheckedContinuation<CBPeripheral, Error>?
    private var scanTimeout: DispatchWorkItem?

    private var connectWaiter: CheckedContinuation<Void, Error>?
    private var connectTimeout: DispatchWorkItem?

    private var statusWaiter: CheckedContinuation<NecklaceProtocol.Status, Error>?
    private var statusTimeout: DispatchWorkItem?

    private var chunkWaiter: CheckedContinuation<Void, Error>?
    private var chunkTimeout: DispatchWorkItem?

    private var isTransferring = false

    /// The connect attempt in flight, if any, so overlapping callers can join
    /// it instead of racing to install waiters.
    private var connectTask: Task<Void, Error>?

    override init() {
        super.init()
        // `showPowerAlert: false` keeps us from throwing a system alert at
        // launch; the status header explains the state instead.
        central = CBCentralManager(delegate: self,
                                   queue: nil,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    // MARK: - Connecting

    /// Scans for the necklace and opens a session.
    ///
    /// Concurrent callers join the attempt already in flight rather than
    /// starting a second one. Without that, two overlapping calls would each
    /// install their own waiter into the same single-slot properties below and
    /// the first continuation would never be resumed, hanging its caller
    /// forever - a real hazard while the state is still `.unknown`, when the
    /// header tap and the upload button can both get through.
    @MainActor
    func connect() async throws {
        guard !state.isReady else { return }

        if let inFlight = connectTask {
            try await inFlight.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.connectTask = nil }
            try await self.waitUntilPoweredOn()
            let discovered = try await self.scanForNecklace()
            try await self.establishSession(with: discovered)
        }
        connectTask = task
        try await task.value
    }

    @MainActor
    func disconnect() {
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        teardown(reason: .notConnected)
        state = mappedState(for: central.state)
    }

    @MainActor
    private func waitUntilPoweredOn() async throws {
        switch central.state {
        case .poweredOn:
            return
        case .unsupported:
            throw NecklaceError.bluetoothUnsupported
        case .unauthorized:
            throw NecklaceError.bluetoothUnauthorized
        case .poweredOff:
            throw NecklaceError.bluetoothOff
        case .resetting, .unknown:
            // The manager hasn't reported in yet; give it a moment.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Belt and braces: never strand a waiter that is already here.
                finishPower(with: .failure(NecklaceError.superseded))
                powerWaiter = continuation
                let timeout = DispatchWorkItem { [weak self] in
                    self?.finishPower(with: .failure(NecklaceError.timedOut("waking up Bluetooth")))
                }
                powerTimeout = timeout
                DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
            }
        @unknown default:
            throw NecklaceError.bluetoothOff
        }
    }

    @MainActor
    private func scanForNecklace() async throws -> CBPeripheral {
        // Clearing a stale waiter first: finishScan can reset `state`, so it
        // has to happen before this attempt marks itself as scanning.
        finishScan(with: .failure(NecklaceError.superseded))
        state = .scanning
        return try await withCheckedThrowingContinuation { continuation in
            scanWaiter = continuation
            let timeout = DispatchWorkItem { [weak self] in
                self?.finishScan(with: .failure(NecklaceError.deviceNotFound))
            }
            scanTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + NecklaceProtocol.scanTimeout, execute: timeout)
            central.scanForPeripherals(withServices: [NecklaceProtocol.serviceUUID], options: nil)
        }
    }

    /// Connects, discovers the service and both characteristics, and - the step
    /// that is easy to forget - subscribes to notifications on the control
    /// characteristic. The continuation only resolves once notifications are
    /// actually enabled, so nothing can write START into a deaf connection.
    @MainActor
    private func establishSession(with discovered: CBPeripheral) async throws {
        // Same ordering point as the scan: finishConnect clears `peripheral`
        // on failure, so a stale waiter has to go before this one is stored.
        finishConnect(with: .failure(NecklaceError.superseded))

        state = .connecting
        peripheral = discovered
        discovered.delegate = self

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connectWaiter = continuation
            let timeout = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if let peripheral = self.peripheral {
                    self.central.cancelPeripheralConnection(peripheral)
                }
                self.finishConnect(with: .failure(NecklaceError.timedOut("connecting")))
            }
            connectTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + NecklaceProtocol.connectTimeout, execute: timeout)
            central.connect(discovered, options: nil)
        }

        state = .ready
        connectedName = discovered.name ?? NecklaceProtocol.deviceName
    }

    // MARK: - Transfer

    /// Runs the full protocol: START, chunked image writes, END.
    ///
    /// Every chunk is written with response so CoreBluetooth waits for the
    /// link-layer acknowledgement before sending the next one; that back
    /// pressure is what paces the ESP32's flash writes.
    @MainActor
    func send(payload: Data) async throws {
        guard payload.count == PanelSpec.payloadByteCount else {
            throw NecklaceError.payloadSizeMismatch(payload.count)
        }
        guard state.isReady,
              let peripheral,
              let control = controlCharacteristic,
              let image = imageCharacteristic else {
            throw NecklaceError.notConnected
        }

        let chunkSize = negotiatedChunkSize(for: peripheral)
        let totalPackets = (payload.count + chunkSize - 1) / chunkSize

        // The negotiated MTU is the one number neither the code nor the docs
        // can predict, and it decides whether this is 11 packets or 276.
        Telemetry.shared.log("""
            transfer: \(payload.count) bytes, chunk \(chunkSize) \
            (withoutResponse \(peripheral.maximumWriteValueLength(for: .withoutResponse)), \
            withResponse \(peripheral.maximumWriteValueLength(for: .withResponse))), \
            \(totalPackets) packets
            """)

        isTransferring = true
        progress = TransferProgress(bytesSent: 0,
                                    totalBytes: payload.count,
                                    packetsSent: 0,
                                    totalPackets: totalPackets)
        defer {
            isTransferring = false
            progress = nil
        }

        // 1. START, and wait for the firmware to open its file pointer.
        let startStatus = try await sendCommand(.start,
                                                to: control,
                                                on: peripheral,
                                                step: "starting the transfer")
        Telemetry.shared.log("START -> \(startStatus)")
        try check(status: startStatus)

        // 2. Stream the payload.
        var offset = 0
        var packets = 0
        while offset < payload.count {
            try Task.checkCancellation()
            let end = min(offset + chunkSize, payload.count)
            let chunk = payload.subdata(in: offset..<end)
            try await writeChunk(chunk, to: image, on: peripheral)
            offset = end
            packets += 1
            progress = TransferProgress(bytesSent: offset,
                                        totalBytes: payload.count,
                                        packetsSent: packets,
                                        totalPackets: totalPackets)

            // Sampled: every packet would be up to 276 lines, and the worst
            // case is exactly when something has gone wrong.
            if packets == 1 || packets == totalPackets || packets % 10 == 0 {
                Telemetry.shared.log("chunk \(packets)/\(totalPackets), \(offset) bytes sent")
            }
        }

        // 3. END, and wait for the firmware to close the file and start
        //    refreshing the panel.
        let endStatus = try await sendCommand(.end,
                                              to: control,
                                              on: peripheral,
                                              step: "finishing the transfer")
        Telemetry.shared.log("END -> \(endStatus)")
        try check(status: endStatus)
    }

    /// ATT_MTU minus the 3 byte write header.
    ///
    /// CoreBluetooth doesn't expose the negotiated MTU directly, but
    /// `maximumWriteValueLength(for: .withoutResponse)` is defined as
    /// ATT_MTU - 3. The `.withResponse` limit is capped separately (iOS will
    /// happily split a larger value into a queued long write, which the
    /// firmware doesn't expect), so take the smaller of the two.
    private func negotiatedChunkSize(for peripheral: CBPeripheral) -> Int {
        let mtuPayload = peripheral.maximumWriteValueLength(for: .withoutResponse)
        let responseLimit = peripheral.maximumWriteValueLength(for: .withResponse)
        return max(20, min(mtuPayload, responseLimit))
    }

    private func check(status: NecklaceProtocol.Status) throws {
        switch status {
        case .ok: return
        case .busy: throw NecklaceError.deviceBusy
        case .error: throw NecklaceError.deviceRejected
        }
    }

    @MainActor
    private func sendCommand(_ command: NecklaceProtocol.Command,
                             to control: CBCharacteristic,
                             on peripheral: CBPeripheral,
                             step: String) async throws -> NecklaceProtocol.Status {
        try await withCheckedThrowingContinuation { continuation in
            // The waiter is installed before the write so a fast notification
            // can't arrive before anyone is listening for it.
            finishStatus(with: .failure(NecklaceError.superseded))
            statusWaiter = continuation
            let timeout = DispatchWorkItem { [weak self] in
                self?.finishStatus(with: .failure(NecklaceError.timedOut(step)))
            }
            statusTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + NecklaceProtocol.controlTimeout, execute: timeout)
            peripheral.writeValue(Data([command.rawValue]), for: control, type: .withResponse)
        }
    }

    @MainActor
    private func writeChunk(_ chunk: Data,
                            to image: CBCharacteristic,
                            on peripheral: CBPeripheral) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            finishChunk(with: .failure(NecklaceError.superseded))
            chunkWaiter = continuation
            let timeout = DispatchWorkItem { [weak self] in
                self?.finishChunk(with: .failure(NecklaceError.timedOut("sending image data")))
            }
            chunkTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + NecklaceProtocol.chunkTimeout, execute: timeout)
            peripheral.writeValue(chunk, for: image, type: .withResponse)
        }
    }

    // MARK: - Continuation plumbing
    //
    // Each waiter resolves exactly once: whoever gets there first (delegate
    // callback, timeout, or disconnect) clears the slot and cancels the timer.

    private func finishPower(with result: Result<Void, Error>) {
        powerTimeout?.cancel()
        powerTimeout = nil
        guard let waiter = powerWaiter else { return }
        powerWaiter = nil
        waiter.resume(with: result)
    }

    private func finishScan(with result: Result<CBPeripheral, Error>) {
        central.stopScan()
        scanTimeout?.cancel()
        scanTimeout = nil
        guard let waiter = scanWaiter else { return }
        scanWaiter = nil
        if case .failure = result, state == .scanning {
            state = central.state == .poweredOn ? .disconnected : mappedState(for: central.state)
        }
        waiter.resume(with: result)
    }

    private func finishConnect(with result: Result<Void, Error>) {
        connectTimeout?.cancel()
        connectTimeout = nil
        guard let waiter = connectWaiter else { return }
        connectWaiter = nil
        if case .failure = result {
            peripheral = nil
            controlCharacteristic = nil
            imageCharacteristic = nil
            if state == .connecting { state = .disconnected }
        }
        waiter.resume(with: result)
    }

    private func finishStatus(with result: Result<NecklaceProtocol.Status, Error>) {
        statusTimeout?.cancel()
        statusTimeout = nil
        guard let waiter = statusWaiter else { return }
        statusWaiter = nil
        waiter.resume(with: result)
    }

    private func finishChunk(with result: Result<Void, Error>) {
        chunkTimeout?.cancel()
        chunkTimeout = nil
        guard let waiter = chunkWaiter else { return }
        chunkWaiter = nil
        waiter.resume(with: result)
    }

    /// Fails everything in flight and drops the session. Called on disconnect,
    /// on Bluetooth going away, and on an explicit disconnect request.
    private func teardown(reason: NecklaceError) {
        peripheral = nil
        controlCharacteristic = nil
        imageCharacteristic = nil
        connectedName = nil
        progress = nil
        isTransferring = false

        finishScan(with: .failure(reason))
        finishConnect(with: .failure(reason))
        finishStatus(with: .failure(reason))
        finishChunk(with: .failure(reason))
        finishPower(with: .failure(reason))
    }

    private func mappedState(for state: CBManagerState) -> ConnectionState {
        switch state {
        case .poweredOn: return .disconnected
        case .poweredOff: return .poweredOff
        case .unauthorized: return .unauthorized
        case .unsupported: return .unsupported
        case .resetting, .unknown: return .unknown
        @unknown default: return .unknown
        }
    }

}

// MARK: - CBCentralManagerDelegate

extension NecklaceBLEManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            finishPower(with: .success(()))
            if state == .unknown || state == .poweredOff {
                state = .disconnected
            }
        } else {
            state = mappedState(for: central.state)
            switch central.state {
            case .unauthorized: teardown(reason: .bluetoothUnauthorized)
            case .unsupported: teardown(reason: .bluetoothUnsupported)
            default: teardown(reason: .bluetoothOff)
            }
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        // The scan is already filtered by service UUID; the name check is a
        // second guard so we never latch onto someone else's board.
        let advertised = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        if let advertised,
           advertised.compare(NecklaceProtocol.deviceName, options: .caseInsensitive) != .orderedSame {
            Telemetry.shared.log("ignored '\(advertised)' (name mismatch)")
            return
        }
        Telemetry.shared.log("found '\(advertised ?? "unnamed")' rssi \(RSSI)")
        finishScan(with: .success(peripheral))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([NecklaceProtocol.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        let reason = error?.localizedDescription ?? "the necklace refused the connection"
        finishConnect(with: .failure(NecklaceError.connectionFailed(reason)))
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        Telemetry.shared.log("""
            disconnected\(isTransferring ? " mid-transfer" : ""): \
            \(error?.localizedDescription ?? "no error reported")
            """)
        let reason: NecklaceError = isTransferring ? .disconnectedDuringTransfer : .notConnected
        teardown(reason: reason)
        state = central.state == .poweredOn ? .disconnected : mappedState(for: central.state)
    }
}

// MARK: - CBPeripheralDelegate

extension NecklaceBLEManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            finishConnect(with: .failure(NecklaceError.connectionFailed(error.localizedDescription)))
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == NecklaceProtocol.serviceUUID }) else {
            finishConnect(with: .failure(NecklaceError.missingCharacteristics))
            return
        }
        peripheral.discoverCharacteristics([NecklaceProtocol.controlCharacteristicUUID,
                                            NecklaceProtocol.imageCharacteristicUUID],
                                           for: service)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error {
            finishConnect(with: .failure(NecklaceError.connectionFailed(error.localizedDescription)))
            return
        }
        let characteristics = service.characteristics ?? []
        controlCharacteristic = characteristics.first { $0.uuid == NecklaceProtocol.controlCharacteristicUUID }
        imageCharacteristic = characteristics.first { $0.uuid == NecklaceProtocol.imageCharacteristicUUID }

        guard let control = controlCharacteristic, imageCharacteristic != nil else {
            finishConnect(with: .failure(NecklaceError.missingCharacteristics))
            return
        }
        // Status bytes arrive as notifications, so this subscription is what
        // makes the whole handshake work.
        peripheral.setNotifyValue(true, for: control)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == NecklaceProtocol.controlCharacteristicUUID else { return }
        if let error {
            finishConnect(with: .failure(NecklaceError.connectionFailed(error.localizedDescription)))
            return
        }
        if characteristic.isNotifying {
            Telemetry.shared.log("notifications enabled, session ready")
            finishConnect(with: .success(()))
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == NecklaceProtocol.controlCharacteristicUUID else { return }
        if let error {
            finishStatus(with: .failure(NecklaceError.writeFailed(error.localizedDescription)))
            return
        }
        guard let byte = characteristic.value?.first else {
            Telemetry.shared.log("notify: empty value")
            finishStatus(with: .failure(NecklaceError.unreadableStatus))
            return
        }
        guard let status = NecklaceProtocol.Status(byte: byte) else {
            // The exact byte matters here: an unrecognised one almost certainly
            // means the board is running firmware older than 7452adb.
            Telemetry.shared.log("notify: unrecognised status \(Telemetry.hex(byte))")
            finishStatus(with: .failure(NecklaceError.unreadableStatus))
            return
        }
        Telemetry.shared.log("notify: \(Telemetry.hex(byte)) -> \(status)")
        finishStatus(with: .success(status))
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        switch characteristic.uuid {
        case NecklaceProtocol.imageCharacteristicUUID:
            // This is the ATT-level acknowledgement that paces the transfer.
            if let error {
                finishChunk(with: .failure(NecklaceError.writeFailed(error.localizedDescription)))
            } else {
                finishChunk(with: .success(()))
            }
        case NecklaceProtocol.controlCharacteristicUUID:
            // A successful control write just means the command left the
            // phone; we keep waiting for the notification. A failed one means
            // no notification is ever coming.
            if let error {
                finishStatus(with: .failure(NecklaceError.writeFailed(error.localizedDescription)))
            }
        default:
            break
        }
    }
}
