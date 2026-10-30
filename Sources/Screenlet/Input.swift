import ApplicationServices
import CoreGraphics
import Foundation

/// Posts the tablet's fingers and pen as CGEvents on the display. macOS does
/// not accept injected touches, so a single finger drives the pointer.
final class Monitor {
    let display: CGDirectDisplayID
    let size: (Int, Int)
    private var finger: UInt8?      // the finger driving the pointer
    private(set) var buttons = Set<CGMouseButton>()
    private(set) var last = CGPoint.zero   // the pointer's last position, in stream pixels

    private let quiet: Bool                // for tests: records clicks without posting events
    private(set) var clicks: [CGMouseButton] = []

    init(display: CGDirectDisplayID, size: (Int, Int), quiet: Bool = false) {
        self.display = display
        self.size = size
        self.quiet = quiet
        if !quiet && !Monitor.accessibility(prompt: true) {
            log("macOS: no Accessibility for Screenlet: the tablet's touches do nothing until it is allowed")
        }
    }

    static func accessibility(prompt: Bool) -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): prompt] as CFDictionary)
    }

    /// Converts a point in stream pixels to global display points.
    static func toScreen(_ bounds: CGRect, _ size: (Int, Int), _ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: bounds.minX + x * bounds.width / Double(size.0), y: bounds.minY + y * bounds.height / Double(size.1))
    }

    func post(_ type: CGEventType, _ x: Double, _ y: Double, button: CGMouseButton = .left,
              fields: [(CGEventField, Double)] = []) {
        last = CGPoint(x: x, y: y)
        if quiet {
            if type == .leftMouseDown || type == .rightMouseDown { clicks.append(button) }
            return
        }
        let point = Monitor.toScreen(CGDisplayBounds(display), size, x, y)
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
        for (field, value) in fields {
            if field == .mouseEventSubtype { event.setIntegerValueField(field, value: Int64(value)) }
            else { event.setDoubleValueField(field, value: value) }
        }
        event.post(tap: .cghidEventTap)
    }

    func touchDown(_ slot: UInt8, _ x: Double, _ y: Double) {
        guard finger == nil else { return }
        finger = slot
        pointerMove(x, y)
        button(.left, pressed: true)
    }

    func touchMotion(_ slot: UInt8, _ x: Double, _ y: Double) {
        if slot == finger { post(.leftMouseDragged, x, y) }
    }

    func touchUp(_ slot: UInt8) {
        guard slot == finger else { return }
        finger = nil
        button(.left, pressed: false)
    }

    func pointerMove(_ x: Double, _ y: Double) { post(.mouseMoved, x, y) }

    func button(_ which: CGMouseButton, pressed: Bool) {
        let type: CGEventType = which == .right ? (pressed ? .rightMouseDown : .rightMouseUp)
                                                : (pressed ? .leftMouseDown : .leftMouseUp)
        if pressed { buttons.insert(which) } else { buttons.remove(which) }
        post(type, last.x, last.y, button: which)
    }

    func releaseAll() {
        buttons.forEach { button($0, pressed: false) }
    }
}

/// The S Pen as tablet events, with pressure and tilt for apps that read them
/// and plain pointer events for the rest. The barrel button is the right button.
/// No proximity events yet (kCGEventTabletProximity).
final class Pen {
    static let tip: UInt8 = 0x01, barrel: UInt8 = 0x02, inRange: UInt8 = 0x10
    static let axisMax = 32767.0, pressureMax = 4096.0
    private let monitor: Monitor
    private var bits: UInt8 = 0

    init(monitor: Monitor) { self.monitor = monitor }

    /// One pen report: bits, x, y and pressure (u16, little-endian), then tilt x and y (s8).
    func report(_ r: Data) {
        guard r.count >= 9 else { return }
        let b = r.startIndex
        func u16(_ at: Int) -> Double { Double(UInt16(r[b + at]) | UInt16(r[b + at + 1]) << 8) }
        let state = r[b], near = state & Pen.inRange != 0
        let x = u16(1) / Pen.axisMax * Double(monitor.size.0), y = u16(3) / Pen.axisMax * Double(monitor.size.1)
        let pressure = min(1.0, u16(5) / Pen.pressureMax)
        let tiltX = Double(Int8(bitPattern: r[b + 7])) / 90, tiltY = Double(Int8(bitPattern: r[b + 8])) / 90
        let tip = near && state & Pen.tip != 0, barrel = near && state & Pen.barrel != 0
        let wasTip = bits & Pen.tip != 0, wasBarrel = bits & Pen.barrel != 0
        let fields: [(CGEventField, Double)] = [(.mouseEventSubtype, 1),  // kCGEventMouseSubtypeTabletPoint
                                                (.tabletEventPointPressure, tip ? pressure : 0),
                                                (.tabletEventTiltX, tiltX), (.tabletEventTiltY, tiltY),
                                                (.mouseEventPressure, tip ? pressure : 0)]
        let type: CGEventType = tip && !wasTip ? .leftMouseDown : wasTip && !tip ? .leftMouseUp : tip ? .leftMouseDragged : .mouseMoved
        if near || wasTip { monitor.post(type, x, y, fields: fields) }
        if barrel != wasBarrel { monitor.button(.right, pressed: barrel) }
        bits = (near ? Pen.inRange : 0) | (tip ? Pen.tip : 0) | (barrel ? Pen.barrel : 0)
    }

