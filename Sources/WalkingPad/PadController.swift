import AppKit
import CoreBluetooth
import Foundation
import WalkingPadCore

struct NearbyPad: Identifiable {
    let id: UUID
    let name: String
    let signal: Int
    let likelyPad: Bool
}

@MainActor
// CoreBluetooth delegates are delivered on the .main queue selected below.
final class PadController: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    @Published private(set) var devices: [NearbyPad] = []
    @Published private(set) var scanning = false
    @Published private(set) var connected = false
    @Published private(set) var connecting = false
    @Published private(set) var deviceName = "SpaceWalk E1L"
    @Published private(set) var status = "Ready to find your walking pad"
    @Published private(set) var notice = "Power on your pad and keep it nearby. Close other treadmill apps before connecting."
    @Published private(set) var speed: Double?
    @Published private(set) var distance: Int?
    @Published private(set) var elapsed: Int?
    @Published private(set) var calories: Int?
    @Published private(set) var lastSample: Date?
    @Published private(set) var range: SpeedRange?
    @Published private(set) var controlsAvailable = false
    @Published private(set) var session = ControlSession()
    @Published private(set) var diagnostics: [String] = []
    @Published private(set) var speedTarget = SpeedTarget()
    @Published private(set) var expectedBeltState: BeltState?

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var pad: CBPeripheral?
    private var characteristics: [String: CBCharacteristic] = [:]
    private var features: Features?
    private var subscriptions: Set<String> = []
    private var commandTimeout: DispatchWorkItem?
    private var connectionTimeout: DispatchWorkItem?
    private var scanTimeout: DispatchWorkItem?
    private var scanRequested = false
    private var lastPacketLog: Date = .distantPast
    private var endingConnection = false
    private var waitingToWrite = false

    var busy: Bool { session.pending != nil }
    var ownsControl: Bool { session.ownsControl }
    var targetSpeed: Int? { speedTarget.value }
    func displaySpeed(_ kmh: Double) -> String {
        String(format: "%.1f", kmh / 1.609344)
    }
    var targetLabel: String {
        targetSpeed.map { displaySpeed(Double($0) / 100) } ?? "—"
    }
    var rangeLabel: String {
        guard let range else { return "Waiting for supported speed range" }
        return "\(displaySpeed(Double(range.minimum) / 100))–\(displaySpeed(Double(range.lastStep) / 100)) mph"
    }

    func offersStart(at date: Date) -> Bool {
        BeltState.observed(speed: speed, updatedAt: lastSample, now: date) == .stopped &&
            expectedBeltState == nil && session.pending != .start && session.pending != .stop && !session.stopQueued
    }

    func canAdjustSpeed(at date: Date) -> Bool {
        controlsAvailable && ownsControl && !session.stopQueued && session.pending != .stop &&
            expectedBeltState != .stopped && targetSpeed != nil && range != nil &&
            BeltState.observed(speed: speed, updatedAt: lastSample, now: date) != .unknown
    }

    func scan() {
        guard !connected && !connecting else { return }
        scanRequested = true
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        } else if central.state == .poweredOn {
            startScan()
        } else {
            centralManagerDidUpdateState(central)
        }
    }

    private func startScan() {
        scanRequested = false
        scanTimeout?.cancel()
        peripherals.removeAll()
        devices.removeAll()
        scanning = true
        status = "Looking for nearby Bluetooth devices"
        notice = "Select your pad. Urevo devices often appear as URTM041."
        log("Scan started (all Bluetooth LE advertisements)")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        let timeout = DispatchWorkItem { [weak self] in self?.stopScan() }
        scanTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeout)
    }

    func stopScan() {
        central?.stopScan()
        scanTimeout?.cancel()
        scanning = false
        if !connecting && !connected {
            status = devices.isEmpty ? "No devices found" : "Choose your walking pad"
            if devices.isEmpty { notice = "Check that the pad is powered on, then scan again. Disconnect it from the Urevo phone app first." }
        }
    }

    func connect(_ device: NearbyPad) {
        guard let peripheral = peripherals[device.id], !connected && !connecting else { return }
        stopScan()
        resetCapabilities()
        endingConnection = false
        pad = peripheral
        pad?.delegate = self
        deviceName = device.name
        connecting = true
        status = "Connecting to \(device.name)"
        notice = "Checking which controls this pad supports. Connecting does not start the belt."
        log("Connecting to \(device.name), \(device.id)")
        central.connect(peripheral)
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.connecting else { return }
            self.failConnection("Connection timed out. Move closer and close other treadmill apps.")
        }
        connectionTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
    }

    func disconnect() {
        guard let pad else { return }
        endingConnection = true
        session.invalidate()
        controlsAvailable = false
        commandTimeout?.cancel()
        central.cancelPeripheralConnection(pad)
        notice = "Disconnecting does not stop the belt. Use the physical remote if it is moving."
        log("User disconnected; no motor command sent")
    }

    func enableControls() {
        guard controlsAvailable, !ownsControl, !busy else { return }
        submit(.requestControl)
    }

    func start() {
        guard controlsAvailable, ownsControl, !busy, offersStart(at: Date()) else { return }
        expectedBeltState = .moving
        submit(.start)
    }

    func toggleBelt() {
        offersStart(at: Date()) ? start() : stop()
    }

    func stop() {
        guard controlsAvailable, ownsControl else { return }
        expectedBeltState = .stopped
        reconcileSpeedTarget()
        submit(.stop)
    }

    func adjustSpeed(_ direction: Int) {
        guard canAdjustSpeed(at: Date()), let range, let targetSpeed else { return }
        let next = range.stepped(from: targetSpeed, direction: direction)
        guard next != targetSpeed, range.contains(next) else { return }
        speedTarget.request(next, at: Date())
        submit(.speed(next))
    }

    private func reconcileSpeedTarget() {
        speedTarget.cancelRequest()
        if let speed, let range { speedTarget.observe(speed, range: range, at: Date()) }
    }

    private func submit(_ command: ControlCommand) {
        if command == .stop, waitingToWrite, let stop = session.replaceUnsentWithStop() {
            transmit(stop)
            return
        }
        if let send = session.begin(command) { transmit(send) }
        else if session.stopQueued {
            notice = "Stop is next, waiting for the pad’s current response. Use the physical remote for an immediate stop."
            log("Stop prioritized after current procedure")
        } else if session.queuedSpeed != nil {
            notice = "Speed target updated; waiting for the current command’s acknowledgement."
        }
    }

    private func transmit(_ command: ControlCommand) {
        guard connected, !endingConnection else { return }
        notice = "\(command.title): waiting for the pad to acknowledge…"
        commandTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.session.pending != nil else { return }
            self.failConnection("The pad did not acknowledge the command. Its belt may still be moving. Use the physical remote; reconnect to try again.")
        }
        commandTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
        waitingToWrite = true
        writePendingCommand()
    }

    private func writePendingCommand() {
        guard waitingToWrite, let command = session.pending, let pad,
              let control = characteristics["2AD9"], connected, !endingConnection else { return }
        let type: CBCharacteristicWriteType = control.properties.contains(.write) ? .withResponse : .withoutResponse
        if type == .withoutResponse && !pad.canSendWriteWithoutResponse {
            log("Waiting for Bluetooth write capacity")
            return
        }
        waitingToWrite = false
        log("TX 2AD9 \(hex(command.data)) [\(command.title), \(type == .withResponse ? "write" : "writeWithoutResponse")]")
        pad.writeValue(command.data, for: control, type: type)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard peripheral == pad else { return }
        writePendingCommand()
    }

    private func failConnection(_ message: String) {
        notice = message
        log(message)
        endingConnection = true
        waitingToWrite = false
        session.invalidate()
        controlsAvailable = false
        commandTimeout?.cancel()
        connectionTimeout?.cancel()
        if let pad { central.cancelPeripheralConnection(pad) }
        connecting = false
        status = "Connection ended"
    }

    private func resetCapabilities() {
        waitingToWrite = false
        commandTimeout?.cancel()
        connectionTimeout?.cancel()
        session.invalidate()
        characteristics.removeAll()
        subscriptions.removeAll()
        features = nil
        range = nil
        controlsAvailable = false
        speed = nil
        distance = nil
        elapsed = nil
        calories = nil
        lastSample = nil
        speedTarget = SpeedTarget()
        expectedBeltState = nil
    }

    private func updateCapabilities() {
        guard connected, !endingConnection else { return }
        let control = characteristics["2AD9"]
        controlsAvailable = features?.supportsSpeed == true && range != nil &&
            (control?.properties.contains(.write) == true || control?.properties.contains(.writeWithoutResponse) == true) &&
            control?.properties.contains(.indicate) == true &&
            subscriptions.isSuperset(of: ["2AD9", "2ACD", "2ADA"])
        if controlsAvailable && !ownsControl && !busy {
            status = "Connected · controls available"
            notice = "Enable controls to request permission from the pad. Enabling controls does not start the belt."
        }
    }

    func copyDiagnostics() {
        let header = "WalkingPad diagnostics\nDevice: \(deviceName)\nConnected: \(connected)\nControls available: \(controlsAvailable)\nOwns control: \(ownsControl)\n"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(header + diagnostics.joined(separator: "\n"), forType: .string)
    }

    private func log(_ line: String) {
        diagnostics.append("\(Date().formatted(date: .omitted, time: .standard))  \(line)")
        if diagnostics.count > 250 { diagnostics.removeFirst(diagnostics.count - 250) }
    }

    private func hex(_ data: Data) -> String { data.map { String(format: "%02X", $0) }.joined(separator: " ") }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("Bluetooth state: \(central.state.rawValue)")
        if central.state == .poweredOn {
            if scanRequested { startScan() }
            return
        }
        resetCapabilities()
        scanning = false
        connecting = false
        connected = false
        switch central.state {
        case .unauthorized:
            status = "Bluetooth permission needed"
            notice = "Allow WalkingPad in System Settings → Privacy & Security → Bluetooth, then scan again."
        case .poweredOff:
            status = "Bluetooth is turned off"
            notice = "Turn on Bluetooth in System Settings, then scan again."
        case .unsupported:
            status = "Bluetooth LE is unavailable"
            notice = "This Mac does not support the required Bluetooth connection."
        default:
            status = "Waiting for Bluetooth"
            notice = "Bluetooth is initializing. If the pad is moving, use its physical remote."
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "Unnamed device"
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let likely = name.uppercased().contains("URTM") || name.uppercased().contains("UREVO") || services.contains(CBUUID(string: "1826"))
        peripherals[peripheral.identifier] = peripheral
        let device = NearbyPad(id: peripheral.identifier, name: name, signal: RSSI.intValue, likelyPad: likely)
        devices.removeAll { $0.id == device.id }
        devices.append(device)
        devices.sort { $0.likelyPad != $1.likelyPad ? $0.likelyPad : $0.signal > $1.signal }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral == pad, !endingConnection else { central.cancelPeripheralConnection(peripheral); return }
        connecting = false
        connected = true
        connectionTimeout?.cancel()
        status = "Connected · inspecting capabilities"
        log("Connected; discovering services")
        peripheral.discoverServices(nil)
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.connected, !self.controlsAvailable else { return }
            self.status = "Connected · controls unavailable"
            self.notice = "This pad has not exposed all required FTMS controls. You can read available telemetry; remote replacement is not yet verified for this firmware. Copy diagnostics for investigation."
            self.log("Capability check incomplete or unsupported after 12 seconds")
        }
        connectionTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeout)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral == pad else { return }
        failConnection("Could not connect: \(error?.localizedDescription ?? "the pad is unavailable").")
        connected = false
        pad = nil
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral == pad else { return }
        let wasExpected = endingConnection
        resetCapabilities()
        connected = false
        connecting = false
        pad = nil
        status = "Disconnected"
        if !wasExpected { notice = "Bluetooth connection lost. The belt may continue moving—use the physical remote. Reconnect manually to resume control." }
        log("Disconnected: \(error?.localizedDescription ?? "connection closed")")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral == pad, !endingConnection else { return }
        if let error { failConnection("Service discovery failed: \(error.localizedDescription)"); return }
        let services = peripheral.services ?? []
        log("Services: \(services.map { $0.uuid.uuidString }.joined(separator: ", "))")
        guard let ftms = services.first(where: { $0.uuid == CBUUID(string: "1826") }) else {
            status = "Connected · unsupported Bluetooth protocol"
            notice = "This pad does not expose the standard Fitness Machine Service. Proprietary Urevo control is not implemented. Copy diagnostics to identify this firmware."
            connectionTimeout?.cancel()
            return
        }
        peripheral.discoverCharacteristics(nil, for: ftms)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral == pad, !endingConnection else { return }
        if let error { failConnection("Characteristic discovery failed: \(error.localizedDescription)"); return }
        for characteristic in service.characteristics ?? [] {
            let id = characteristic.uuid.uuidString
            characteristics[id] = characteristic
            log("Characteristic \(id), properties 0x\(String(characteristic.properties.rawValue, radix: 16))")
            if ["2ACC", "2AD4"].contains(id), characteristic.properties.contains(.read) {
                peripheral.readValue(for: characteristic)
            }
            if ["2AD9", "2ACD", "2ADA"].contains(id),
               characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
        updateCapabilities()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral == pad, !endingConnection else { return }
        let id = characteristic.uuid.uuidString
        log("Subscription \(id): \(characteristic.isNotifying), \(error?.localizedDescription ?? "OK")")
        if characteristic.isNotifying && error == nil { subscriptions.insert(id) }
        else {
            subscriptions.remove(id)
            if ownsControl { failConnection("A required Bluetooth notification stream ended. Use the physical remote if the belt is moving."); return }
        }
        updateCapabilities()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral == pad, !endingConnection, characteristic.uuid == CBUUID(string: "2AD9") else { return }
        if let error { failConnection("Bluetooth command failed: \(error.localizedDescription). Use the physical remote if needed.") }
        else { log("2AD9 write delivered; awaiting FTMS indication") }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral == pad, !endingConnection else { return }
        let id = characteristic.uuid.uuidString
        if let error { log("Read \(id) failed: \(error.localizedDescription)"); return }
        guard let data = characteristic.value else { return }
        if id != "2ACD" || Date().timeIntervalSince(lastPacketLog) > 5 {
            log("RX \(id) \(hex(data))")
            if id == "2ACD" { lastPacketLog = Date() }
        }
        do {
            switch id {
            case "2ACC":
                features = try Features(data: data)
                log("Speed target support: \(features?.supportsSpeed == true)")
                updateCapabilities()
            case "2AD4":
                let discovered = try SpeedRange(data: data)
                range = discovered
                if let speed { speedTarget.observe(speed, range: discovered, at: Date()) }
                log("Speed range: \(discovered.minimum)…\(discovered.maximum), step \(discovered.increment) (0.01 km/h)")
                updateCapabilities()
            case "2ACD":
                let isURTM041 = deviceName.uppercased() == "URTM041"
                let sample = try TreadmillSample(data: data, allowsURTM041Extension: isURTM041)
                if let value = sample.speed {
                    speed = value
                    lastSample = Date()
                    let speedInFlight: Bool
                    if case .speed = session.pending { speedInFlight = true } else { speedInFlight = false }
                    if let range, !speedInFlight, session.queuedSpeed == nil { speedTarget.observe(value, range: range, at: Date()) }
                    if expectedBeltState == (value > 0 ? .moving : .stopped) { expectedBeltState = nil }
                }
                if let value = sample.distance { distance = value }
                if let value = sample.elapsed { elapsed = value }
                if let value = sample.calories { calories = value }
            case "2ADA":
                guard let opcode = data.first else { throw PacketError.truncated }
                if opcode == 0xFF || opcode == 0x01 {
                    failConnection("The pad revoked control or reset. The belt may still be moving—use the physical remote. Reconnect manually to request control again.")
                }
            case "2AD9":
                let reply = try ControlReply(data: data)
                guard let outcome = session.receive(reply) else { log("Ignored unsolicited or mismatched control response"); return }
                commandTimeout?.cancel()
                log("\(outcome.completed.title): \(reply.message)")
                if reply.result != 1 {
                    reconcileSpeedTarget()
                    if outcome.completed == .start || outcome.completed == .stop { expectedBeltState = nil }
                }
                if let next = outcome.next { transmit(next) }
                else if reply.result == 1 {
                    status = ownsControl ? "Connected · you have control" : "Connected"
                    notice = outcome.completed == .requestControl ? "Controls enabled. Start uses the pad’s current start speed. Watch the belt before stepping on." : "\(outcome.completed.title) accepted by the pad. Watch live speed to confirm the belt’s response."
                } else {
                    notice = outcome.completed == .stop ? "Stop was rejected by the pad. Use the physical remote. \(reply.message)" : reply.message
                }
            default: break
            }
        } catch { log("Invalid \(id) packet ignored: \(hex(data))") }
    }
}
