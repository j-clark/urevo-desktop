import Foundation
import XCTest
@testable import WalkingPadCore

final class FTMSTests: XCTestCase {
    func testMinimalSpeedAndMoreData() throws {
        XCTAssertEqual(try TreadmillSample(data: Data([0, 0, 0x41, 1])).speed, 3.21)
        XCTAssertNil(try TreadmillSample(data: Data([1, 0])).speed)
    }

    func testEveryOptionalFieldAndTruncation() throws {
        // All standard fields in SIG order. Distance deliberately exceeds uint16.
        let bytes: [UInt8] = [0xFE, 0x1F, 0x2C, 1, 0, 0, 0x56, 0x34, 0x12,
                             0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                             42, 0, 0, 0, 0, 80, 0, 0x10, 0x0E, 0, 0, 0, 0, 0, 0]
        let sample = try TreadmillSample(data: Data(bytes))
        XCTAssertEqual(sample.speed, 3)
        XCTAssertEqual(sample.distance, 0x123456)
        XCTAssertEqual(sample.calories, 42)
        XCTAssertEqual(sample.elapsed, 3600)
        for length in 0..<bytes.count {
            XCTAssertThrowsError(try TreadmillSample(data: Data(bytes.prefix(length))), "Length \(length)")
        }
    }

    func testMalformedTelemetry() {
        for bytes: [UInt8] in [[], [0], [0, 0], [0, 0, 10], [0, 0x20, 0, 0], [0, 0, 0, 0, 1]] {
            XCTAssertThrowsError(try TreadmillSample(data: Data(bytes)))
        }
    }

    func testCapturedURTM041Telemetry() throws {
        let capture = Data([0x84, 0x25, 0x41, 0x01, 0x0C, 0x03, 0x00, 0x2E, 0x00,
                            0x00, 0x00, 0x00, 0x00, 0xDB, 0x03, 0x85, 0x05, 0x00])
        XCTAssertThrowsError(try TreadmillSample(data: capture))
        let sample = try TreadmillSample(data: capture, allowsURTM041Extension: true)
        XCTAssertEqual(sample.speed, 3.21)
        XCTAssertEqual(sample.distance, 780)
        XCTAssertEqual(sample.calories, 46)
        XCTAssertEqual(sample.elapsed, 987)
        for length in 0..<capture.count {
            XCTAssertThrowsError(try TreadmillSample(data: capture.prefix(length), allowsURTM041Extension: true))
        }
        XCTAssertThrowsError(try TreadmillSample(data: capture + Data([0]), allowsURTM041Extension: true))
        var otherFlag = capture
        otherFlag[1] |= 0x40
        XCTAssertThrowsError(try TreadmillSample(data: otherFlag, allowsURTM041Extension: true))
    }

    func testCapturedURTM041Capabilities() throws {
        XCTAssertTrue(try Features(data: Data([0x45, 0x56, 0, 0, 5, 0, 0, 0])).supportsSpeed)
        let range = try SpeedRange(data: Data([0x60, 0, 0x83, 2, 0x20, 0]))
        XCTAssertEqual(range.minimum, 96)
        XCTAssertEqual(range.maximum, 643)
        XCTAssertEqual(range.lastStep, 640)
        XCTAssertTrue(range.contains(320))
        XCTAssertFalse(range.contains(321))
        XCTAssertEqual(range.nearest(321), 320)
        XCTAssertEqual(range.nearest(999), 640)
        XCTAssertEqual(range.nearest(0), 96)
        XCTAssertEqual(String(format: "%.1f", Double(range.nearest(321) + range.increment) / 100 / 1.609344), "2.2")
    }

    func testSpeedTargetFollowsLiveSpeedAndPreservesRequestedSpeedDuringRamp() throws {
        let range = try SpeedRange(data: Data([0x60, 0, 0x83, 2, 0x20, 0]))
        let now = Date()
        var target = SpeedTarget()
        XCTAssertNil(target.value)
        target.observe(3.21, range: range, at: now)
        XCTAssertEqual(target.value, 320)
        target.request(384, at: now)
        target.observe(3.4, range: range, at: now.addingTimeInterval(1))
        XCTAssertEqual(target.value, 384)
        target.observe(3.85, range: range, at: now.addingTimeInterval(2))
        XCTAssertEqual(target.value, 384)
        target.observe(3.21, range: range, at: now.addingTimeInterval(3))
        XCTAssertEqual(target.value, 320) // Remote changes follow live speed again.
        target.request(384, at: now.addingTimeInterval(4))
        target.observe(3.21, range: range, at: now.addingTimeInterval(15))
        XCTAssertEqual(target.value, 320) // Unreached requests expire.
        target.request(384, at: now.addingTimeInterval(16))
        target.cancelRequest()
        target.observe(0, range: range, at: now.addingTimeInterval(17))
        XCTAssertEqual(target.value, 0)
    }

