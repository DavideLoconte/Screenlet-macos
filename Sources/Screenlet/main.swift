import AppKit
import Network

let arguments = CommandLine.arguments
if arguments.count >= 2, ["--show-cable", "--show-wifi"].contains(arguments[1]) {
    // A test from the terminal. Shows the desktop on the tablet for a number
    // of seconds, over the cable or over Wi-Fi to the first paired tablet
    // found, and logs the latency every 2 s. Options: "mirror" (the main
    // display), "hevc", a priority, "30" (Hz), "native", a resolution, or "pattern"
    // (a moving test pattern on the tablet's display, the same load every run).
    let seconds = arguments.count > 2 ? Double(arguments[2]) ?? 20 : 20
    var mode = DisplaySession.Mode()
    var pattern = false
    for word in arguments.dropFirst(3) {
        switch word {
        case "mirror": mode.mirror = CGMainDisplayID()
        case "hevc": mode.codec = "hevc"
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
        Thread.detachNewThread {
            do {
                let cable = try Cable()
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
