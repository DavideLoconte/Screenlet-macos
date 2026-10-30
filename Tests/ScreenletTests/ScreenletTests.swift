import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import Screenlet

// The shared vectors (PROTOCOL.md, vectors.json): the Android app and
// Screenlet for GNOME check the same values.
private let vectors: [String: [String: Any]] = {
    let url = Bundle.module.url(forResource: "vectors", withExtension: "json")!
    let all = try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    return all.compactMapValues { $0 as? [String: Any] }  // the sections, not the comment
}()

private func hex(_ section: String, _ key: String) -> Data {
    Companion.unhex((vectors[section]![key] as! String).replacingOccurrences(of: " ", with: ""))!
}

@Test func pairingCodeAndCommitmentMatchTheVectors() {
    let code = Companion.pairingCode(hex("pairing", "cert_b"), hex("pairing", "cert_a"),
                                     ours: hex("pairing", "pc_nonce"), theirs: hex("pairing", "app_nonce"))
    #expect(code == vectors["pairing"]!["code"] as? String)
    #expect(Companion.commitment(nonce: hex("commitment", "app_nonce"), appCert: hex("commitment", "app_cert"),
                                 pcCert: hex("commitment", "pc_cert")) == vectors["commitment"]!["commit"] as? String)
}

@Test func sealsTheVector() {
    let v = vectors["sealed"]!
    let packet = Channel.seal(hex("sealed", "body"), key: SymmetricKey(data: hex("sealed", "key")),
                              direction: UInt32(v["direction"] as! Int), count: UInt64(v["count"] as! Int))
    #expect(packet == hex("sealed", "packet"))
}

@Test func cableFrameMatchesTheVector() {
    #expect(Cable.frame(.datagram, 0, hex("cable_frame", "data")) == hex("cable_frame", "frame"))
}

@Test func inputVectorParses() {
    let monitor = Monitor(display: 0, size: (1000, 1000), quiet: true)
    let input = Input(monitor: monitor, size: (1000, 1000), clock: { 0 })
    #expect(input.packet(hex("input", "body")))
    #expect(monitor.posted.contains("near"))  // the pen came in range
}

@Test func sizesAtTheTabletsProportions() {
    #expect(Sizes.all((2000, 1200)).map { [$0.0, $0.1] } == [[2000, 1200], [1920, 1152], [1680, 1008], [1440, 864], [1280, 768]])
    #expect(Sizes.auto((2000, 1200), wifi: false) == (2000, 1200))
    #expect(Sizes.auto((2800, 1752), wifi: true) == (1920, 1202))
    #expect(Sizes.auto((2560, 1600), wifi: true) == (1920, 1200))
    #expect(Sizes.auto((2000, 1200), wifi: true) == (2000, 1200))
    #expect(Sizes.auto((2400, 1500), wifi: true) == (1920, 1200))   // not in the table: closest to 1920x1200
}

@Test func chosenAndMirroredSizes() {
    #expect(Sizes.choose("tablet", (2000, 1200), wifi: true) == (2000, 1200))
    #expect(Sizes.choose("1440x864", (2000, 1200), wifi: true) == (1440, 864))
    #expect(Sizes.choose("1440x900", (2000, 1200), wifi: true) == (2000, 1200))  // wrong proportions: automatic
    #expect(Sizes.fit((2880, 1800), into: (2000, 1200)) == (1920, 1200))
    #expect(Sizes.fit((1440, 900), into: (1200, 2000)) == (1440, 900))   // already smaller: unchanged
}

@Test func cableFramesAcrossReads() throws {
    let stream = Cable.frame(.data, 3, Data([1, 2, 3])) + Cable.frame(.datagram, 0, Data(repeating: 9, count: 40))
    var buffer = Data(stream.prefix(5))
    #expect(try Cable.frames(&buffer).isEmpty)
    buffer += stream.dropFirst(5).prefix(10)
    let first = try Cable.frames(&buffer)
    #expect(first.count == 1 && first[0].0 == .data && first[0].1 == 3 && first[0].2 == Data([1, 2, 3]))
    buffer += stream.dropFirst(15)
    let second = try Cable.frames(&buffer)
    #expect(second.count == 1 && second[0].0 == .datagram && second[0].2.count == 40 && buffer.isEmpty)
    var huge = Data([Cable.Kind.data.rawValue, 1]) + Data([0x7f, 0xff, 0xff, 0xff])
    #expect(throws: (any Error).self) { try Cable.frames(&huge) }
}

@Test func channelOpensFreshPacketsOnceAndLateOnesInTheWindow() throws {
    let key = SymmetricKey(size: .bits256)
    let channel = try Channel(key: key.withUnsafeBytes { Data($0) }, cable: nil)
    defer { channel.close() }
    func from(_ count: UInt64, _ body: UInt8 = Packet.keyframe) -> Data {
        Channel.seal(Data([body]), key: key, direction: Packet.fromApp, count: count)
    }
    channel.received(from(5))
    #expect(channel.receive(timeout: 0.1) == Data([Packet.keyframe]))
    channel.received(from(5))                                                  // replayed
    channel.received(from(3, Packet.ping))                                     // late, in the window: taken
    #expect(channel.receive(timeout: 0.1) == Data([Packet.ping]))
    var tampered = from(6)
    tampered[Packet.nonceSize] ^= 1
    channel.received(tampered)                                                 // not authentic
    channel.received(Channel.seal(Data([1]), key: key, direction: Packet.fromPC, count: 7))  // our own direction
    channel.received(Channel.seal(Data([1]), key: SymmetricKey(size: .bits256), direction: Packet.fromApp, count: 8))
    #expect(channel.receive(timeout: 0.1) == nil)
}

