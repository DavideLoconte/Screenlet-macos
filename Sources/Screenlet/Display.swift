import CryptoKit
import Foundation
import Native
import Network

/// The display stream (PROTOCOL.md, "The display"). Each encoded frame is
/// split into packets sealed with AES-GCM, using a key sent over the paired
/// TLS link, and sent as soon as the encoder produces it.
enum Packet {
    static let video: UInt8 = 1, keyframe: UInt8 = 2, ping: UInt8 = 3, pong: UInt8 = 4, stats: UInt8 = 5, input: UInt8 = 6
    static let fromPC: UInt32 = 1, fromApp: UInt32 = 2
    static let nonceSize = 12, tagSize = 16, videoHeader = 18
    /// Video bytes per packet, so that with header, nonce and tag it fits one Ethernet frame.
    static let payload = 1472 - videoHeader - nonceSize - tagSize
    static let stages = 5
    static let statsSize = 1 + 4 + 4 + stages * 3 * 2
}

extension Data {
    mutating func append<T: FixedWidthInteger>(big value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    func big<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        var value: T = 0
        for i in 0 ..< MemoryLayout<T>.size { value = value << 8 | T(self[startIndex + offset + i]) }
        return value
    }
}

/// Display sizes for a tablet, at its proportions, largest first.
enum Sizes {
    static let widths = [3840, 2560, 2304, 1920, 1680, 1440, 1280]
    static let reference = 1920 * 1200   // the size the bitrates are set for
    static let hidpiWidth = 2560         // from this width, the display is HiDPI

    static func all(_ screen: (Int, Int)) -> [(Int, Int)] {
        let width = max(screen.0, screen.1), height = min(screen.0, screen.1)
        var found = [(width, height)]
        let ratio = Double(width) / Double(height)
        for w in widths where w < width {
            let h = Int((Double(w) * Double(height) / Double(width) / 2).rounded()) * 2
            if abs(Double(w) / Double(h) - ratio) < 0.005 * ratio { found.append((w, h)) }
        }
        return found
    }

    /// Samsung tablets by the native resolution they report (landscape): their
    /// names, and the width Automatic uses over Wi-Fi, where the densest
    /// screens would need more bandwidth than most networks give.
    static let tablets: [[Int]: (models: String, wifiWidth: Int)] = [
        [1340, 800]: ("Galaxy Tab A7 Lite, Tab A9", 1340),
        [1920, 1200]: ("Galaxy Tab A8, Tab A9+", 1920),
        [2000, 1200]: ("Galaxy Tab S6 Lite, Tab A7", 2000),
        [2304, 1440]: ("Galaxy Tab S9 FE, Tab S10 FE", 1920),
        [2560, 1600]: ("Galaxy Tab S6, S7, S7 FE, S8, S9, S9 FE+, S11", 1920),
        [2800, 1752]: ("Galaxy Tab S7+, S8+, S9+, S10+", 1920),
        [2960, 1848]: ("Galaxy Tab S8 Ultra, S9 Ultra, S10 Ultra, S11 Ultra", 1920),
    ]

    static func models(_ screen: (Int, Int)) -> String? {
        tablets[[max(screen.0, screen.1), min(screen.0, screen.1)]]?.models
    }

    /// Native over the cable. Over Wi-Fi, the width the table gives for this
    /// tablet, or the size closest to 1920x1200 for one it does not know.
    static func auto(_ screen: (Int, Int), wifi: Bool) -> (Int, Int) {
        let sizes = all(screen)
        guard wifi else { return sizes[0] }
        if let known = tablets[[sizes[0].0, sizes[0].1]], let size = sizes.first(where: { $0.0 <= known.wifiWidth }) {
            return size
        }
        return sizes.min { abs($0.0 * $0.1 - reference) < abs($1.0 * $1.1 - reference) }!
    }

    static func scale(_ size: (Int, Int)) -> Int { size.0 >= hidpiWidth ? 2 : 1 }

    /// The size the setting asks for on this tablet, or the automatic size if
    /// the setting does not fit its proportions.
    static func choose(_ resolution: String, _ screen: (Int, Int), wifi: Bool) -> (Int, Int) {
        let sizes = all(screen)
        if resolution == "tablet" { return sizes[0] }
        let asked = resolution.split(separator: "x").compactMap { Int($0) }
        return sizes.first { asked == [$0.0, $0.1] } ?? auto(screen, wifi: wifi)
    }

