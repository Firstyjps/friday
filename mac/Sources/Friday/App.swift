import AppKit
import SwiftUI

/// Friday — แอป menu bar (ไม่มีไอคอนใน Dock)
/// เมนูบาร์: สถานะ + คุย/หยุด + แสดงหน้าต่าง + ปิดหู · friday://  = เรียกคุย · ⌥⌘F = คีย์ลัดเรียกคุย
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = FridayController()
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()
        updateIcon(.starting)

        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 440),
                        styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView, .utilityWindow],
                        backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: PanelView(c: controller))
        placePanel()

        controller.onPhaseChanged = { [weak self] p in self?.updateIcon(p); self?.buildMenu() }
        controller.onWantsPanel = { [weak self] show in self?.showPanel(show) }
        controller.start()

        // friday://  (Shortcut "Friday" บน Mac / หูเบื้องหลังของ server) → เรียกคุย
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        hotKey = HotKey(keyCode: 3 /* F */, modifiers: [.command, .option]) { [weak self] in self?.summon() }
    }

    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) { summon() }

    /// ปิด Friday (เมนู / ⌘Q) → ปล่อยไมค์ + ปิดหูสำรองของ server ด้วย ไมค์จะไม่ถูกใช้เลยจนกว่าจะเปิดแอปใหม่
    func applicationWillTerminate(_ n: Notification) { controller.shutdown() }

    /// เปิดแอปซ้ำ (Spotlight / Dock / open -a Friday) → เรียกคุย
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { summon(); return false }

    private func summon() {
        if controller.earMuted { controller.setEarMuted(false) }   // เรียกเอง = เปิดหูคืน
        showPanel(true)
        if controller.phase == .sleeping { controller.wake(prebuffer: [], greet: true) }
    }

    private func placePanel() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: screen.maxX - 380, y: screen.maxY - 460))
    }

    private func showPanel(_ show: Bool) {
        if show { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
    }

    private func updateIcon(_ p: FridayController.Phase) {
        let name: String
        switch p {
        case .live: name = "waveform.circle.fill"
        case .connecting: name = "ellipsis.circle.fill"
        case .error: name = "exclamationmark.circle"
        default: name = controller.earMuted ? "mic.slash.circle" : "circle.circle"
        }
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Friday")
    }

    private func buildMenu() {
        let m = NSMenu()
        let talking = controller.phase == .live || controller.phase == .connecting
        m.addItem(withTitle: talking ? "หยุดคุย" : "คุยกับ Friday  (⌥⌘F)", action: #selector(toggleTalk), keyEquivalent: "").target = self
        m.addItem(withTitle: "แสดงหน้าต่าง", action: #selector(showWindow), keyEquivalent: "").target = self
        m.addItem(.separator())
        for line in ["🔊 \(controller.outputName.isEmpty ? "-" : controller.outputName)", "🎤 \(controller.inputName.isEmpty ? "-" : controller.inputName)"] {
            let it = NSMenuItem(title: line, action: nil, keyEquivalent: ""); it.isEnabled = false; m.addItem(it)
        }
        m.addItem(.separator())
        m.addItem(withTitle: controller.earMuted ? "เปิดหู (ฟังคำปลุก)" : "ปิดหู (ไม่ฟังคำปลุก)", action: #selector(toggleEar), keyEquivalent: "").target = self
        m.addItem(withTitle: "เปิด log", action: #selector(openLog), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "ปิด Friday", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = m
    }

    @objc private func toggleTalk() { showPanel(true); controller.toggle() }
    @objc private func showWindow() { showPanel(true) }
    @objc private func toggleEar() { controller.toggleEar() }
    @objc private func openLog() { NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/logs/friday.log")) }
}

/// จุดเข้าของ FridayCore.dylib — ตัวเปิดแอป (Launcher) โหลด dylib นี้แล้วเรียกฟังก์ชันนี้
/// แยกแบบนี้เพื่อให้ตัวแอปที่ macOS ผูกสิทธิ์ไมค์ไว้ไม่เปลี่ยน → build ใหม่ไม่ต้องกด Allow ซ้ำ
@_cdecl("friday_main")
public func fridayMain() {
    MainActor.assumeIsolated {
        if CommandLine.arguments.contains("--selftest") { SelfTest.run(); RunLoop.main.run() }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