    func close() {
        if bits & Pen.tip != 0 { monitor.button(.left, pressed: false) }
        if bits & Pen.barrel != 0 { monitor.button(.right, pressed: false) }
        bits = 0
    }
}

/// Turns the tablet's INPUT packets into pointer events. Each packet lists
/// what touches the screen, and the difference from the previous one tells
/// which fingers went down, moved or lifted. A two-finger tap is a right
/// click. Called only from the streamer's receiving thread.
final class Input {
    static let touchMax = 65535.0, maxFingers = 10, penSample = 9
    static let silence = 0.4       // seconds; the app repeats its state every 0.1 s
    static let secondFinger = 0.08, tapTime = 0.3, tapMove = 0.02

    let monitor: Monitor
    private let size: (Int, Int)
    private let clock: () -> Double
    private var down: [UInt8: (Double, Double)] = [:]
    private var pen: Pen?
    private var penLast: Data?   // the last report while the pen is in range
    private var heard: Double
    private var waiting: (since: Double, states: [[UInt8: (Double, Double)]])?

    init(monitor: Monitor, size: (Int, Int), clock: @escaping () -> Double = { Double(nowNanos()) / 1e9 }) {
        self.monitor = monitor
        self.size = size
        self.clock = clock
        heard = clock()
    }

    var busy: Bool { !down.isEmpty || waiting != nil || penLast != nil }

    /// Handles an INPUT packet. Returns false if it is malformed.
    func packet(_ body: Data) -> Bool {
        let b = body.startIndex
        guard body.count >= 3 else { return false }
        let count = Int(body[b + 1])
        guard count <= Input.maxFingers, body.count >= 2 + count * 5 + 1 else { return false }
        var fingers: [UInt8: (Double, Double)] = [:]
        for i in 0 ..< count {
            let at = 2 + i * 5
            let x = Double(body.big(UInt16.self, at: at + 1)), y = Double(body.big(UInt16.self, at: at + 3))
            fingers[body[b + at]] = (x / Input.touchMax * Double(size.0), y / Input.touchMax * Double(size.1))
        }
        let at = 2 + count * 5
        let samples = Int(body[b + at])
        guard body.count == at + 1 + samples * Input.penSample else { return false }
        heard = clock()
        touch(fingers)
        for i in 0 ..< samples {
            let from = b + at + 1 + i * Input.penSample
            penReport(body.subdata(in: from ..< from + Input.penSample))
        }
        return true
    }

    private func touch(_ fingers: [UInt8: (Double, Double)]) {
        if waiting == nil {
            if !down.isEmpty || fingers.isEmpty { return apply(fingers) }
            waiting = (clock(), [])
        }
        waiting!.states.append(fingers)
        decide()
    }

    private func decide() {
        guard let (since, states) = waiting else { return }
        let elapsed = clock() - since
        if !states.contains(where: { $0.count >= 2 }) {
            // One finger: press now if it lifted (a tap) or no second finger came in time.
            if states.last!.isEmpty || elapsed >= Input.secondFinger { replay() }
            return
        }
        var first: [UInt8: (Double, Double)] = [:]
        for state in states { for (f, at) in state where first[f] == nil { first[f] = at } }
        var moved = 0.0
        let width = Double(size.0), height = Double(size.1)
        for state in states {
            for (f, at) in state {
                let from = first[f]!
                moved = max(moved, abs(at.0 - from.0) / width + abs(at.1 - from.1) / height)
            }
        }
        if states.last!.isEmpty && elapsed < Input.tapTime && moved < Input.tapMove {
            waiting = nil
            let at = first.values.first!
            monitor.pointerMove(at.0, at.1)
            monitor.button(.right, pressed: true)
            monitor.button(.right, pressed: false)
        } else if moved >= Input.tapMove || elapsed >= Input.tapTime || states.last!.count > 2 || states.last!.isEmpty {
            replay()  // a pinch, two resting fingers or three: plain touches
        }
    }

    private func replay() {
        let states = waiting?.states ?? []
        waiting = nil
        states.forEach(apply)
    }

    private func apply(_ fingers: [UInt8: (Double, Double)]) {
        for f in down.keys where fingers[f] == nil {
            monitor.touchUp(f)
            down[f] = nil
        }
        for (f, at) in fingers {
            if let was = down[f] {
                if was != at { monitor.touchMotion(f, at.0, at.1) }
            } else {
                monitor.touchDown(f, at.0, at.1)
            }
            down[f] = at
        }
    }

    private func penReport(_ report: Data) {
        if pen == nil { pen = Pen(monitor: monitor) }
        pen!.report(report)
        penLast = report.first! & Pen.inRange != 0 ? report : nil
    }

    /// Called every few ms. Settles a finger waiting for a second one, and lifts
    /// everything when the tablet has gone quiet.
    func check() {
        if waiting != nil { decide() }
        guard clock() - heard >= Input.silence else { return }
        waiting = nil
        if !down.isEmpty { apply([:]) }
        if var last = penLast {
            last[last.startIndex] = 0
            penReport(last)
        }
    }

    func close() {
        waiting = nil
        apply([:])
        if var last = penLast {
            last[last.startIndex] = 0
            penReport(last)
        }
        pen?.close()
        monitor.releaseAll()
    }
}