    /// A display's size in pixels.
    static func pixels(_ display: CGDirectDisplayID) -> (Int, Int) {
        guard let mode = CGDisplayCopyDisplayMode(display) else { return (CGDisplayPixelsWide(display), CGDisplayPixelsHigh(display)) }
        return (mode.pixelWidth, mode.pixelHeight)
    }

    /// size scaled down to fit screen in either orientation, keeping proportions
    /// and even dimensions. Used for a mirrored display, which the app letterboxes.
    static func fit(_ size: (Int, Int), into screen: (Int, Int)) -> (Int, Int) {
        let tablet = size.0 >= size.1 ? (max(screen.0, screen.1), min(screen.0, screen.1))
                                       : (min(screen.0, screen.1), max(screen.0, screen.1))
        let scale = min(1.0, Double(tablet.0) / Double(size.0), Double(tablet.1) / Double(size.1))
        return (Int(Double(size.0) * scale / 2) * 2, Int(Double(size.1) * scale / 2) * 2)
    }

    static func bitrate(_ kbps: Int, _ size: (Int, Int)) -> Int {
        Int(Double(kbps) * max(1.0, Double(size.0 * size.1) / Double(reference)))
    }
}

/// The session's sealed packets in both directions, over UDP or the cable.
final class Channel {
    private let key: SymmetricKey
    private let lock = NSLock()
    private var sent: UInt64 = 0
    private var replay = Replay()
    private var socket: Int32 = -1
    private var app = sockaddr_in()
    private let cable: Cable?
    private(set) var port: UInt16 = 9   // ours, sent to the app (unused over the cable)
    private var inbox: [Data] = []
    private let arrived = DispatchSemaphore(value: 0)
    private var open = true

    init(key: Data, cable: Cable?) throws {
        self.key = SymmetricKey(data: key)
        self.cable = cable
        if let cable {
            cable.onDatagram = { [weak self] in self?.received($0) }
            return
        }
        socket = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        // Room for a keyframe at the highest bitrate, not much more: a deeper
        // queue only makes the next frames later when the network slows.
        var size: Int32 = 1 << 20
        setsockopt(socket, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                                  sin_port: 0, sin_addr: in_addr(s_addr: INADDR_ANY), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, length) == 0 && getsockname(socket, $0, &length) == 0 }
        }
        guard bound else { throw Failure("no UDP port for the display") }
        port = UInt16(bigEndian: address.sin_port)
        Thread.detachNewThread { [self] in receiving() }
    }

    /// Sets the app's address and the port it announced.
    func app(host: String, port: UInt16) {
        app = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                          sin_port: port.bigEndian, sin_addr: in_addr(s_addr: inet_addr(host)), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
    }

    private func seal(_ body: Data) -> Data {
        lock.lock()
        let count = sent
        sent += 1
        lock.unlock()
        return Channel.seal(body, key: key, direction: Packet.fromPC, count: count)
    }

    static func seal<Body: DataProtocol>(_ body: Body, key: SymmetricKey, direction: UInt32, count: UInt64) -> Data {
        var nonce = Data(capacity: Packet.nonceSize)
        nonce.append(big: direction)
        nonce.append(big: count)
        // CryptoKit's combined form is the packet: nonce, ciphertext, tag.
        return try! AES.GCM.seal(body, using: key, nonce: try! AES.GCM.Nonce(data: nonce)).combined!
    }

    /// Seals and sends bodies together, so a frame's packets take one USB write.
    func send(_ bodies: [Data]) {
        let packets = bodies.map(seal)
        if let cable {
            try? cable.send(datagrams: packets)
            return
        }
        for packet in packets {
            _ = packet.withUnsafeBytes { raw in
                withUnsafePointer(to: &app) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(socket, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
    }

    private func receiving() {
        var buffer = [UInt8](repeating: 0, count: 2048)
        var from = sockaddr_in()
        while open {
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(socket, &buffer, buffer.count, 0, $0, &length) }
            }
            if n < 0 { return }
            if from.sin_addr.s_addr == app.sin_addr.s_addr { received(Data(buffer[0 ..< n])) }
        }
    }

    func received(_ packet: Data) {
        guard packet.count >= Packet.nonceSize + Packet.tagSize + 1,
              packet.big(UInt32.self, at: 0) == Packet.fromApp else { return }
        let count = packet.big(UInt64.self, at: 4)
        lock.lock()
        let fresh = replay.fresh(count)
        lock.unlock()
        guard fresh, let nonce = try? AES.GCM.Nonce(data: packet.prefix(Packet.nonceSize)),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: packet.dropFirst(Packet.nonceSize).dropLast(Packet.tagSize),
                                               tag: packet.suffix(Packet.tagSize)),
              let body = try? AES.GCM.open(box, using: key) else { return }  // not sealed with this session's key
        lock.lock()
        guard replay.fresh(count) else { lock.unlock(); return }
        replay.accept(count)
        inbox.append(body)
        lock.unlock()
        arrived.signal()
    }

    /// The next body from the app, or nil after timeout.
    func receive(timeout: TimeInterval) -> Data? {
        guard arrived.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return inbox.isEmpty ? nil : inbox.removeFirst()
    }

    func close() {
        open = false
        cable?.onDatagram = nil
        if socket >= 0 { Darwin.close(socket) }
    }
}

