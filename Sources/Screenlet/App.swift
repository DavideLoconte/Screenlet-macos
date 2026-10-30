import AppKit
import Combine
import Network
import SwiftUI

/// A string in the system's language.
func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

/// The state and actions behind the menu bar and the window.
final class Model: ObservableObject {
    struct Tablet {
        let id: String          // the first 16 digits of its certificate's fingerprint
        let name: String
        let endpoint: NWEndpoint
    }

    @Published var state = ""
    @Published var tablets: [String: Tablet] = [:]   // Bonjour name -> the tablet
    @Published var plugged = Cable.present
    @Published var session: DisplaySession?
    @Published var showing: String?   // the tablet showing the desktop
    /// Show the desktop by itself when a paired tablet is plugged in.
    @Published var autoStart = UserDefaults.standard.object(forKey: "autoStart") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoStart, forKey: "autoStart") }
    }

    // How the desktop reaches the tablet (DisplaySession.Mode), from the next session.
    @Published var mirroring = UserDefaults.standard.bool(forKey: "mirroring") {
        didSet { UserDefaults.standard.set(mirroring, forKey: "mirroring") }
    }
    @Published var resolution = UserDefaults.standard.string(forKey: "resolution") ?? "auto" {
        didSet { UserDefaults.standard.set(resolution, forKey: "resolution") }
    }
    @Published var mirror = UserDefaults.standard.object(forKey: "mirror") as? Int ?? Int(CGMainDisplayID()) {
        didSet { UserDefaults.standard.set(mirror, forKey: "mirror") }
    }
    @Published var priority = UserDefaults.standard.string(forKey: "priority") ?? "balanced" {
        didSet { UserDefaults.standard.set(priority, forKey: "priority") }
    }

    var mode: DisplaySession.Mode {
        // The chosen display if it is still connected, the main one otherwise.
        let shown = Model.displays().contains { $0.id == mirror } ? CGDirectDisplayID(mirror) : CGMainDisplayID()
        // The refresh rate is the tablet's, the codec HEVC where it decodes it: nothing to choose.
        return DisplaySession.Mode(resolution: resolution, mirror: mirroring ? shown : nil, priority: priority)
    }

    /// The Mac's displays that can be mirrored, excluding Screenlet's: id and name.
    static func displays() -> [(id: Int, name: String)] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  CGDisplayModelNumber(id) != 0x5350 else { return nil }
            return (Int(id), screen.localizedName)
        }
    }

    /// The tablet's screen size from the last session.
    var tabletScreen: (Int, Int)? {
        guard let size = UserDefaults.standard.array(forKey: "tabletScreen") as? [Int], size.count == 2 else { return nil }
        return (size[0], size[1])
    }
    private var cable: Cable?
    private var browser: NWBrowser?
    private var timer: Timer?

    init() {
        state = L("No tablet with Screenlet open")
        browse()
        // There is no notification for the cable, so poll it.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = self.cable != nil || Cable.present
            if now == self.plugged { return }
            self.plugged = now
            // Plugged in: the desktop goes to it by itself, once paired.
            if now && self.autoStart && self.session == nil && !Paired.all().isEmpty { self.showOverCable() }
        }
    }

    private func showOverCable() {
        // No announced id here: any paired tablet will do, and TLS proves which.
        overCable { self.start(L("the tablet on the cable"), [$0.endpoint], expect: nil, cable: $0) }
    }

    func show(_ text: String) {
        state = text
        log("menu bar:", text)
    }

    // -- what can be done ----------------------------------------------------------
    /// An action on a tablet, shown as a menu item (title) or a button (short) in
    /// the tablet's row of the window.
    struct Action: Identifiable {
        let id: String
        let title: String
        let device: String
        let detail: String
        let icon: String
        let short: String
        var primary = true
        let run: () -> Void
    }

    var actions: [Action] {
        let wifi = L("Wi-Fi"), cable = L("USB-C cable"), onCable = L("Tablet on the cable")
        if session != nil {
            return [Action(id: "stop", title: L("Disconnect"), device: showing ?? "", detail: state,
                           icon: "rectangle.on.rectangle", short: L("Disconnect"), primary: false, run: disconnect)]
        }
        let paired = Paired.all()
        var found: [Action] = []
        // A plugged-in tablet always uses the cable, whose tail latency is about
        // a tenth of Wi-Fi's. A second tablet on Wi-Fi is not shown then.
        let byCable = plugged
        let byWifi = !plugged
        for (key, tablet) in tablets.sorted(by: { $0.value.name.lowercased() < $1.value.name.lowercased() }) {
            if paired.keys.contains(where: { $0.hasPrefix(tablet.id) }) && !tablet.id.isEmpty {
                if byWifi {
                    found.append(Action(id: "show " + key, title: String(format: L("Show the desktop on %@"), tablet.name),
                                        device: tablet.name, detail: wifi, icon: "wifi", short: L("Show the desktop")) {
                        self.start(tablet.name, [tablet.endpoint], expect: tablet.id)
                    })
                }
            } else {
                found.append(Action(id: "pair " + key, title: String(format: L("Pair with %@…"), tablet.name),
                                    device: tablet.name, detail: wifi, icon: "wifi", short: L("Pair…"), primary: false) {
                    self.pair(tablet.name, [tablet.endpoint])
                })
            }
        }
        if byCable {
            if !paired.isEmpty {
                found.append(Action(id: "cable", title: L("Show the desktop over the cable"), device: onCable, detail: cable,
                                    icon: "cable.connector", short: L("Show the desktop"), run: showOverCable))
            }
            found.append(Action(id: "pair cable", title: L("Pair over the cable…"), device: onCable, detail: cable,
                                icon: "cable.connector", short: L("Pair…"), primary: paired.isEmpty) {
                self.overCable { self.pair(L("the tablet on the cable"), [$0.endpoint]) }
            })
        }
        return found
    }

    // -- the tablets on the network --------------------------------------------------
    private func browse() {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_screenlet._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            var found: [String: Tablet] = [:]
            for result in results {
                guard case .service(let name, _, _, _) = result.endpoint else { continue }
                var id = "", tablet = name
                if case .bonjour(let txt) = result.metadata {
                    id = String((txt["id"] ?? "").lowercased().prefix(64))
                    tablet = String((txt["name"].flatMap { $0.isEmpty ? nil : $0 } ?? name).prefix(64))
                }
                found[name] = Tablet(id: id, name: tablet, endpoint: result.endpoint)
            }
            later {
                guard let self else { return }
                for (key, tablet) in found where self.tablets[key] == nil { log("menu bar: Screenlet's app on \(tablet.name)") }
                self.tablets = found
                if self.session == nil {
                    let none = L("No tablet with Screenlet open"), ready = L("A tablet is ready")
                    if found.isEmpty && self.state == ready { self.show(none) }
                    if !found.isEmpty && self.state == none { self.show(ready) }
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    // -- pairing ---------------------------------------------------------------------
    private func pair(_ name: String, _ endpoints: [NWEndpoint]) {
        show(String(format: L("Pairing with %@…"), name))
        Thread.detachNewThread {
            do {
                let (_, tablet) = try Companion.pair(endpoints) { tablet, code in
                    // On the link's thread; the user compares the code on the main thread.
                    DispatchQueue.main.sync {
                        alert(String(format: L("Pair with %@?"), tablet),
                              String(format: L("Pair only if %@ shows the same code:\n\n%@"), tablet, code),
                              buttons: [L("Pair"), L("Cancel")])
                    }
                }
                later { self.show(String(format: L("Paired with %@"), tablet)) }
            } catch is PairingRefused {
                later { self.show(String(format: L("Not paired with %@"), name)) }
            } catch {
                later {
                    self.show(String(format: L("Could not pair with %@"), name))
                    alert(String(format: L("Could not pair with %@"), name), L(error.localizedDescription))
                }
            }
        }
    }

    // -- the desktop on the tablet -----------------------------------------------------
    private func start(_ name: String, _ endpoints: [NWEndpoint], expect: String?, cable: Cable? = nil) {
        guard session == nil else { return }
        let session = DisplaySession(endpoints: endpoints, expect: expect, cable: cable, mode: mode)
        session.onStarted = { [weak self] w, h in self?.show(String(format: L("On %@, %dx%d"), name, w, h)) }
        session.onPaused = { [weak self] paused in self?.show(String(format: L(paused ? "On %@, paused" : "On %@"), name)) }
        session.onEnded = { [weak self] error in
            guard let self else { return }
            self.session = nil
            guard let error else { return self.show(String(format: L("Ended on %@"), name)) }
            self.show(String(format: L("Could not show the desktop on %@"), name))
            alert(String(format: L("The desktop on %@ ended"), name), L(error.localizedDescription))
        }
        self.session = session
        showing = name
        show(String(format: L("Connecting to %@…"), name))
        session.start()
    }

    /// Calls then(cable) on the main thread once the cable's link is open. It
    /// stays open for pairing and then the desktop.
    private func overCable(_ then: @escaping (Cable) -> Void) {
        if let cable { return then(cable) }
        show(L("Opening the link over the cable…"))
        Thread.detachNewThread {
            do {
                let cable = try Cable()
                cable.onLost = { _ in later { self.cable = nil } }
                later {
                    self.cable = cable
                    then(cable)
                }
            } catch {
                later {
                    self.show(L("No link over the cable"))
                    alert(L("Screenlet could not use the cable"), L(error.localizedDescription))
                }
            }
        }
    }

    func disconnect() {
        guard let session else { return }
        session.stop()  // its onEnded is not called, so report it here
        self.session = nil
        show(L("Disconnected"))
    }

    func quit() {
        disconnect()
        cable?.close()
        // The link's thread tells the app shortly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }
}

@discardableResult
func alert(_ title: String, _ text: String, buttons: [String] = ["OK"]) -> Bool {
    let dialog = NSAlert()
    dialog.messageText = title
    dialog.informativeText = text
    buttons.forEach { dialog.addButton(withTitle: $0) }
    NSApp.activate(ignoringOtherApps: true)
    return dialog.runModal() == .alertFirstButtonReturn
}

enum Permissions {
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }
    static var accessibility: Bool { Monitor.accessibility(prompt: false) }
    static var granted: Bool { screenRecording && accessibility }

    static func openSettings(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_" + pane)!)
    }
}

// -- the windows ---------------------------------------------------------------------
/// The header of both windows: the app icon, a title and a short subtitle.
struct Header: View {
    let title: String
    let detail: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title2.weight(.semibold))
                HStack(spacing: 6) {
                    Circle().fill(tint).frame(width: 8, height: 8)
                    Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
    }
}

/// An SF Symbol on a coloured rounded square, as in System Settings.
struct Badge: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// A setting's label with a "?" button whose popover explains its effect on latency and clarity.
struct Explained: View {
    let title: String
    let help: String
    @State private var shown = false

    init(_ title: String, _ help: String) {
        self.title = title
        self.help = help
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Button { shown.toggle() } label: {
                Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(help)
            .popover(isPresented: $shown, arrowEdge: .trailing) {
                Text(help).fixedSize(horizontal: false, vertical: true).frame(width: 320, alignment: .leading).padding(14)
            }
        }
    }
}

struct MainView: View {
    @ObservedObject var model: Model
    let permissions: () -> Void

    private var tint: Color {
        model.session != nil ? .green : model.tablets.isEmpty && !model.plugged ? .secondary : .blue
    }

    var body: some View {
        let actions = model.actions
        // Each tablet with its buttons, in the order of its actions.
        let devices = actions.reduce(into: [String]()) { if !$0.contains($1.device) { $0.append($1.device) } }
        VStack(spacing: 0) {
            Header(title: "Screenlet", detail: model.state, tint: tint)
            Form {
                Section(L("Devices")) {
                    if devices.isEmpty {
                        HStack(spacing: 12) {
                            Image(systemName: "ipad.landscape").font(.title2).foregroundStyle(.tertiary)
                            Text(L("Open Screenlet on the tablet, on the same Wi-Fi as this Mac or on the cable."))
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 6)
                    }
                    ForEach(devices, id: \.self) { device in
                        let mine = actions.filter { $0.device == device }
                        HStack(spacing: 12) {
                            Badge(symbol: mine[0].icon, color: model.session != nil ? .green : .blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device).fontWeight(.medium)
                                Text(mine[0].detail).font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            ForEach(mine) { action in
                                if action.primary {
                                    Button(action.short, action: action.run).buttonStyle(.borderedProminent)
                                } else {
                                    Button(action.short, action: action.run)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                Section(L("Display")) {
                    Picker(selection: $model.mirroring) {
                        Text(L("Extend")).tag(false)
                        Text(L("Mirror")).tag(true)
                    } label: {
                        Explained(L("Show the desktop"), L("help.mode"))
                    }
                    .pickerStyle(.segmented)
                    if model.mirroring {
                        Picker(L("Display"), selection: $model.mirror) {
                            ForEach(Model.displays(), id: \.id) { Text($0.name).tag($0.id) }
                        }
                    } else {
                        Picker(selection: $model.resolution) {
                            Text(model.tabletScreen.flatMap(Sizes.models).map { String(format: L("Automatic (%@)"), $0) }
                                 ?? L("Automatic")).tag("auto")
                            if let screen = model.tabletScreen {
                                ForEach(Sizes.all(screen), id: \.0) { size in
                                    let name = "\(size.0) × \(size.1)"
                                    Text(size == Sizes.all(screen)[0] ? String(format: L("%@ (native)"), name) : name)
                                        .tag(size == Sizes.all(screen)[0] ? "tablet" : "\(size.0)x\(size.1)")
                                }
                            } else {
                                Text(L("Native")).tag("tablet")
                            }
                        } label: {
                            Explained(L("Resolution"), L("help.resolution"))
                        }
                    }
                    Picker(selection: $model.priority) {
                        Text(L("Latency")).tag("latency")
                        Text(L("Balanced")).tag("balanced")
                        Text(L("Clarity")).tag("clarity")
                    } label: {
                        Explained(L("Priority"), L("help.priority"))
                    }
                }
                Section(L("Settings")) {
                    Toggle(L("Show the desktop when the tablet is plugged in"), isOn: $model.autoStart)
                    LabeledContent(L("Permissions")) {
                        Button(L("Review…"), action: permissions)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct WelcomeView: View {
    let done: () -> Void
    @State private var screen = Permissions.screenRecording
    @State private var access = Permissions.accessibility
    @State private var asked = Set<String>()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            Header(title: L("Welcome to Screenlet"),
                   detail: L("To show this Mac's desktop on the tablet, Screenlet needs two permissions."),
                   tint: screen && access ? .green : .orange)
            Form {
                Section {
                    row("rectangle.dashed.badge.record", .red, L("Screen Recording"), L("To send the desktop to the tablet."), screen) {
                        // macOS asks only once; after that, the user allows it in System Settings.
                        if asked.insert("screen").inserted { CGRequestScreenCaptureAccess() } else { Permissions.openSettings("ScreenCapture") }
                    }
                    row("hand.point.up.left.fill", .blue, L("Accessibility"), L("So the tablet's touches and pen move the pointer."), access) {
                        if asked.insert("access").inserted { _ = Monitor.accessibility(prompt: true) } else { Permissions.openSettings("Accessibility") }
                    }
                } footer: {
                    Text(L("macOS may also ask to use the local network: allow it, to find the tablet over Wi-Fi."))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            HStack {
                Button(L("Reopen Screenlet"), action: reopen)
                    .help(L("Once Screen Recording is allowed, Screenlet may need to reopen."))
                Spacer()
                Button(L("Later"), action: done)
                Button(L("Continue"), action: done).keyboardShortcut(.defaultAction).disabled(!(screen && access))
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(tick) { _ in
            screen = Permissions.screenRecording
            access = Permissions.accessibility
        }
    }

    private func row(_ symbol: String, _ color: Color, _ name: String, _ why: String, _ allowed: Bool,
                     allow: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Badge(symbol: symbol, color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).fontWeight(.medium)
                Text(why).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if allowed {
                Label(L("Allowed"), systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon)
            } else {
                Button(L("Allow…"), action: allow).buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
    }

    /// Relaunches Screenlet after it quits, since macOS applies a new permission
    /// only at launch.
    private func reopen() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; open -n \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = Model()
    private var item: NSStatusItem!
    private var window: NSWindow?
    private var welcome: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "Screenlet"  // remembers where it is ⌘-dragged
        item.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "Screenlet")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        if !Permissions.granted {
            openWelcome()
        } else {
            openWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openWindow()
        return false
    }

    // The menu is rebuilt each time it opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: model.state, action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        for action in model.actions { add(menu, action.title, action.run) }
        menu.addItem(.separator())
        add(menu, L("Open Screenlet…"), openWindow)
        add(menu, L("Quit Screenlet"), model.quit)
    }

    private final class Run: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire() { run() }
    }

    private func add(_ menu: NSMenu, _ title: String, _ run: @escaping () -> Void) {
        let target = Run(run)
        let entry = menu.addItem(withTitle: title, action: #selector(Run.fire), keyEquivalent: "")
        entry.target = target
        entry.representedObject = target  // kept alive with the menu
    }

    private func make(_ title: String, _ view: some View) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false  // closing hides it; the menu bar shows it again
        window.center()
        return window
    }

    func openWindow() {
        if window == nil { window = make("Screenlet", MainView(model: model, permissions: { [weak self] in self?.openWelcome() })) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func openWelcome() {
        if welcome == nil {
            welcome = make("Screenlet", WelcomeView { [weak self] in
                self?.welcome?.orderOut(nil)
                self?.openWindow()
            })
        }
        NSApp.activate(ignoringOtherApps: true)
        welcome?.makeKeyAndOrderFront(nil)
    }
}
