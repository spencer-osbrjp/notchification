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
    var cancellables = Set<AnyCancellable>()
    var statusItem: NSStatusItem!
    var updateItem: NSMenuItem!

    func applicationDidFinishLaunching(_ note: Notification) {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main!
        screenFrame = screen.frame
        if screen.safeAreaInsets.top > 0 {
            model.notchHeight = screen.safeAreaInsets.top
        }
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            model.notchWidth = right.minX - left.maxX
        }

        let size = NSSize(width: 760, height: 420)
        let origin = NSPoint(x: screenFrame.midX - size.width / 2,
                             y: screenFrame.maxY - size.height)
        panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: OverlayView(model: model, panelSize: size))
        panel.orderFrontRegardless()

        // Small separate panel for the banner so it can take clicks (focus the terminal)
        // while everything else stays click-through.
        let bSize = NSSize(width: 480, height: 150)
        bannerPanel = NSPanel(contentRect: NSRect(x: screenFrame.midX - bSize.width / 2,
                                                  y: screenFrame.maxY - bSize.height,
                                                  width: bSize.width, height: bSize.height),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        bannerPanel.level = .statusBar
        bannerPanel.backgroundColor = .clear
        bannerPanel.isOpaque = false
        bannerPanel.hasShadow = false
        bannerPanel.ignoresMouseEvents = true
        bannerPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        bannerPanel.contentView = NSHostingView(rootView: BannerHost(model: model))
        bannerPanel.orderFrontRegardless()

        model.$current
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cur in self?.bannerPanel.ignoresMouseEvents = (cur == nil) }
            .store(in: &cancellables)

        let model = self.model
        watcher = EventWatcher { event in
            Task { @MainActor in model.handle(event) }
        }

        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { _ in
            DispatchQueue.main.async { [weak self] in self?.checkHover() }
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

    // MARK: - Auto-update (repo commit vs installed sha, via gh)

    nonisolated static let repoSlug = "spencer-osbrjp/notchification"
    nonisolated static var repoPath: String {
        UserDefaults.standard.string(forKey: "repoPath")
            ?? NSHomeDirectory() + "/Documents/Works/OSBR/notchification"
    }

    private func checkForUpdates() {
        // dev runs (swift run) carry no baked sha — skip
        guard let shaURL = Bundle.main.url(forResource: "sha", withExtension: nil),
              let installed = try? String(contentsOf: shaURL, encoding: .utf8)
                  .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return }
        Task.detached {
            guard let gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
                  let remote = Self.shell(gh, ["api", "repos/\(Self.repoSlug)/commits/main", "--jq", ".sha"])?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  remote.count == 40, remote != installed
            else { return }
            await MainActor.run {
                self.updateItem.isHidden = false
                self.updateItem.title = "Install update (\(remote.prefix(7)))…"
                self.model.notice("Update available — install from the menu bar icon")
            }
        }
    }

    @objc private func installUpdate() {
        updateItem.title = "Updating…"
        updateItem.action = nil
        Task.detached {
            _ = Self.shell("/usr/bin/git", ["-C", Self.repoPath, "pull", "--ff-only"])
            _ = Self.shell("/usr/bin/make", ["-C", Self.repoPath, "install"])
            await MainActor.run { NSApp.terminate(nil) } // make install already opened the new build
        }
    }

    nonisolated private static func shell(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }

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

    /// Expand on hover over the notch (or the character when it's out); collapse when the mouse leaves.
    private func checkHover() {
        let loc = NSEvent.mouseLocation
        let notchRect = NSRect(x: screenFrame.midX - model.notchWidth / 2,
                               y: screenFrame.maxY - model.notchHeight,
                               width: model.notchWidth,
                               height: model.notchHeight)
        let hot: NSRect
        if model.expanded {
            hot = NSRect(x: screenFrame.midX - 200, y: screenFrame.maxY - 340, width: 400, height: 340)
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