/// The counts accepted from the app: the highest and a window of 64 below
/// it, so a packet Wi-Fi delivered late is taken once, a replay never.
struct Replay {
    private var highest: UInt64?
    private var window: UInt64 = 0  // bit i: highest - i was accepted

    func fresh(_ count: UInt64) -> Bool {
        guard let highest else { return true }
        if count > highest { return true }
        let behind = highest - count
        return behind < 64 && window & (1 << behind) == 0
    }

    mutating func accept(_ count: UInt64) {
        guard let top = highest, count <= top else {
            let shift = highest.map { count - $0 } ?? 64
            window = shift >= 64 ? 1 : window << shift | 1
            highest = count
            return
        }
        window |= 1 << (top - count)
    }
}

/// Sends the encoded display to the app and handles its input and reports.
final class Streamer {
    static let minKeyframeGap: TimeInterval = 0.25  // the app keeps asking until one arrives
    static let idleWait: TimeInterval = 0.25
    static var statsEvery = 30  // log one report in this many, plus any with losses

    private let channel: Channel
    private var video: Video!
    private let input: Input?
    private var frame: UInt32 = 0
    private var lastKeyframe = Date.distantPast
    private var encoded: [Double] = []   // ms from capture to encoded since the last report
    private var sent: [Double] = []      // ms from capture to sent
    /// Packets go out from here, never from VideoToolbox's thread: a slow USB
    /// write must not hold the encoder's next frame.
    private let sender = DispatchQueue(label: "screenlet.send", qos: .userInteractive)
    private var bytes = 0                // of video since the last report
    // The bitrate adapts like a TCP window: down a third when frames arrive
    // late or are lost, up a tenth while they arrive on time, capped at the
    // priority's bitrate.
    static let minKbps = 2000
    static let late = 90.0        // a median above this many ms is late, whatever the link's best
    private let target: Int
    private var bitrate: Int
    private var medians: [Double] = []   // capture to decoded, from recent reports
    private var calm = 0                 // reports on time in a row
    private var holding = 0              // reports to wait after lowering, while queues drain
    private var reportedAt = nowNanos()
    private let lock = NSLock()
    private var running = true
    private var shown = true
    private var reports = 0
    var onPaused: ((Bool) -> Void)?

    init(channel: Channel, display: CGDirectDisplayID, size: (Int, Int), fps: Int, bitrate: Int, vbvFrames: Double,
         hevc: Bool, wifi: Bool, input: Input?, onError: @escaping (String) -> Void) {
        self.channel = channel
        self.input = input
        target = bitrate
        // Wi-Fi starts at half and ramps up, so the start does not fill queues.
        let bitrate = wifi ? max(Streamer.minKbps, bitrate / 2) : bitrate
        self.bitrate = bitrate
        video = Video(display: display, size: size, fps: fps, bitrate: bitrate, vbvFrames: vbvFrames, hevc: hevc,
                      onFrame: { [weak self] in self?.send($0, keyframe: $1, captured: $2) }, onError: onError)
        log("app display: \(size.0)x\(size.1)@\(fps) \(hevc ? "HEVC" : "H.264") \(bitrate) kbit/s")
    }

