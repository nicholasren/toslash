import AppKit
import ServiceManagement

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let server = Server()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.image = menuBarGlyph()
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        server.onChange = { [weak self] in
            guard let self else { return }
            self.statusItem.button?.appearsDisabled = self.server.state != .running
        }
        server.start()
        offerHostsSetup()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = switch server.state {
        case .running: "Running at http://\(site)/"
        case .starting: "Starting…"
        case .stopped: "Stopped"
        case .failed(let error): "Failed: \(error)"
        }
        let line = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        line.isEnabled = false
        menu.addItem(line)
        menu.addItem(.separator())
        menu.addItem(item("Start", #selector(start), enabled: !server.isActive))
        menu.addItem(item("Stop", #selector(stop), enabled: server.isActive))
        menu.addItem(item("Restart", #selector(restart), enabled: server.isActive))
        menu.addItem(.separator())
        let login = item("Open at Login", #selector(toggleLogin), enabled: true)
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(NSMenuItem(title: "Quit ToSlash", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    func item(_ title: String, _ selector: Selector, enabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        return item
    }

    @objc func start() { server.start() }
    @objc func stop() { server.stop() }
    @objc func restart() { server.restart() }

    @objc func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
            if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Asked on every launch until the short name resolves, since declining leaves its links broken.
    func offerHostsSetup() {
        guard port == 80, !resolvesToLoopback(shortHost) else { return }
        let alert = NSAlert()
        alert.messageText = "Set up \(shortHost)/ links?"
        alert.informativeText = "ToSlash adds \"127.0.0.1 \(shortHost)\" to /etc/hosts so http://\(shortHost)/<name> reaches it. macOS asks for an administrator password."
        alert.addButton(withTitle: "Set Up")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let shell = "echo '127.0.0.1 \(shortHost)' >> /etc/hosts; dscacheutil -flushcache; killall -HUP mDNSResponder"
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"\(shell)\" with administrator privileges")?.executeAndReturnError(&error)
        if let error, (error[NSAppleScript.errorNumber] as? Int) != -128 {
            let failed = NSAlert()
            failed.messageText = "Could not update /etc/hosts"
            failed.informativeText = error[NSAppleScript.errorMessage] as? String ?? "\(error)"
            failed.runModal()
        }
    }
}

/// A slash inside a rounded box, drawn on a 20-unit grid. As a template image,
/// macOS tints it for light and dark menu bars and dims it while the server is stopped.
func menuBarGlyph() -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
        let grid = NSAffineTransform()
        grid.scale(by: 18.0 / 20)
        grid.concat()
        NSColor.black.setStroke()
        let box = NSBezierPath(roundedRect: NSRect(x: 2.5, y: 3.5, width: 15, height: 13), xRadius: 3.5, yRadius: 3.5)
        box.lineWidth = 1.6
        box.stroke()
        let slash = NSBezierPath()
        slash.move(to: NSPoint(x: 8, y: 13.5))
        slash.line(to: NSPoint(x: 12, y: 6.5))
        slash.lineWidth = 1.8
        slash.lineCapStyle = .round
        slash.stroke()
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "ToSlash"
    return image
}

/// The app icon's tile as a 256 px PNG for the to/ page, cut from the bundled .icns.
/// The .icns follows Apple's grid, an 824 px tile inside a 1024 px canvas, so the
/// transparent margin is cropped off. nil when not running from the app bundle.
let pageIcon: Data? = {
    guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
          let image = NSImage(contentsOf: url) else { return nil }
    var full = NSRect(x: 0, y: 0, width: 1024, height: 1024)
    guard let cg = image.cgImage(forProposedRect: &full, context: nil, hints: nil) else { return nil }
    let k = CGFloat(cg.width) / 1024
    guard let tile = cg.cropping(to: CGRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)) else { return nil }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.imageInterpolation = .high
    NSGraphicsContext.current!.cgContext.draw(tile, in: CGRect(x: 0, y: 0, width: 256, height: 256))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}()

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
