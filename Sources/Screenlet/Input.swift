import ApplicationServices
import CoreGraphics
import Foundation

/// Posts the tablet's fingers and pen as CGEvents on the display. macOS does
/// not accept injected touches, so a finger drives the pointer and two scroll.
final class Monitor {
    let display: CGDirectDisplayID
    let size: (Int, Int)
    private(set) var buttons = Set<CGMouseButton>()
    private(set) var last = CGPoint.zero   // the pointer's last position, in stream pixels

    private let quiet: Bool                // for tests: records what it would post
    private(set) var posted: [String] = []

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

    private static let integerFields: Set<CGEventField> = [.mouseEventSubtype, .tabletEventDeviceID]

    func post(_ type: CGEventType, _ x: Double, _ y: Double, button: CGMouseButton = .left,
              fields: [(CGEventField, Double)] = []) {
        last = CGPoint(x: x, y: y)
        if quiet { return record("\(type.rawValue)") }
        let point = Monitor.toScreen(CGDisplayBounds(display), size, x, y)
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
        for (field, value) in fields {
            if Monitor.integerFields.contains(field) { event.setIntegerValueField(field, value: Int64(value)) }
            else { event.setDoubleValueField(field, value: value) }
        }
        event.post(tap: .cghidEventTap)
    }

    private func record(_ what: String) {
        posted.append(what)
    }

    var clicks: [String] { posted.filter { $0 == "\(CGEventType.leftMouseDown.rawValue)" || $0 == "\(CGEventType.rightMouseDown.rawValue)" } }

    func pointerMove(_ x: Double, _ y: Double) { post(buttons.contains(.left) ? .leftMouseDragged : .mouseMoved, x, y) }

    func button(_ which: CGMouseButton, pressed: Bool) {
        let type: CGEventType = which == .right ? (pressed ? .rightMouseDown : .rightMouseUp)
                                                : (pressed ? .leftMouseDown : .leftMouseUp)
        if pressed { buttons.insert(which) } else { buttons.remove(which) }
        post(type, last.x, last.y, button: which)
    }

    enum Phase: Int64 { case began = 1, changed = 2, ended = 4 }

    /// A continuous scroll by dx, dy pixels, as a trackpad's: the content follows the fingers.
    func scroll(_ dx: Double, _ dy: Double, _ phase: Phase) {
        if quiet { return record("scroll \(phase)") }
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0) else { return }
        event.location = Monitor.toScreen(CGDisplayBounds(display), size, last.x, last.y)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase.rawValue)
        event.post(tap: .cghidEventTap)
    }

    /// The pen coming near (or going): apps that read tablets learn it is a pen, or the eraser.
    func proximity(_ entering: Bool, eraser: Bool) {
        if quiet { return record(entering ? "near" : "away") }
        guard let event = CGEvent(source: nil) else { return }
        event.type = .tabletProximity
        event.setIntegerValueField(.tabletProximityEventEnterProximity, value: entering ? 1 : 0)
        event.setIntegerValueField(.tabletProximityEventPointerType, value: eraser ? 3 : 1)  // NX_TABLET_POINTER_PEN, _ERASER
        event.setIntegerValueField(.tabletProximityEventDeviceID, value: Pen.deviceID)
        event.setIntegerValueField(.tabletProximityEventSystemTabletID, value: Pen.deviceID)
        event.post(tap: .cghidEventTap)
    }

    func releaseAll() {
        buttons.forEach { button($0, pressed: false) }
    }
}

/// The S Pen as tablet events, with pressure and tilt for apps that read them
/// and plain pointer events for the rest. The barrel button is the right button.
final class Pen {
    static let tip: UInt8 = 0x01, barrel: UInt8 = 0x02, eraser: UInt8 = 0x08, inRange: UInt8 = 0x10
    static let axisMax = 32767.0, pressureMax = 4096.0
    static let deviceID: Int64 = 0x5C4E
    private let monitor: Monitor
    private var bits: UInt8 = 0

    init(monitor: Monitor) { self.monitor = monitor }