    func start() {
        video.start()
        Thread.detachNewThread { [self] in listen() }
    }

    func stop() {
        running = false
        input?.close()
        video.stop()
    }

    /// Called on the encoder's thread with one Annex B frame: on its way at once.
    private func send(_ data: Data, keyframe: Bool, captured: Int64) {
        let encodedAt = nowNanos()
        sender.async { [self] in
            frame &+= 1
            let count = (data.count + Packet.payload - 1) / Packet.payload
            var bodies: [Data] = []
            bodies.reserveCapacity(count)
            for index in 0 ..< count {
                var body = Data(capacity: Packet.videoHeader + Packet.payload)
                body.append(Packet.video)
                body.append(keyframe ? 1 : 0)
                body.append(big: frame)
                body.append(big: UInt16(index))
                body.append(big: UInt16(count))
                body.append(big: captured)
                let from = data.startIndex + index * Packet.payload
                body.append(data[from ..< min(from + Packet.payload, data.endIndex)])
                bodies.append(body)
            }
            channel.send(bodies)
            let now = nowNanos()
            lock.lock()
            encoded.append(Double(encodedAt - captured) / 1e6)
            sent.append(Double(now - captured) / 1e6)
            bytes += data.count
            lock.unlock()
        }
    }

    private func listen() {
        while running {
            // Input.check() every 5 ms while something is touching (a finger
            // held still is pressed after a moment), rarely otherwise.
            let busy = input?.busy ?? false
            let body = channel.receive(timeout: busy ? 0.005 : Streamer.idleWait)
            input?.check()
            guard let body, let kind = body.first else { continue }
            switch kind {
            case Packet.input:
                if input?.packet(body) == false { log("app display: a malformed input packet") }
            case Packet.keyframe:
                log("app display: the app asks for a keyframe")
                forceKeyframe()
            case Packet.ping where body.count == 9 || body.count == 10:
                var pong = Data([Packet.pong])
                pong.append(big: body.big(Int64.self, at: 1))
                pong.append(big: nowNanos())
                sender.async { [channel] in channel.send([pong]) }
                if body.count == 10 { visible(body[body.startIndex + 9] != 0) }
            case Packet.stats where body.count == Packet.statsSize:
                stats(body)
            default:
                break
            }
        }
    }

    /// The app's measures (PROTOCOL.md §3.5), five stages × median, 90th
    /// percentile and highest, with this Mac's own: capture to encoded, to sent.
    static func stages(_ body: Data) -> [[Double]] {
        (0 ..< Packet.stages).map { stage in (0 ..< 3).map { Double(body.big(UInt16.self, at: 9 + 6 * stage + 2 * $0)) / 10 } }
    }

    private func stats(_ body: Data) {
        let shown = body.big(UInt32.self, at: 1), lost = body.big(UInt32.self, at: 5)
        let app = Streamer.stages(body)
        lock.lock()
        let encodedMs = encoded.sorted(), sentMs = sent.sorted()
        encoded.removeAll()
        sent.removeAll()
        let now = nowNanos()
        let kbps = Double(bytes) * 8e6 / Double(max(1, now - reportedAt))
        bytes = 0
        reportedAt = now
        lock.unlock()
        let fidelity = video.fidelity?.take()
        if shown > 0 { adapt(median: app[0][0], lost: lost) }
        reports += 1
        if lost > 0 || reports % Streamer.statsEvery == 1 {
            func median(_ v: [Double]) -> String { v.isEmpty ? "?" : String(format: "%.1f", v[v.count / 2]) }
            // Where the time goes, stage by stage (medians, ms).
            log(String(format: "app display: %d fps, lost %d; capture to decoded %.1f ms (90%%: %.1f, max %.1f); "
                       + "stages: encoded %@, sent %@, first packet %.1f, spread %.1f, decoder wait %.1f, decode %.1f; %.0f kbit/s",
                       shown, lost, app[0][0], app[0][1], app[0][2], median(encodedMs), median(sentMs),
                       app[1][0], app[2][0], app[3][0], app[4][0], kbps)
                + " (at most \(bitrate))"
                + (fidelity.map { String(format: "; PSNR %.1f dB (lowest %.1f)", $0.0, $0.1) } ?? ""))
        }
    }

