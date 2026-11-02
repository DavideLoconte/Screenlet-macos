import AppKit
import Network

let arguments = CommandLine.arguments
if arguments.count >= 2, ["--show-cable", "--show-wifi"].contains(arguments[1]) {
    // Diagnostic CLI execution mode. Streams display output to an attached or discovered companion
    // device for a specified duration and reports transport statistics at 2-second intervals.
    // Supported argument options:
    // - "mirror": Mirror the primary desktop display.
    // - "hevc" / "h264": Video codec selection.
    // - "latency" / "balanced" / "clarity": Encoding profile priority.
    // - "30" / "60": Target refresh rate in Hz.
    // - "native" / <WIDTHxHEIGHT>: Display resolution mode.
    // - "pattern": Display procedural animated benchmark pattern on virtual display.
    // - "measure": Enable PSNR fidelity evaluation pipeline.
    // - "serial=SERIAL": Target specific USB device serial.
    let seconds = arguments.count > 2 ? Double(arguments[2]) ?? 20 : 20
    var mode = DisplaySession.Mode()
    var pattern = false
    var tablet: String?
    for word in arguments.dropFirst(3) {
        switch word {
        case _ where word.hasPrefix("serial="): tablet = String(word.dropFirst("serial=".count))
        case "mirror": mode.mirror = CGMainDisplayID()
        case "hevc": mode.codec = "hevc"
        case "h264": mode.codec = "avc"
        case "60": mode.fps = 60
        case "measure": Fidelity.enabled = true
        case "latency", "balanced", "clarity": mode.priority = word
        case "30": mode.fps = 30
        case "native": mode.resolution = "tablet"
        case "pattern": pattern = true
        default: mode.resolution = word
        }
    }
    Streamer.statsEvery = 2
    NSApplication.shared.setActivationPolicy(.accessory)
    var session: DisplaySession?
    var shown: Pattern?
    func show(_ endpoint: NWEndpoint, expect: String?, cable: Cable?) {
        let now = DisplaySession(endpoints: [endpoint], expect: expect, cable: cable, mode: mode)
        session = now
        now.onStarted = { w, h in
            log("started: \(w)x\(h)", cable == nil ? "over Wi-Fi" : "over the cable")
            if pattern, let id = now.displayID { shown = Pattern.show(on: id) }
        }
        now.onEnded = { error in log("ended:", error?.localizedDescription ?? "-"); exit(error == nil ? 0 : 1) }
        now.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            shown?.close()
            now.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { cable?.close(); exit(0) }
        }
    }
    if arguments[1] == "--show-cable" {
        let chosen = tablet
        Thread.detachNewThread {
            do {
                let cable = try Cable(tablet: chosen)
                later { show(cable.endpoint, expect: nil, cable: cable) }
            } catch {
                log("failed:", error.localizedDescription)
                exit(1)
            }
        }
    } else {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_screenlet._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in
            let paired = Paired.all()
            for result in results where session == nil {
                guard case .bonjour(let txt) = result.metadata, let id = txt["id"]?.lowercased(),
                      paired.keys.contains(where: { $0.hasPrefix(id) }) else { continue }
                show(result.endpoint, expect: id, cable: nil)
            }
        }
        browser.start(queue: .main)
        withExtendedLifetime(browser) { NSApplication.shared.run() }
    }
    NSApplication.shared.run()
} else {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.run()
}