    /// One pen report: bits, x, y and pressure (u16, little-endian), then tilt x and y (s8).
    func report(_ r: UnsafeRawBufferPointer) {
        guard r.count >= 9 else { return }
        func u16(_ at: Int) -> Double { Double(UInt16(r[at]) | UInt16(r[at + 1]) << 8) }
        let state = r[0], near = state & Pen.inRange != 0, wasNear = bits & Pen.inRange != 0
        let x = u16(1) / Pen.axisMax * Double(monitor.size.0), y = u16(3) / Pen.axisMax * Double(monitor.size.1)
        let pressure = min(1.0, u16(5) / Pen.pressureMax)
        let tiltX = Double(Int8(bitPattern: r[7])) / 90, tiltY = Double(Int8(bitPattern: r[8])) / 90
        let tip = near && state & Pen.tip != 0, barrel = near && state & Pen.barrel != 0
        let wasTip = bits & Pen.tip != 0, wasBarrel = bits & Pen.barrel != 0
        if near && !wasNear { monitor.proximity(true, eraser: state & Pen.eraser != 0) }
        let fields: [(CGEventField, Double)] = [(.mouseEventSubtype, 1),  // kCGEventMouseSubtypeTabletPoint
                                                (.tabletEventDeviceID, Double(Pen.deviceID)),
                                                (.tabletEventPointPressure, tip ? pressure : 0),
                                                (.tabletEventTiltX, tiltX), (.tabletEventTiltY, tiltY),
                                                (.mouseEventPressure, tip ? pressure : 0)]
        let type: CGEventType = tip && !wasTip ? .leftMouseDown : wasTip && !tip ? .leftMouseUp : tip ? .leftMouseDragged : .mouseMoved
        if near || wasTip { monitor.post(type, x, y, fields: fields) }
        if barrel != wasBarrel { monitor.button(.right, pressed: barrel) }
        if !near && wasNear { monitor.proximity(false, eraser: bits & Pen.eraser != 0) }
        bits = (near ? Pen.inRange : 0) | (tip ? Pen.tip : 0) | (barrel ? Pen.barrel : 0) | (near ? state & Pen.eraser : 0)
    }

    var near: Bool { bits & Pen.inRange != 0 }

    func close() {
        if bits & Pen.tip != 0 { monitor.button(.left, pressed: false) }
        if bits & Pen.barrel != 0 { monitor.button(.right, pressed: false) }
        if near { monitor.proximity(false, eraser: bits & Pen.eraser != 0) }
        bits = 0
    }
}

/// Turns the tablet's INPUT packets into pointer events, with no wait on a
/// finger: it moves the pointer the moment it lands, presses the button the
/// moment it moves (a drag), when it lifts (a click) or after holding still
/// a moment. Two fingers scroll, and a two-finger tap is a right click.
/// Called only from the streamer's receiving thread.
final class Input {
    static let touchMax = 65535.0, maxFingers = 10, penSample = 9
    static let silence = 0.4       // seconds; the app repeats its state every 0.1 s
    static let hold = 0.12         // seconds still before a finger presses
    static let slop = 0.006        // of the screen, moved before a finger drags
    static let tapTime = 0.3, tapMove = 0.02

    let monitor: Monitor
    private let size: (Int, Int)
    private let clock: () -> Double
    private var heard: Double
    private var pen: Pen?

    private enum Touch {
        case idle
        case one(id: UInt8, at: (Double, Double), since: Double, pressed: Bool)
        case two(since: Double, middle: (Double, Double), first: (Double, Double), moved: Bool, scrolling: Bool)
        case lifting  // after a gesture, until every finger is off
    }
    private var touch = Touch.idle

    init(monitor: Monitor, size: (Int, Int), clock: @escaping () -> Double = { Double(nowNanos()) / 1e9 }) {
        self.monitor = monitor
        self.size = size
        self.clock = clock
        heard = clock()
    }

    var busy: Bool {
        if case .idle = touch { return pen?.near ?? false }
        return true
    }