    /// Adjusts the bitrate after a report. On time means close to the best delay
    /// of recent reports, which absorbs the link's base latency and clock offset.
    private func adapt(median: Double, lost: UInt32) {
        medians.append(median)
        if medians.count > 20 { medians.removeFirst() }
        let best = medians.min()!
        if holding > 0 {
            holding -= 1
        } else if median > best + 60 || median > Streamer.late || (lost > 0 && median > best + 25) {
            // Queueing raises the median. An occasional late frame (Wi-Fi jitter,
            // the 90th percentile) does not, and is not worth lowering the bitrate for.
            calm = 0
            holding = 2
            let next = max(Streamer.minKbps, bitrate * 2 / 3)
            if next < bitrate {
                bitrate = next
                video.rate(next)
                log("app display: frames late (\(Int(median)) ms, at best \(Int(best))): \(next) kbit/s")
            }
        } else if median < best + 30 {
            calm += 1
            if calm >= 2 && bitrate < target {
                calm = 0
                bitrate = min(target, bitrate * 11 / 10)
                video.rate(bitrate)
            }
        } else {
            calm = 0
        }
    }

    /// Whether the app shows the desktop. Nothing is captured or encoded while it does not.
    private func visible(_ now: Bool) {
        guard now != shown else { return }
        shown = now
        if !now { input?.close() }
        video.pause(!now)
        if now { forceKeyframe() }
        onPaused?(!now)
    }

    private func forceKeyframe() {
        guard Date().timeIntervalSince(lastKeyframe) >= Streamer.minKeyframeGap else { return }
        lastKeyframe = Date()
        video.keyframe()
    }
}

/// A display session with a paired tablet: the display, its stream and the
/// tablet's touch and pen input, for as long as the app shows it. Callbacks
/// run on the main thread.
final class DisplaySession {
    /// How the desktop reaches the tablet: a new display (resolution "auto"
    /// as Sizes.auto chooses, "tablet" for native, or "WxH"), or one of
    /// the Mac's displays mirrored.
    struct Mode {
        var resolution = "auto"
        var fps = 0                  // 0: the tablet's refresh rate, up to maxFps
        var mirror: CGDirectDisplayID?
        var hevc = true              // requested; the app answers whether it decodes it in hardware
        var priority = "balanced"    // a Priority name
    }

    private let endpoints: [NWEndpoint]
    private let expect: String?
    private let cable: Cable?
    private var mode: Mode
    private var link: Link?
    private var channel: Channel?
    private var display: ScreenletVirtualDisplay?
    private var streamer: Streamer?
    private var started = false
    private var stopped = false
    private let stopping = DispatchSemaphore(value: 0)
    private(set) var displayID: CGDirectDisplayID?   // the display shown on the tablet
    var onStarted: ((Int, Int) -> Void)?
    var onEnded: ((Error?) -> Void)?
    var onPaused: ((Bool) -> Void)?

    init(endpoints: [NWEndpoint], expect: String?, cable: Cable?, mode: Mode) {
        self.endpoints = endpoints
        self.expect = expect
        self.cable = cable
        self.mode = mode
    }

    func start() {
        Thread.detachNewThread { [self] in run() }
    }

    static let maxFps = 120

    /// The capture rate for a panel of refresh Hz: 60 when it does not say.
    static func fps(_ refresh: Double?) -> Int {
        guard let refresh, refresh >= 30 else { return 60 }
        return min(maxFps, Int(refresh.rounded()))
    }

    /// Ends the session now. Call on the main thread; the link's thread tells the app.
    func stop() {
        guard !stopped else { return }
        stopped = true
        stopping.signal()
        teardown()
    }

