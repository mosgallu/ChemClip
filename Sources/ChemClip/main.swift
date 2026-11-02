import AppKit
import ServiceManagement
import ChemClipCore

/// Watches the clipboard. When ChemDraw copies a drawing, adds Office's own vector picture format
/// to the same clipboard entry, so a normal Command-V in Word, PowerPoint, Excel or Outlook pastes
/// a sharp SVG (with a vector EMF fallback). Everything stays in memory; nothing is written to disk.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private var timer: Timer?
    private var lastCount = NSPasteboard.general.changeCount
    private var generation = 0
    private static let idle = "Ready: copy a drawing in ChemDraw"
    private var status = AppDelegate.idle
    private let queue = DispatchQueue(label: "ChemClip.convert", qos: .userInitiated)
    private let defaults = UserDefaults.standard
    private var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }
    private var mode: OfficeMode {
        get { defaults.string(forKey: "mode").flatMap(OfficeMode.init) ?? .vector }
        set { defaults.set(newValue.rawValue, forKey: "mode") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--smoke-test") {
            setUpStatusItem()
            print("ChemClip menu bar initialized; enhancement is \(enabled ? "on" : "off").")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
            return
        }
        let me = NSRunningApplication.current
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains(where: { $0 != me }) { NSApp.terminate(nil); return }
        setUpStatusItem()
        timer = Timer(timeInterval: 0.15, target: self, selector: #selector(poll), userInfo: nil, repeats: true)
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func setUpStatusItem() {
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu(); menu.delegate = self; item.menu = menu
        updateIcon()
        rebuild()
    }
    private func updateIcon() {
        item.button?.image = Self.menuBarIcon(active: enabled)
        item.button?.toolTip = "ChemClip: " + (enabled ? status : "paused")
    }
    /// A benzene ring matching the app icon, drawn as a template image so it follows the menu bar's appearance.
    /// Paused shows the ring only, dimmed.
    static func menuBarIcon(active: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let c = NSPoint(x: 9, y: 9), r: CGFloat = 7.2
            let corners = (0..<6).map { i -> NSPoint in
                let a = CGFloat.pi / 6 + CGFloat(i) * .pi / 3
                return NSPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
            }
            NSColor.black.withAlphaComponent(active ? 1 : 0.45).setStroke()
            let ring = NSBezierPath()
            ring.move(to: corners[0]); corners.dropFirst().forEach(ring.line); ring.close()
            ring.lineWidth = 1.6; ring.lineJoinStyle = .round; ring.stroke()
            guard active else { return true }
            let bonds = NSBezierPath()
            for i in stride(from: 0, to: 6, by: 2) {
                func inset(_ p: NSPoint) -> NSPoint { NSPoint(x: c.x + (p.x - c.x) * 0.62, y: c.y + (p.y - c.y) * 0.62) }
                let p = inset(corners[i]), q = inset(corners[(i + 1) % 6])
                bonds.move(to: NSPoint(x: p.x + (q.x - p.x) * 0.15, y: p.y + (q.y - p.y) * 0.15))
                bonds.line(to: NSPoint(x: q.x + (p.x - q.x) * 0.15, y: q.y + (p.y - q.y) * 0.15))
            }
            bonds.lineWidth = 1.4; bonds.lineCapStyle = .round; bonds.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = active ? "ChemClip" : "ChemClip (paused)"
        return image
    }

    // MARK: Menu

    func menuWillOpen(_ menu: NSMenu) { rebuild() }
    private func rebuild() {
        guard let menu = item.menu else { return }
        menu.removeAllItems(); menu.autoenablesItems = false
        add(menu, enabled ? status : "Paused: ChemDraw copies are left as they are", nil, enabled: false)
        menu.addItem(.separator())
        add(menu, "Enhance ChemDraw Copies", #selector(toggle), state: enabled)
        menu.addItem(.separator())
        add(menu, "Paste into Office As", nil, enabled: false)
        add(menu, "Vector Graphic (SVG)", #selector(useVector), state: mode == .vector, indent: 1,
            tip: "Sharp at any size and on Windows. Copy it from Office back into ChemDraw to edit it.")
        add(menu, "High-Resolution Picture (600 dpi)", #selector(usePicture), state: mode == .picture, indent: 1,
            tip: "Use when you export with Save as Picture → PNG. Not editable in ChemDraw afterwards.")
        menu.addItem(.separator())
        add(menu, "Open at Login", #selector(toggleLogin), state: SMAppService.mainApp.status == .enabled)
        add(menu, "How ChemClip Works…", #selector(help))
        add(menu, "Show Clipboard Formats…", #selector(report))
        menu.addItem(.separator())
        add(menu, "About ChemClip", #selector(about))
        add(menu, "Quit ChemClip", #selector(quit), key: "q")
    }
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector?, enabled: Bool = true, state: Bool? = nil,
                     indent: Int = 0, tip: String? = nil, key: String = "") {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self; entry.isEnabled = enabled; entry.indentationLevel = indent; entry.toolTip = tip
        if let state { entry.state = state ? .on : .off }
        menu.addItem(entry)
    }

    @objc private func toggle() {
        enabled.toggle()
        generation += 1
        lastCount = NSPasteboard.general.changeCount
        status = Self.idle
        updateIcon(); rebuild()
    }
    @objc private func useVector() { setMode(.vector) }
    @objc private func usePicture() { setMode(.picture) }
    private func setMode(_ new: OfficeMode) {
        guard new != mode else { return }
        mode = new
        status = "Applies from your next copy in ChemDraw"
        updateIcon(); rebuild()
    }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            alert("Couldn't change Open at Login", "macOS reported: \(error.localizedDescription)\n\nYou can add ChemClip yourself in System Settings → General → Login Items.")
        }
        rebuild()
    }

    // MARK: Clipboard

    @objc private func poll() {
        let board = NSPasteboard.general
        guard enabled, board.changeCount != lastCount else { return }
        lastCount = board.changeCount
        generation += 1
        // Only ChemDraw copies, and Office copies of ChemClip pictures, are read; anything else is skipped by type.
        if let restoration = ClipboardRestorer.restoration(board) {
            if ClipboardRestorer.write(restoration, to: board) {
                lastCount = board.changeCount
                status = "Ready to paste into ChemDraw as an editable structure"; updateIcon()
            }
            return
        }
        guard let snapshot = ClipboardEnhancer.snapshot(board) else { return }
        let token = generation, mode = mode
        status = "Converting…"; updateIcon()
        queue.async {
            let result = Result { try ClipboardEnhancer.enhance(snapshot, mode: mode) }
            DispatchQueue.main.async { self.finish(result, snapshot: snapshot, token: token) }
        }
    }
    private func finish(_ result: Result<Enhancement, Error>, snapshot: ClipboardSnapshot, token: Int) {
        guard token == generation, enabled else { return }   // a newer copy or a pause superseded this one
        switch result {
        case .success(let enhancement):
            if ClipboardEnhancer.write(enhancement, for: snapshot, to: .general) {
                lastCount = NSPasteboard.general.changeCount
                status = "Ready to paste into Office as a " + enhancement.note
            }
        case .failure(let error):
            status = "Couldn't convert this copy: " + error.localizedDescription
        }
        updateIcon()
    }

    // MARK: Info

    @objc private func help() {
        alert("How ChemClip works", """
        Copy a drawing in ChemDraw with ⌘C and paste it into Word, PowerPoint, Excel or Outlook with ⌘V. ChemClip adds Office's own picture format to the copy, so the drawing stays sharp, including on Windows.

        Paste into Office As
        • Vector Graphic (SVG): sharp at any zoom. To export it, use Save as Picture and choose SVG or PDF. Office saves SVG graphics as low-resolution PNGs.
        • High-Resolution Picture (600 dpi): use this when you need Save as Picture → PNG.

        Back to ChemDraw
        A ChemDraw copy still pastes into ChemDraw as an editable structure. Vector graphics also carry the structure inside the picture. Copy one in Office, even from a saved file, and paste it into ChemDraw to edit it again. Anyone you send the file to can do the same.

        Privacy
        Everything happens in memory. ChemClip writes no files, keeps no clipboard history and makes no network connections. Other copies are ignored.
        """)
    }
    @objc private func about() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "ChemClip", .applicationVersion: version, .version: "",
            .credits: NSAttributedString(string: "Sharp ChemDraw drawings in Microsoft Office for Mac.\nMIT License.",
                                         attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]),
        ])
    }
    @objc private func report() { alert("Clipboard formats", "Type names on the clipboard right now. Contents are not shown.\n\n" + ClipboardEnhancer.diagnostics(.general)) }
    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = text; alert.runModal()
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