    func testBeltStateRequiresFreshObservedSpeed() {
        let now = Date()
        XCTAssertEqual(BeltState.observed(speed: nil, updatedAt: nil, now: now), .unknown)
        XCTAssertEqual(BeltState.observed(speed: 0, updatedAt: now, now: now), .stopped)
        XCTAssertEqual(BeltState.observed(speed: 3.21, updatedAt: now, now: now), .moving)
        XCTAssertEqual(BeltState.observed(speed: 0, updatedAt: now.addingTimeInterval(-6), now: now), .unknown)
        XCTAssertEqual(BeltState.observed(speed: 3.21, updatedAt: now.addingTimeInterval(-6), now: now), .unknown)
    }

    func testCapabilitiesAndSpeedValidation() throws {
        XCTAssertTrue(try Features(data: Data([0, 0, 0, 0, 1, 0, 0, 0])).supportsSpeed)
        XCTAssertFalse(try Features(data: Data(repeating: 0, count: 8)).supportsSpeed)
        XCTAssertThrowsError(try Features(data: Data(repeating: 0, count: 7)))
        let range = try SpeedRange(data: Data([100, 0, 0x26, 2, 10, 0]))
        XCTAssertTrue(range.contains(100))
        XCTAssertTrue(range.contains(550))
        XCTAssertFalse(range.contains(101))
        XCTAssertFalse(range.contains(90))
        XCTAssertFalse(range.contains(560))
        XCTAssertEqual(range.lastStep, 550)
        XCTAssertThrowsError(try SpeedRange(data: Data([100, 0, 100, 0, 10, 0])))
        XCTAssertThrowsError(try SpeedRange(data: Data([100, 0, 0x58, 2, 0, 0])))
        XCTAssertThrowsError(try SpeedRange(data: Data([100, 0])))
    }

    func testCommandEncoding() {
        XCTAssertEqual(ControlCommand.requestControl.data, Data([0]))
        XCTAssertEqual(ControlCommand.start.data, Data([7]))
        XCTAssertEqual(ControlCommand.stop.data, Data([8, 1]))
        XCTAssertEqual(ControlCommand.speed(321).data, Data([2, 0x41, 1]))
        XCTAssertEqual(ControlCommand.speed(-1).data, Data())
    }

    private func response(_ opcode: UInt8, _ result: UInt8 = 1) throws -> ControlReply {
        try ControlReply(data: Data([0x80, opcode, result]))
    }

    func testNoControlWithoutSuccessfulPermissionResponse() throws {
        var session = ControlSession()
        XCTAssertNil(session.begin(.start))
        XCTAssertNil(session.begin(.speed(100)))
        XCTAssertNil(session.begin(.stop))
        XCTAssertEqual(session.begin(.requestControl), .requestControl)
        XCTAssertFalse(session.ownsControl)
        XCTAssertNil(session.receive(try response(7)))
        XCTAssertEqual(session.pending, .requestControl)
        _ = session.receive(try response(0, 5))
        XCTAssertFalse(session.ownsControl)
        XCTAssertNil(session.begin(.start))
        _ = session.begin(.requestControl)
        _ = session.receive(try response(0))
        XCTAssertTrue(session.ownsControl)
    }

    func testStopPriorityAndNoQueuedSpeedOrRestart() throws {
        var session = ControlSession()
        _ = session.begin(.requestControl)
        _ = session.receive(try response(0))
        XCTAssertEqual(session.begin(.speed(200)), .speed(200))
        XCTAssertNil(session.begin(.speed(300)))
        XCTAssertNil(session.begin(.start))
        XCTAssertNil(session.begin(.stop))
        XCTAssertTrue(session.stopQueued)
        let outcome = session.receive(try response(2))
        XCTAssertEqual(outcome?.next, .stop)
        XCTAssertEqual(session.pending, .stop)
        XCTAssertNil(session.receive(try response(8))?.next)
        XCTAssertNil(session.pending)
    }

    func testLostPermissionAndTimeoutClearCommands() throws {
        var session = ControlSession()
        _ = session.begin(.requestControl)
        _ = session.receive(try response(0))
        _ = session.begin(.start)
        _ = session.begin(.stop)
        XCTAssertNil(session.receive(try response(7, 5))?.next)
        XCTAssertFalse(session.ownsControl)
        XCTAssertFalse(session.stopQueued)
        _ = session.begin(.requestControl)
        session.invalidate()
        XCTAssertNil(session.receive(try response(0)))
        XCTAssertFalse(session.ownsControl)
        XCTAssertNil(session.pending)
    }