    private func run() {
        var failure: Error?
        do {
            let (link, _, _) = try Companion.connect(endpoints, expect: expect)
            self.link = link
            defer { link.close() }
            if stopped { return }
            var key = Data(count: 32)
            _ = key.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
            let channel = try Channel(key: key, cable: cable)
            self.channel = channel
            try link.send(["type": "display", "key": Companion.hex(key), "port": Int(channel.port),
                           "codec": mode.hevc ? "hevc" : "avc"])
            let reply = try link.receive()
            if reply["type"] as? String == "refused" { throw Refused(reason: "\(reply["reason"] ?? "")") }
            guard reply["type"] as? String == "display-ready", let port = reply["port"] as? Int,
                  let width = reply["width"] as? Int, let height = reply["height"] as? Int else {
                throw Failure("the app answered \(reply["type"] ?? "nothing")")
            }
            if cable == nil {
                guard let host = link.remoteHost else { throw Failure("no address for the tablet") }
                channel.app(host: host, port: UInt16(port))
            }
            log("app display: the tablet shows \(width)x\(height) at \(reply["refresh"] ?? "?") Hz")
            UserDefaults.standard.set([width, height], forKey: "tabletScreen")  // for the resolutions in the window
            // An app that names no codec decodes H.264 only.
            if mode.hevc && reply["codec"] as? String != "hevc" { log("app display: the tablet takes H.264 only") }
            mode.hevc = reply["codec"] as? String == "hevc"
            let size = mode.mirror.map { Sizes.fit(Sizes.pixels($0), into: (width, height)) }
                ?? Sizes.choose(mode.resolution, (width, height), wifi: cable == nil)
            // As fast as the tablet's panel refreshes: a frame waits less for
            // the next capture, and the app shows it at the next vsync.
            if mode.fps == 0 { mode.fps = DisplaySession.fps((reply["refresh"] as? NSNumber)?.doubleValue) }
            DispatchQueue.main.async { [self] in open(size) }
            try hold(link)
        } catch {
            failure = error
        }
        if !stopped {
            DispatchQueue.main.async { [self] in ended(failure) }
        }
    }

    /// Pings for as long as the session lasts, since the app drops a silent Mac,
    /// and ends it when the app hangs up or stop() is called.
    private func hold(_ link: Link) throws {
        var gone: Error?
        let got = DispatchSemaphore(value: 0)
        func next() {
            link.receiveNext { result in
                switch result {
                case .success: next()   // no reply expected
                case .failure(let e): gone = e; got.signal()
                }
            }
        }
        next()
        while !stopped && gone == nil {
            if stopping.wait(timeout: .now() + 5) == .success { break }
            if gone == nil { try link.send(["type": "ping"]) }
        }
        if let gone, !stopped { throw gone }
        try? link.send(["type": "stop"])
    }

    // -- the main thread ---------------------------------------------------------
    private func open(_ size: (Int, Int)) {
        guard !stopped else { return }
        let id: CGDirectDisplayID
        if let mirror = mode.mirror {
            id = mirror
            log("macOS: mirroring display \(mirror) at \(size.0)x\(size.1)")
        } else {
            let scale = Sizes.scale(size)
            guard let display = ScreenletVirtualDisplay(pixels: CGSize(width: size.0, height: size.1),
                                                 points: CGSize(width: size.0 / scale, height: size.1 / scale),
                                                 refreshRate: Double(mode.fps),
                                                 name: "Screenlet", vendor: 0x5C4E, product: 0x5350) else {
                return ended(Failure("macOS did not make the virtual display"))
            }
            self.display = display
            id = display.displayID
            log("macOS: virtual display \(id), \(size.0 / scale)x\(size.1 / scale) points at \(mode.fps) Hz")
        }
        displayID = id
        let monitor = Monitor(display: id, size: size)
        let priority = Priority.settings(mode.priority)
        let streamer = Streamer(channel: channel!, display: id, size: size, fps: mode.fps,
                                bitrate: Sizes.bitrate(priority.kbps, size), vbvFrames: priority.vbvFrames, hevc: mode.hevc,
                                wifi: cable == nil,
                                input: Input(monitor: monitor, size: size),
                                onError: { [weak self] message in later { self?.ended(Failure(message)) } })
        streamer.onPaused = { [weak self] paused in later { self?.onPaused?(paused) } }
        self.streamer = streamer
        streamer.start()
        started = true
        onStarted?(size.0, size.1)
    }

    private func ended(_ error: Error?) {
        guard !stopped else { return }
        stopped = true
        stopping.signal()
        teardown()
        onEnded?(error)
    }

    private func teardown() {
        streamer?.stop()
        streamer = nil
        if display != nil { log("macOS: virtual display closed") }
        display = nil   // releasing it removes the display
        channel?.close()
    }
}
