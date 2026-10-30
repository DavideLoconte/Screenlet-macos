import CryptoKit
import Foundation
import Testing
@testable import Screenlet

// The same values Screenlet Companion computes.

@Test func pairingCodeAndCommitmentMatchTheOtherApps() {
    let code = Companion.pairingCode(Data("cert-b".utf8), Data("cert-a".utf8), ours: Data(count: 16),
                                     theirs: Data(repeating: 1, count: 16))
    #expect(code == "923178")
    #expect(Companion.commitment(nonce: Data(repeating: 2, count: 16), appCert: Data("app".utf8), pcCert: Data("pc".utf8))
            == "b37ff558d1ff9eef7e1089261643ce3f606d564c8520a7420640a5bad2604014")
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

@Test func channelOpensOnlyFreshPacketsFromTheApp() throws {
    let key = SymmetricKey(size: .bits256)
    let channel = try Channel(key: key.withUnsafeBytes { Data($0) }, cable: nil)
    defer { channel.close() }
    let first = Channel.seal(Data([Packet.keyframe]), key: key, direction: Packet.fromApp, count: 0)
    channel.received(first)
    #expect(channel.receive(timeout: 0.1) == Data([Packet.keyframe]))
    channel.received(first)                                                   // replayed
    var tampered = Channel.seal(Data([Packet.keyframe]), key: key, direction: Packet.fromApp, count: 1)
    tampered[Packet.nonceSize] ^= 1
    channel.received(tampered)                                                // not authentic
    channel.received(Channel.seal(Data([1]), key: key, direction: Packet.fromPC, count: 2))  // our own direction
    channel.received(Channel.seal(Data([1]), key: SymmetricKey(size: .bits256), direction: Packet.fromApp, count: 3))
    #expect(channel.receive(timeout: 0.1) == nil)
}

@Test func lengthPrefixedToStartCodes() {
    let avcc = Data([0, 0, 0, 2, 0x65, 1, 0, 0, 0, 1, 0x41])
    #expect(Video.convert(avcc, lengthSize: 4, into: Data([0, 0, 0, 1, 0x67]))
            == Data([0, 0, 0, 1, 0x67, 0, 0, 0, 1, 0x65, 1, 0, 0, 0, 1, 0x41]))
}

@Test func twoFingersTappedAreTheRightButton() {
    final class Clock { var now = 0.0 }
    let clock = Clock()
    let input = Input(monitor: Monitor(display: 0, size: (1000, 1000), quiet: true), size: (1000, 1000), clock: { clock.now })
    func packet(_ fingers: [(UInt8, UInt16, UInt16)]) -> Data {
        var body = Data([Packet.input, UInt8(fingers.count)])
        for (id, x, y) in fingers { body.append(id); body.append(big: x); body.append(big: y) }
        body.append(0)
        return body
    }
    #expect(input.packet(packet([(1, 100, 100)])))
    clock.now = 0.02
    #expect(input.packet(packet([(1, 100, 100), (2, 200, 200)])))
    clock.now = 0.1
    #expect(input.packet(packet([])))
    #expect(input.monitor.clicks == [.right])
    #expect(!input.packet(Data([Packet.input, 11])))  // more fingers than a hand
}