    func testStopReplacesStartBeforeTransportSendsIt() throws {
        var session = ControlSession()
        XCTAssertNil(session.replaceUnsentWithStop())
        _ = session.begin(.requestControl)
        _ = session.receive(try response(0))
        _ = session.begin(.start)
        XCTAssertEqual(session.replaceUnsentWithStop(), .stop)
        XCTAssertEqual(session.pending, .stop)
        XCTAssertNil(session.receive(try response(7)))
        XCTAssertNil(session.receive(try response(8))?.next)
        XCTAssertNil(session.pending)
    }

    func testInvalidReplies() {
        for bytes: [UInt8] in [[], [0x80], [0x80, 0], [0, 0, 1], [0x80, 0, 0], [0x80, 0, 6], [0x80, 0, 1, 0]] {
            XCTAssertThrowsError(try ControlReply(data: Data(bytes)))
        }
    }

    func testSpeedBurstCoalescesAndClampsToNativeRange() throws {
        let range = try SpeedRange(data: Data([0x60, 0, 0x83, 2, 0x20, 0]))
        var session = ControlSession()
        _ = session.begin(.requestControl)
        _ = session.receive(try response(0))
        var desired = 320
        desired = range.stepped(from: desired, direction: 1)
        XCTAssertEqual(session.begin(.speed(desired)), .speed(352))
        for _ in 0..<20 {
            desired = range.stepped(from: desired, direction: 1)
            XCTAssertNil(session.begin(.speed(desired)))
        }
        XCTAssertEqual(desired, 640)
        XCTAssertEqual(session.queuedSpeed, 640)
        desired = range.stepped(from: desired, direction: -1)
        _ = session.begin(.speed(desired))
        XCTAssertEqual(session.receive(try response(2))?.next, .speed(608))
        XCTAssertNil(session.queuedSpeed)
        XCTAssertNil(session.receive(try response(2))?.next)
        for _ in 0..<30 { desired = range.stepped(from: desired, direction: -1) }
        XCTAssertEqual(desired, 96)
    }

    func testSpeedBurstReturningToOutstandingTargetNeedsNoDuplicateWrite() throws {
        var session = ControlSession()
        _ = session.begin(.requestControl)
        _ = session.receive(try response(0))
        _ = session.begin(.speed(352))
        _ = session.begin(.speed(384))
        _ = session.begin(.speed(352))
        XCTAssertNil(session.receive(try response(2))?.next)
        XCTAssertNil(session.pending)
    }

    func testStopCancelsSpeedBurstAndBlocksNewSpeedsUntilStopCompletes() throws {
        var session = ControlSession()
        _ = session.begin(.requestControl)
        _ = session.receive(try response(0))
        _ = session.begin(.start)
        _ = session.begin(.speed(352))
        _ = session.begin(.speed(384))
        _ = session.begin(.stop)
        XCTAssertNil(session.queuedSpeed)
        _ = session.begin(.speed(416))
        XCTAssertNil(session.queuedSpeed)
        XCTAssertEqual(session.receive(try response(7))?.next, .stop)
        _ = session.begin(.stop)
        _ = session.begin(.speed(448))
        XCTAssertFalse(session.stopQueued)
        XCTAssertNil(session.queuedSpeed)
        XCTAssertNil(session.receive(try response(8))?.next)
        XCTAssertNil(session.pending)
    }

    func testRejectedCommandsAndOwnershipLossDiscardSpeedBurst() throws {
        for failure: UInt8 in [2, 3, 4, 5] {
            var session = ControlSession()
            _ = session.begin(.requestControl)
            _ = session.receive(try response(0))
            _ = session.begin(.speed(352))
            _ = session.begin(.speed(384))
            XCTAssertNil(session.receive(try response(2, failure))?.next)
            XCTAssertNil(session.queuedSpeed)
            XCTAssertNil(session.pending)
        }
        var session = ControlSession()
        _ = session.begin(.requestControl)
        _ = session.receive(try response(0))
        _ = session.begin(.speed(352))
        _ = session.begin(.speed(384))
        session.invalidate()
        XCTAssertNil(session.queuedSpeed)
        XCTAssertNil(session.receive(try response(2)))
        XCTAssertNil(session.pending)
        XCTAssertFalse(session.ownsControl)
    }
}
