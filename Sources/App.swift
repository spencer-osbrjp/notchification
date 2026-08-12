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