    /// Handles an INPUT packet. Returns false if it is malformed.
    func packet(_ body: Data) -> Bool {
        body.withUnsafeBytes { b in
            guard b.count >= 3 else { return false }
            let count = Int(b[1])
            guard count <= Input.maxFingers, b.count >= 2 + count * 5 + 1 else { return false }
            var fingers: [(UInt8, (Double, Double))] = []
            for i in 0 ..< count {
                let at = 2 + i * 5
                let x = Double(UInt16(b[at + 1]) << 8 | UInt16(b[at + 2])), y = Double(UInt16(b[at + 3]) << 8 | UInt16(b[at + 4]))
                fingers.append((b[at], (x / Input.touchMax * Double(size.0), y / Input.touchMax * Double(size.1))))
            }
            let at = 2 + count * 5
            let samples = Int(b[at])
            guard b.count == at + 1 + samples * Input.penSample else { return false }
            heard = clock()
            fingersNow(fingers)
            for i in 0 ..< samples {
                if pen == nil { pen = Pen(monitor: monitor) }
                let from = at + 1 + i * Input.penSample
                pen!.report(UnsafeRawBufferPointer(rebasing: b[from ..< from + Input.penSample]))
            }
            return true
        }
    }

    private func moved(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
        abs(a.0 - b.0) / Double(size.0) + abs(a.1 - b.1) / Double(size.1)
    }

    private func middle(_ fingers: [(UInt8, (Double, Double))]) -> (Double, Double) {
        let n = Double(fingers.count)
        return (fingers.reduce(0) { $0 + $1.1.0 } / n, fingers.reduce(0) { $0 + $1.1.1 } / n)
    }

    private func fingersNow(_ fingers: [(UInt8, (Double, Double))]) {
        let now = clock()
        switch touch {
        case .idle:
            if fingers.count == 1 {
                monitor.pointerMove(fingers[0].1.0, fingers[0].1.1)  // at once: the pointer is there
                touch = .one(id: fingers[0].0, at: fingers[0].1, since: now, pressed: false)
            } else if fingers.count >= 2 {
                let m = middle(fingers)
                touch = .two(since: now, middle: m, first: m, moved: false, scrolling: false)
            }
        case .one(let id, let at, let since, let pressed):
            guard let finger = fingers.first(where: { $0.0 == id }) else {
                // Lifted: a tap clicks where it landed; a drag lets go.
                if !pressed { monitor.pointerMove(at.0, at.1); monitor.button(.left, pressed: true) }
                monitor.button(.left, pressed: false)
                touch = fingers.isEmpty ? .idle : .lifting
                return
            }
            if !pressed && fingers.count >= 2 {
                let m = middle(fingers)
                touch = .two(since: since, middle: m, first: m, moved: false, scrolling: false)
                return
            }
            if !pressed && (moved(finger.1, at) >= Input.slop || now - since >= Input.hold) {
                monitor.pointerMove(at.0, at.1)
                monitor.button(.left, pressed: true)
                touch = .one(id: id, at: at, since: since, pressed: true)
            }
            if case .one(_, _, _, true) = touch { monitor.pointerMove(finger.1.0, finger.1.1) }
        case .two(let since, let last, let first, var wasMoved, var scrolling):
            if fingers.count >= 2 {
                let m = middle(fingers)
                wasMoved = wasMoved || moved(m, first) >= Input.tapMove
                if wasMoved && (m.0 != last.0 || m.1 != last.1) {
                    monitor.scroll(m.0 - last.0, m.1 - last.1, scrolling ? .changed : .began)
                    scrolling = true
                }
                touch = .two(since: since, middle: m, first: first, moved: wasMoved, scrolling: scrolling)
                return
            }
            if scrolling { monitor.scroll(0, 0, .ended) }
            if !wasMoved && now - since < Input.tapTime {
                monitor.pointerMove(first.0, first.1)
                monitor.button(.right, pressed: true)
                monitor.button(.right, pressed: false)
            }
            touch = fingers.isEmpty ? .idle : .lifting
        case .lifting:
            if fingers.isEmpty { touch = .idle }
        }
    }

    /// Called every few ms while busy: presses a finger held still, and lifts
    /// everything when the tablet has gone quiet.
    func check() {
        if case .one(let id, let at, let since, false) = touch, clock() - since >= Input.hold {
            monitor.pointerMove(at.0, at.1)
            monitor.button(.left, pressed: true)
            touch = .one(id: id, at: at, since: since, pressed: true)
        }
        guard clock() - heard >= Input.silence else { return }
        close()
    }

    func close() {
        if case .two(_, _, _, _, true) = touch { monitor.scroll(0, 0, .ended) }
        touch = .idle
        pen?.close()
        monitor.releaseAll()
    }
}
