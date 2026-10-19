import Foundation

public enum PacketError: Error { case truncated, invalid }

private struct Reader {
    let bytes: [UInt8]
    var offset = 0
    mutating func uint(_ count: Int) throws -> Int {
        guard offset + count <= bytes.count else { throw PacketError.truncated }
        defer { offset += count }
        return (0..<count).reduce(0) { $0 | Int(bytes[offset + $1]) << ($1 * 8) }
    }
}

public struct SpeedRange: Equatable {
    public let minimum: Int
    public let maximum: Int
    public let increment: Int
    public init(data: Data) throws {
        var reader = Reader(bytes: Array(data))
        minimum = try reader.uint(2)
        maximum = try reader.uint(2)
        increment = try reader.uint(2)
        guard data.count == 6, minimum < maximum, increment > 0,
              increment <= maximum - minimum else { throw PacketError.invalid }
    }
    public func contains(_ hundredths: Int) -> Bool {
        (minimum...maximum).contains(hundredths) && (hundredths - minimum) % increment == 0
    }
    public var lastStep: Int { minimum + ((maximum - minimum) / increment) * increment }
    public func nearest(_ value: Int) -> Int {
        let bounded = min(lastStep, max(minimum, value))
        return min(lastStep, minimum + ((bounded - minimum + increment / 2) / increment) * increment)
    }
    public func stepped(from value: Int, direction: Int) -> Int {
        if value < minimum { return minimum }
        return min(lastStep, max(minimum, value + (direction > 0 ? 1 : -1) * increment))
    }
}

/// Keep the requested speed visible during a ramp, then return to live telemetry.
public struct SpeedTarget {
    public private(set) var value: Int?
    private var requestedAt: Date?
    public init() {}
    public mutating func request(_ value: Int, at date: Date) {
        self.value = value
        requestedAt = date
    }
    public mutating func observe(_ speed: Double, range: SpeedRange, at date: Date) {
        let raw = Int((speed * 100).rounded())
        if let requestedAt, let value, date.timeIntervalSince(requestedAt) < 10,
           abs(raw - value) > range.increment / 2 { return }
        requestedAt = nil
        value = raw == 0 ? 0 : range.nearest(raw)
    }
    public mutating func cancelRequest() { requestedAt = nil }
}

public enum BeltState {
    case unknown, stopped, moving
    public static func observed(speed: Double?, updatedAt: Date?, now: Date) -> Self {
        guard let speed, let updatedAt, now.timeIntervalSince(updatedAt) <= 5 else { return .unknown }
        return speed > 0 ? .moving : .stopped
    }
}

public struct Features {
    public let machine: UInt32
    public let targets: UInt32
    public var supportsSpeed: Bool { targets & 1 != 0 }
    public init(data: Data) throws {
        guard data.count == 8 else { throw PacketError.invalid }
        var reader = Reader(bytes: Array(data))
        machine = UInt32(try reader.uint(4))
        targets = UInt32(try reader.uint(4))
    }
}

/// Bluetooth SIG FTMS Treadmill Data (2ACD), little-endian standard fields.
public struct TreadmillSample: Equatable {
    public var speed: Double?
    public var distance: Int?
    public var elapsed: Int?
    public var calories: Int?

    public init(data: Data, allowsURTM041Extension: Bool = false) throws {
        var reader = Reader(bytes: Array(data))
        let flags = try reader.uint(2)
        let hasURTM041Extension = allowsURTM041Extension && flags & 0x2000 != 0
        guard flags & (hasURTM041Extension ? 0xC000 : 0xE000) == 0 else { throw PacketError.invalid }
        if flags & 1 == 0 { speed = Double(try reader.uint(2)) / 100 }
        if flags & (1 << 1) != 0 { _ = try reader.uint(2) }
        if flags & (1 << 2) != 0 { distance = try reader.uint(3) }
        if flags & (1 << 3) != 0 { _ = try reader.uint(4) }
        if flags & (1 << 4) != 0 { _ = try reader.uint(4) }
        if flags & (1 << 5) != 0 { _ = try reader.uint(1) }
        if flags & (1 << 6) != 0 { _ = try reader.uint(1) }
        if flags & (1 << 7) != 0 {
            calories = try reader.uint(2)
            _ = try reader.uint(3)
        }
        if flags & (1 << 8) != 0 { _ = try reader.uint(1) }
        if flags & (1 << 9) != 0 { _ = try reader.uint(1) }
        if flags & (1 << 10) != 0 { elapsed = try reader.uint(2) }
        if flags & (1 << 11) != 0 { _ = try reader.uint(2) }
        if flags & (1 << 12) != 0 { _ = try reader.uint(4) }
        // Observed on URTM041: bit 13 adds three vendor bytes after standard
        // fields. Their meaning is unverified; deliberately do not expose steps.
        if hasURTM041Extension { _ = try reader.uint(3) }
        guard reader.offset == data.count else { throw PacketError.invalid }
    }
}

