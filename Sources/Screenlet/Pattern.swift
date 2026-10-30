import AppKit

/// A repeatable test pattern for measuring latency and fidelity: scrolling
/// text, a panning photo, a plasma and a moving square, at 60 Hz.
final class Pattern: NSView {
    private var offset = 0.0
    private var timer: Timer?
    private var window_: NSWindow?

    /// Shows the pattern on the display, once AppKit knows it, until close().
    static func show(on display: CGDirectDisplayID) -> Pattern {
        let pattern = Pattern()
        pattern.open(on: display)
        return pattern
    }

    private func open(on display: CGDirectDisplayID) {
        guard let screen = NSScreen.screens.first(where: {
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == display
        }) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in open(on: display) }
            return
        }
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        window.setFrame(screen.frame, display: true)
        window.level = .screenSaver
        window.contentView = self
        window.orderFrontRegardless()
        window_ = window
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            self?.offset += 4
            self?.needsDisplay = true
        }
    }

    func close() {
        timer?.invalidate()
        window_?.orderOut(nil)
    }

    override var isFlipped: Bool { true }

    /// Photo-like detail from overlapping soft discs (fixed seed), wider than the
    /// screen so it can pan.
    private lazy var photo: NSImage = {
        var seed: UInt64 = 0x5EED
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        return NSImage(size: NSSize(width: 4000, height: 420), flipped: false) { rect in
            NSColor(white: 0.5, alpha: 1).setFill()
            rect.fill()
            for _ in 0 ..< 1500 {
                let r = 4 + next() * 40
                NSColor(hue: next(), saturation: 0.3 + next() * 0.7, brightness: 0.3 + next() * 0.7, alpha: 0.6).setFill()
                NSBezierPath(ovalIn: NSRect(x: next() * rect.width, y: next() * rect.height, width: r, height: r)).fill()
            }
            return true
        }
    }()

    /// Frame t of a plasma (sines of the position and time), 640x360.
    private func plasma(_ t: Int) -> NSImage {
        let w = 640, h = 360
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        let time = Double(t) / 8
        for y in 0 ..< h {
            for x in 0 ..< w {
                let v = sin(Double(x) / 23 + time) + sin(Double(y) / 17 - time * 1.3) + sin(Double(x + y) / 31 + time * 0.7)
                    + sin(sqrt(Double(x * x + y * y)) / 13 - time * 2)
                let i = (y * w + x) * 4
                pixels[i] = UInt8(127.5 + 127.5 * sin(v * 2))
                pixels[i + 1] = UInt8(127.5 + 127.5 * sin(v * 2 + 2.1))
                pixels[i + 2] = UInt8(127.5 + 127.5 * sin(v * 3 + 4.2))
            }
        }
        let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false,
                            intent: .defaultIntent)!
        return NSImage(cgImage: image, size: NSSize(width: w, height: h))
    }

    override func draw(_ dirty: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        // Gradients, like a photo or wallpaper.
        let band = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height * 0.25)
        NSGradient(colors: [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple])!.draw(in: band, angle: 0)
        NSGradient(starting: .black, ending: .white)!.draw(in: NSRect(x: 0, y: band.maxY, width: bounds.width, height: 40), angle: 0)
        // Scrolling text, like a document.
        let words = "Screenlet sends this Mac's desktop to the tablet; small text shows what the encoder keeps. "
        var y = band.maxY + 50 - offset.truncatingRemainder(dividingBy: 120)
        var size = 9.0
        while y < bounds.height {
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.black]
            (String(repeating: words, count: 4) as NSString).draw(at: NSPoint(x: 10, y: y), withAttributes: attributes)
            y += size * 1.6
            size = size >= 18 ? 9 : size + 1.5
        }
        // The photo panning, like scrolling a picture. The hardest part.
        let pan = offset.truncatingRemainder(dividingBy: photo.size.width - bounds.width)
        photo.draw(in: NSRect(x: 0, y: bounds.height - photo.size.height, width: bounds.width, height: photo.size.height),
                   from: NSRect(x: pan, y: 0, width: bounds.width, height: photo.size.height), operation: .copy, fraction: 1)
        // A plasma, like video: colour changes everywhere that motion prediction
        // cannot follow, so only the bitrate decides its sharpness.
        let video = NSRect(x: bounds.width - 660, y: bounds.height * 0.3, width: 640, height: 360)
        plasma(Int(offset / 4)).draw(in: video)
        // A moving square, like a dragged window.
        let x = (sin(offset / 120) * 0.5 + 0.5) * (bounds.width - 200)
        NSColor.systemTeal.setFill()
        NSRect(x: x, y: bounds.height * 0.55, width: 200, height: 200).fill()
    }
}