@Test func replayWindow() {
    var r = Replay()
    for c: UInt64 in [0, 2, 1, 70] { #expect(r.fresh(c)); r.accept(c) }
    #expect(!r.fresh(1) && !r.fresh(70) && !r.fresh(6))   // seen, seen, too old
    #expect(r.fresh(69) && r.fresh(71))
}

@Test func lengthPrefixedToStartCodes() {
    let avcc = Data([0, 0, 0, 2, 0x65, 1, 0, 0, 0, 1, 0x41])
    #expect(Video.convert(avcc, lengthSize: 4, into: Data([0, 0, 0, 1, 0x67]))
            == Data([0, 0, 0, 1, 0x67, 0, 0, 0, 1, 0x65, 1, 0, 0, 0, 1, 0x41]))
}

private final class Clock { var now = 0.0 }

private func fingers(_ list: [(UInt8, UInt16, UInt16)]) -> Data {
    var body = Data([Packet.input, UInt8(list.count)])
    for (id, x, y) in list { body.append(id); body.append(big: x); body.append(big: y) }
    body.append(0)
    return body
}

private let down = "\(CGEventType.leftMouseDown.rawValue)", up = "\(CGEventType.leftMouseUp.rawValue)"
private let moved = "\(CGEventType.mouseMoved.rawValue)", dragged = "\(CGEventType.leftMouseDragged.rawValue)"
private let rightDown = "\(CGEventType.rightMouseDown.rawValue)"

@Test func aFingerMovesThePointerAtOnceAndClicksWhenItLifts() {
    let clock = Clock()
    let input = Input(monitor: Monitor(display: 0, size: (1000, 1000), quiet: true), size: (1000, 1000), clock: { clock.now })
    #expect(input.packet(fingers([(1, 10000, 10000)])))
    #expect(input.monitor.posted == [moved])                 // no wait: the pointer is there
    clock.now = 0.05
    #expect(input.packet(fingers([])))
    #expect(input.monitor.posted == [moved, moved, down, up])
}

@Test func aFingerThatMovesDragsAtOnce() {
    let clock = Clock()
    let input = Input(monitor: Monitor(display: 0, size: (1000, 1000), quiet: true), size: (1000, 1000), clock: { clock.now })
    #expect(input.packet(fingers([(1, 10000, 10000)])))
    clock.now = 0.016
    #expect(input.packet(fingers([(1, 12000, 10000)])))      // 30 pixels on
    #expect(input.monitor.posted == [moved, moved, down, dragged])
}

@Test func aFingerHeldStillPressesAfterAMoment() {
    let clock = Clock()
    let input = Input(monitor: Monitor(display: 0, size: (1000, 1000), quiet: true), size: (1000, 1000), clock: { clock.now })
    #expect(input.packet(fingers([(1, 10000, 10000)])))
    clock.now = Input.hold
    input.check()
    #expect(input.monitor.clicks == [down])
}

@Test func twoFingersTappedAreTheRightButtonAndMovedScroll() {
    let clock = Clock()
    let input = Input(monitor: Monitor(display: 0, size: (1000, 1000), quiet: true), size: (1000, 1000), clock: { clock.now })
    #expect(input.packet(fingers([(1, 10000, 10000)])))
    clock.now = 0.02
    #expect(input.packet(fingers([(1, 10000, 10000), (2, 20000, 20000)])))
    clock.now = 0.1
    #expect(input.packet(fingers([])))
    #expect(input.monitor.clicks == [rightDown])
    #expect(!input.packet(Data([Packet.input, 11])))  // more fingers than a hand

    let scrolled = Input(monitor: Monitor(display: 0, size: (1000, 1000), quiet: true), size: (1000, 1000), clock: { clock.now })
    #expect(scrolled.packet(fingers([(1, 10000, 10000), (2, 20000, 10000)])))
    #expect(scrolled.packet(fingers([(1, 10000, 15000), (2, 20000, 15000)])))
    #expect(scrolled.packet(fingers([])))
    #expect(scrolled.monitor.posted == ["scroll began", "scroll ended"])
}

@Test func theCaptureRateFollowsThePanel() {
    #expect(DisplaySession.fps(nil) == 60)
    #expect(DisplaySession.fps(59.94) == 60)
    #expect(DisplaySession.fps(120.0) == 120)
    #expect(DisplaySession.fps(144.0) == 120)
}

@Test func statsStageByStage() {
    var body = Data([Packet.stats])
    body.append(big: UInt32(60)); body.append(big: UInt32(1))
    for stage in 0 ..< Packet.stages { for q in 0 ..< 3 { body.append(big: UInt16(stage * 10 + q)) } }
    #expect(body.count == Packet.statsSize)
    let stages = Streamer.stages(body)
    #expect(stages[0] == [0, 0.1, 0.2] && stages[4] == [4, 4.1, 4.2])
}

@Test func psnrOfLuma() {
    let a = Data(repeating: 100, count: 16)
    #expect(Fidelity.psnr(a, a, width: 4, height: 4, stride: 4) == 100)
    // Each sample off by 1: MSE 1, PSNR 20·log10(255) ≈ 48.13 dB.
    let b = Data(repeating: 101, count: 16)
    #expect(abs(Fidelity.psnr(a, b, width: 4, height: 4, stride: 4) - 48.13) < 0.01)
}
