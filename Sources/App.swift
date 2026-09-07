import AppKit
import Combine
import ServiceManagement
import SwiftUI

@main
struct Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = NotchModel()
    var panel: NSPanel!
    var bannerPanel: NSPanel!
    var watcher: EventWatcher!
    var screenFrame = NSRect.zero
    var mouseMonitor: Any?
    var localMouseMonitor: Any?
    var cancellables = Set<AnyCancellable>()
    var statusItem: NSStatusItem!
    var updateItem: NSMenuItem!
    var pendingUpdateTag: String?

    static let panelSize = NSSize(width: 760, height: 420)
    static let bannerSize = NSSize(width: 480, height: 150)

    func applicationDidFinishLaunching(_ note: Notification) {
        panel = Self.makePanel(size: Self.panelSize)
        panel.contentView = NSHostingView(rootView: OverlayView(model: model, panelSize: Self.panelSize))

        // Small separate panel for the banner so it can take clicks (focus the terminal)
        // while everything else stays click-through.
        bannerPanel = Self.makePanel(size: Self.bannerSize)
        bannerPanel.contentView = NSHostingView(rootView: BannerHost(model: model))

        layoutPanels()
        panel.orderFrontRegardless()
        bannerPanel.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.layoutPanels() }
        }

        model.$current
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cur in self?.bannerPanel.ignoresMouseEvents = (cur == nil) }
            .store(in: &cancellables)

        let model = self.model
        watcher = EventWatcher { events in
            Task { @MainActor in events.forEach { model.handle($0) } }
        }

        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { _ in
            DispatchQueue.main.async { [weak self] in self?.checkHover() }
        }
        // global monitors skip events delivered to our own windows (e.g. over the banner panel)
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] e in
            DispatchQueue.main.async { self?.checkHover() }
            return e
        }

        setupStatusItem()

        // installed builds register as a login item once; the menu toggle stays in control after
        if Bundle.main.bundlePath.hasPrefix("/Applications"),
           !UserDefaults.standard.bool(forKey: "didAutoLogin") {
            UserDefaults.standard.set(true, forKey: "didAutoLogin")
            try? SMAppService.mainApp.register()
        }

        checkForUpdates()
        Timer.scheduledTimer(withTimeInterval: 4 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForUpdates() }
        }
    }

    private static func makePanel(size: NSSize) -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        return p
    }

    /// Called at launch and whenever displays change (dock/undock, sleep, resolution).
    private func layoutPanels() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main ?? NSScreen.screens.first else { return }
        screenFrame = screen.frame
        if screen.safeAreaInsets.top > 0 {
            model.notchHeight = screen.safeAreaInsets.top
        }
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            model.notchWidth = right.minX - left.maxX
        }
        panel.setFrame(NSRect(x: screenFrame.midX - Self.panelSize.width / 2,
                              y: screenFrame.maxY - Self.panelSize.height,
                              width: Self.panelSize.width, height: Self.panelSize.height),
                       display: true)
        bannerPanel.setFrame(NSRect(x: screenFrame.midX - Self.bannerSize.width / 2,
                                    y: screenFrame.maxY - Self.bannerSize.height,
                                    width: Self.bannerSize.width, height: Self.bannerSize.height),
                             display: true)
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.statusIcon()

        let menu = NSMenu()

        let characterMenu = NSMenu()
        let buddy = NSMenuItem(title: "Pixel Buddy (orange)", action: nil, keyEquivalent: "")
        buddy.state = .on
        characterMenu.addItem(buddy)
        let characterItem = NSMenuItem(title: "Character", action: nil, keyEquivalent: "")
        characterItem.submenu = characterMenu
        menu.addItem(characterItem)

        let sound = NSMenuItem(title: "Sound", action: #selector(toggleSound(_:)), keyEquivalent: "")
        sound.target = self
        sound.state = UserDefaults.standard.bool(forKey: "soundOff") ? .off : .on
        menu.addItem(sound)

        let agentsMenu = NSMenu()
        for (title, tag) in [("All", 0), ("Claude", 1), ("Codex", 2)] {
            let it = NSMenuItem(title: title, action: #selector(pickAgent(_:)), keyEquivalent: "")
            it.target = self
            it.tag = tag
            agentsMenu.addItem(it)
        }
        let agentsItem = NSMenuItem(title: "Agents", action: nil, keyEquivalent: "")
        agentsItem.submenu = agentsMenu
        menu.addItem(agentsItem)
        syncAgentMenu(agentsMenu)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        updateItem = NSMenuItem(title: "Install update…", action: #selector(installUpdate), keyEquivalent: "")
        updateItem.target = self
        updateItem.isHidden = true
        menu.addItem(updateItem)
        let quit = NSMenuItem(title: "Quit Notchification", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func toggleSound(_ item: NSMenuItem) {
        let off = !UserDefaults.standard.bool(forKey: "soundOff")
        UserDefaults.standard.set(off, forKey: "soundOff")
        item.state = off ? .off : .on
    }

    @objc private func pickAgent(_ item: NSMenuItem) {
        model.setAgentFilter(item.tag == 1 ? .claude : item.tag == 2 ? .codex : nil)
        if let menu = item.menu { syncAgentMenu(menu) }
    }

    private func syncAgentMenu(_ menu: NSMenu) {
        let tag = model.agentFilter == .claude ? 1 : model.agentFilter == .codex ? 2 : 0
        for it in menu.items { it.state = it.tag == tag ? .on : .off }
    }

    @objc private func toggleLogin(_ item: NSMenuItem) {
        // only works from the installed .app bundle (make install); silently no-ops in dev runs
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        } else {
            try? SMAppService.mainApp.register()
        }
        item.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    /// Menu bar icon drawn from the character sprite.
    private static func statusIcon() -> NSImage {
        let map = Sprite.walkA
        let cols = map[0].count, rows = map.count
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            let scale = 18.0 / CGFloat(max(cols, rows))
            for (y, row) in map.enumerated() {
                for (x, ch) in row.enumerated() where Sprite.color(ch) != nil {
                    NSColor(Sprite.color(ch)!).setFill()
                    NSRect(x: CGFloat(x) * scale + (18 - CGFloat(cols) * scale) / 2,
                           y: CGFloat(y) * scale + (18 - CGFloat(rows) * scale) / 2,
                           width: scale, height: scale).fill()
                }
            }
            return true
        }
        return img
    }

    // MARK: - Auto-update (installed sha vs latest release, installs the release artifact)

    nonisolated static let repoSlug = "spencer-osbrjp/notchification"

    nonisolated private static func ghPath() -> String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func checkForUpdates() {
        // dev runs (swift run) carry no baked sha — skip
        guard let shaURL = Bundle.main.url(forResource: "sha", withExtension: nil),
              let installed = try? String(contentsOf: shaURL, encoding: .utf8)
                  .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return }
        Task.detached {
            guard let gh = Self.ghPath(),
                  let tag = Self.shell(gh, ["release", "view", "--repo", Self.repoSlug,
                                            "--json", "tagName", "--jq", ".tagName"])?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !tag.isEmpty,
                  let remote = Self.shell(gh, ["api", "repos/\(Self.repoSlug)/commits/\(tag)",
                                               "--jq", ".sha"])?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  remote.count == 40, remote != installed
            else { return }
            await MainActor.run {
                self.pendingUpdateTag = tag
                self.updateItem.isHidden = false
                self.updateItem.title = "Install update (\(tag))…"
                self.model.notice("Update \(tag) available — install from the menu bar icon")
            }
        }
    }

    @objc private func installUpdate() {
        guard let tag = pendingUpdateTag else { return }
        updateItem.title = "Updating…"
        updateItem.action = nil
        Task.detached {
            let ok: Bool = {
                guard let gh = Self.ghPath() else { return false }
                let tmp = NSTemporaryDirectory() + "notchification-update"
                try? FileManager.default.removeItem(atPath: tmp)
                guard Self.shell(gh, ["release", "download", tag, "--repo", Self.repoSlug,
                                      "--pattern", "Notchification.app.zip", "--dir", tmp]) != nil,
                      Self.shell("/usr/bin/ditto", ["-x", "-k",
                                                    tmp + "/Notchification.app.zip",
                                                    "/Applications"]) != nil
                else { return false }
                return true
            }()
            await MainActor.run {
                if ok {
                    // relaunch after this instance exits — a plain `open` would only activate us
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/bin/sh")
                    p.arguments = ["-c", "sleep 1; /usr/bin/open /Applications/Notchification.app"]
                    try? p.run()
                    NSApp.terminate(nil)
                } else {
                    self.model.notice("Update failed — try again from the menu bar")
                    self.updateItem.title = "Install update (\(tag))…"
                    self.updateItem.action = #selector(self.installUpdate)
                }
            }
        }
    }

    nonisolated static func shell(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice // an unread stderr pipe can deadlock the child
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }

    // MARK: - Hover

    /// Expand on hover over the notch (or the character when it's out); collapse when the mouse leaves.
    private func checkHover() {
        let loc = NSEvent.mouseLocation
        let notchRect = NSRect(x: screenFrame.midX - model.notchWidth / 2,
                               y: screenFrame.maxY - model.notchHeight,
                               width: model.notchWidth,
                               height: model.notchHeight)
        let hot: NSRect
        if model.expanded {
            // generous: taller than the tallest panel content — over-holding is benign,
            // collapsing under the cursor is not
            hot = NSRect(x: screenFrame.midX - 210, y: screenFrame.maxY - 500, width: 420, height: 500)
        } else if model.characterOut {
            hot = notchRect.insetBy(dx: -110, dy: 0)
        } else {
            hot = notchRect
        }
        let inside = hot.contains(loc)
        if ProcessInfo.processInfo.environment["NOTCH_DEBUG"] != nil {
            try? "loc=\(loc) hot=\(hot) inside=\(inside)\n"
                .write(toFile: "/tmp/notch-debug.log", atomically: true, encoding: .utf8)
        }
        if inside != model.expanded {
            withAnimation(.spring(duration: 0.35)) { model.expanded = inside }
        }
    }
}