public enum ControlCommand: Equatable {
    case requestControl, start, stop, speed(Int)
    public var opcode: UInt8 {
        switch self { case .requestControl: return 0; case .speed: return 2; case .start: return 7; case .stop: return 8 }
    }
    public var data: Data {
        switch self {
        case .speed(let value):
            guard (0...65535).contains(value) else { return Data() }
            return Data([opcode, UInt8(value & 255), UInt8(value >> 8)])
        case .stop: return Data([opcode, 1])
        default: return Data([opcode])
        }
    }
    public var title: String {
        switch self { case .requestControl: return "Enable controls"; case .start: return "Start"; case .stop: return "Stop"; case .speed: return "Set speed" }
    }
}

public struct ControlReply: Equatable {
    public let opcode: UInt8
    public let result: UInt8
    public init(data: Data) throws {
        let bytes = Array(data)
        guard bytes.count == 3, bytes[0] == 0x80, (1...5).contains(bytes[2]) else { throw PacketError.invalid }
        opcode = bytes[1]
        result = bytes[2]
    }
    public var message: String {
        switch result {
        case 1: return "Accepted"
        case 2: return "This command is not supported by the pad."
        case 3: return "The pad rejected the command parameters."
        case 4: return "The pad could not complete the command."
        default: return "Control permission was denied. Close other treadmill apps, then reconnect."
        }
    }
}

/// One outstanding FTMS procedure; speed bursts coalesce to their latest target.
/// Stop discards queued speed changes and takes precedence after the current ACK.
public struct ControlSession {
    public private(set) var ownsControl = false
    public private(set) var pending: ControlCommand?
    public private(set) var stopQueued = false
    public private(set) var queuedSpeed: Int?
    public init() {}

    public mutating func begin(_ command: ControlCommand) -> ControlCommand? {
        guard command == .requestControl || ownsControl else { return nil }
        if command == .stop { queuedSpeed = nil }
        if pending != nil {
            if command == .stop, pending != .stop { stopQueued = true }
            if case .speed(let value) = command, !stopQueued, pending != .stop { queuedSpeed = value }
            return nil
        }
        pending = command
        return command
    }

    /// Unrelated indications never complete the current procedure.
    public mutating func receive(_ reply: ControlReply) -> (completed: ControlCommand, next: ControlCommand?)? {
        guard let command = pending, command.opcode == reply.opcode else { return nil }
        pending = nil
        if command == .requestControl { ownsControl = reply.result == 1 }
        if reply.result == 5 { ownsControl = false }
        let shouldStop = stopQueued && ownsControl
        let speed = reply.result == 1 && ownsControl && !shouldStop ? queuedSpeed : nil
        stopQueued = false
        queuedSpeed = nil
        let next = shouldStop ? begin(.stop) : speed.flatMap { command == .speed($0) ? nil : begin(.speed($0)) }
        return (command, next)
    }

    public mutating func invalidate() {
        ownsControl = false
        pending = nil
        stopQueued = false
        queuedSpeed = nil
    }

    /// The transport may replace a procedure only before any bytes are sent.
    public mutating func replaceUnsentWithStop() -> ControlCommand? {
        guard ownsControl, pending != nil else { return nil }
        pending = .stop
        stopQueued = false
        queuedSpeed = nil
        return .stop
    }
}
