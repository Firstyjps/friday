import AppKit
import Combine
import SwiftUI

/// Friday — แอป menu bar (ไม่มีไอคอนใน Dock)
/// เมนูบาร์: สถานะ + คุย/หยุด + แสดงหน้าต่าง + ปิดหู · friday://  = เรียกคุย · ⌥⌘F = คีย์ลัดเรียกคุย
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = FridayController()
    private var statusItem: NSStatusItem!
    private var mainWindow: MainWindowController?   // หน้าต่างหลัก (ดูข้อมูล/ตั้งค่า) — สร้างตอนเปิดครั้งแรก
    private var overlay: OverlayPanel!   // Edge Wave overlay ขอบขวาของจอ (โผล่เฉพาะตอนคุย)
    private let overlayUI = OverlayUI()
    private var mouseTimer: Timer?
    private var keyMonitor: Any?
    private var confirmSub: AnyCancellable?
    private var hotKey: HotKey?
    private var jobSub: AnyCancellable?

    func applicationDidFinishLaunching(_ n: Notification) {
        T.registerFonts()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()
        updateIcon(.starting)
        jobSub = controller.$activeJobs.map { $0 > 0 }.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { guard let self else { return }; self.updateIcon(self.controller.phase) }
        }

        overlay = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: OverlayView.width, height: 600),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false                       // ม่าน/แสงวาดใน SwiftUI
        overlay.isFloatingPanel = true
        overlay.level = .floating
        overlay.hidesOnDeactivate = false
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        overlay.ignoresMouseEvents = true               // พื้นที่โปร่ง/ม่านต้องคลิกทะลุ — เปิดรับคลิกเฉพาะตอนเมาส์อยู่บนแผง (ดู trackMouse)
        overlay.contentView = NSHostingView(rootView: OverlayView(c: controller, ui: overlayUI))
        // ↩ = ยืนยัน · esc = ยกเลิก — เฉพาะตอนแผงยืนยันเป็น key (ผู้ใช้คลิกที่แผงแล้ว) ไม่ดักคีย์ทั้งระบบ กันกด Enter ในแอปอื่นแล้วเผลอยืนยัน
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self.overlay, let p = self.controller.pendingConfirm else { return e }
            switch e.keyCode {
            case 36, 76: Task { await self.controller.decide(p.jobId, approve: true, via: "ปุ่ม") }
            case 53: Task { await self.controller.decide(p.jobId, approve: false, via: "ปุ่ม") }
            default: return e
            }
            return nil
        }
        confirmSub = controller.$pendingConfirm.map { $0 != nil }.removeDuplicates().sink { [weak self] on in
            guard let self else { return }
            self.overlay.allowKey = on
            if !on, self.overlay.isKeyWindow { NSWorkspace.shared.frontmostApplication?.activate() }   // คืนคีย์บอร์ดให้แอปที่ใช้อยู่
        }

        controller.onPhaseChanged = { [weak self] p in self?.updateIcon(p); self?.buildMenu() }
        controller.onWantsPanel = { [weak self] show in self?.showOverlay(show) }
        controller.start()

        // friday://  (Shortcut "Friday" บน Mac / หูเบื้องหลังของ server) → เรียกคุย
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        hotKey = HotKey(keyCode: 3 /* F */, modifiers: [.command, .option]) { [weak self] in self?.summon() }
    }

    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) { summon() }

    /// ปิด Friday (เมนู / ⌘Q) → ปล่อยไมค์ + ปิดหูสำรองของ server ด้วย ไมค์จะไม่ถูกใช้เลยจนกว่าจะเปิดแอปใหม่
    func applicationWillTerminate(_ n: Notification) { controller.shutdown() }
    @objc func quitFromMenu() { Log.write("quit: เมนู ปิด Friday / ⌘Q"); NSApp.terminate(nil) }
    /// ปิดจากที่อื่น (ระบบ/logout/osascript) จะไม่มีบรรทัด quit: ก่อน "ปล่อยไมค์" — ไว้แยกสาเหตุแอปปิดเอง

    /// เปิดแอปซ้ำ (Spotlight / Dock / open -a Friday) → เรียกคุย
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { summon(); return false }

    private func summon() {
        if controller.earMuted { controller.setEarMuted(false) }   // เรียกเอง = เปิดหูคืน
        showOverlay(true)
        if controller.phase == .sleeping { controller.wake(prebuffer: [], greet: true) }
    }

    func openMain(_ page: MainUI.Page? = nil) {
        if mainWindow == nil { mainWindow = MainWindowController(controller: controller) }
        mainWindow?.show(page)
    }

    /// overlay: ชิดขอบขวาของจอหลัก กว้าง 560 สูงเต็ม visibleFrame (ใต้ menu bar) — เนื้อหาอยู่กลางแนวตั้ง
    private func showOverlay(_ show: Bool) {
        if show {
            if let screen = NSScreen.main?.visibleFrame {
                overlay.setFrame(NSRect(x: screen.maxX - OverlayView.width, y: screen.minY, width: OverlayView.width, height: screen.height), display: true)
            }
            overlayUI.windowFrame = overlay.frame
            overlay.orderFrontRegardless()
            if mouseTimer == nil {
                mouseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.trackMouse() }
                }
            }
        } else {
            overlay.orderOut(nil)
            mouseTimer?.invalidate(); mouseTimer = nil
            overlay.ignoresMouseEvents = true
        }
        if overlayUI.visible != show { overlayUI.visible = show }
    }

    /// รับคลิกเฉพาะตอนเมาส์อยู่บนแผงที่โชว์อยู่ — ที่เหลือคลิกทะลุไปแอปข้างใต้ (ม่านไม่บังการใช้งาน)
    private func trackMouse() {
        let r = overlayUI.panelRect, f = overlay.frame
        let onPanel = !r.isEmpty && NSRect(x: f.minX + r.minX, y: f.maxY - r.maxY, width: r.width, height: r.height)
            .insetBy(dx: -8, dy: -8).contains(NSEvent.mouseLocation)
        if overlay.ignoresMouseEvents == onPanel { overlay.ignoresMouseEvents = !onPanel }
        if !onPanel, overlayUI.hover != nil { overlayUI.hover = nil }
    }

    /// ไอคอนเมนูบาร์ = Fri the Fox (template): ตาเปิด = คุยอยู่ · เหลือบข้าง = กำลังคิด/ทำงาน · หลับ = รอคำปลุก · จาง = ปิดหู
    private func updateIcon(_ p: FridayController.Phase) {
        let img: NSImage?
        switch p {
        case .error: img = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: "Friday")
        case .live: img = Fox.menuBarImage(mood: controller.activeJobs > 0 ? .thinking : .listening)
        case .connecting: img = Fox.menuBarImage(mood: .thinking)
        default: img = Fox.menuBarImage(mood: controller.activeJobs > 0 ? .thinking : .sleeping, dim: controller.earMuted || p == .starting)
        }
        statusItem.button?.image = img
    }

    private func buildMenu() {
        let m = NSMenu()
        let talking = controller.phase == .live || controller.phase == .connecting
        m.addItem(withTitle: talking ? "หยุดคุย" : "คุยกับ Friday  (⌥⌘F)", action: #selector(toggleTalk), keyEquivalent: "").target = self
        if talking { m.addItem(withTitle: controller.micMuted ? "เปิดไมค์" : "ปิดไมค์ชั่วคราว", action: #selector(toggleMic), keyEquivalent: "").target = self }
        m.addItem(withTitle: "Open Friday…", action: #selector(showWindow), keyEquivalent: "o").target = self
        m.addItem(.separator())
        for line in ["🔊 \(controller.outputName.isEmpty ? "-" : controller.outputName)", "🎤 \(controller.inputName.isEmpty ? "-" : controller.inputName)", "💰 \(controller.usageLine.isEmpty ? "-" : controller.usageLine)"] {
            let it = NSMenuItem(title: line, action: nil, keyEquivalent: ""); it.isEnabled = false; m.addItem(it)
        }
        m.addItem(.separator())
        m.addItem(withTitle: controller.earMuted ? "เปิดหู (ฟังคำปลุก)" : "ปิดหู (ไม่ฟังคำปลุก)", action: #selector(toggleEar), keyEquivalent: "").target = self
        m.addItem(withTitle: "เปิด log", action: #selector(openLog), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "ปิด Friday", action: #selector(AppDelegate.quitFromMenu), keyEquivalent: "q").target = self
        statusItem.menu = m
    }

    @objc private func toggleTalk() { showOverlay(true); controller.toggle() }
    @objc private func showWindow() { openMain() }
    @objc private func toggleMic() { controller.toggleMic() }
    @objc private func toggleEar() { controller.toggleEar() }
    @objc private func openLog() { NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/logs/friday.log")) }
}

/// จุดเข้าของ FridayCore.dylib — ตัวเปิดแอป (Launcher) โหลด dylib นี้แล้วเรียกฟังก์ชันนี้
/// แยกแบบนี้เพื่อให้ตัวแอปที่ macOS ผูกสิทธิ์ไมค์ไว้ไม่เปลี่ยน → build ใหม่ไม่ต้องกด Allow ซ้ำ
@_cdecl("friday_main")
public func fridayMain() {
    MainActor.assumeIsolated {
        if CommandLine.arguments.contains("--selftest") { SelfTest.run(); RunLoop.main.run() }
        if CommandLine.arguments.contains("--overlay-demo") { OverlayDemo.run(); NSApplication.shared.run() }
        if let i = CommandLine.arguments.firstIndex(of: "--make-iconset"), i + 1 < CommandLine.arguments.count {   // build.sh: ไอคอนแอปจิ้งจอก
            exit(Fox.writeIconset(to: CommandLine.arguments[i + 1]) ? 0 : 1)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--main-demo") {   // เปิดหน้าต่างหลักอย่างเดียว (ไม่เปิดไมค์) · ใส่โฟลเดอร์ = ถ่ายภาพทุกหน้าแล้วปิด
            MainDemo.run(out: i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : nil); NSApplication.shared.run()
        }
        if CommandLine.arguments.contains("--vp-test") { NSApplication.shared.setActivationPolicy(.accessory); VPTest.run(); NSApplication.shared.run() }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

/// overlay เป็น key ได้เฉพาะตอนมีแผงยืนยัน (ให้ ↩/esc ใช้ได้หลังคลิกแผง) — ปกติกดปุ่มแล้วไม่แย่งคีย์บอร์ดจากแอปที่ใช้อยู่
final class OverlayPanel: NSPanel {
    var allowKey = false
    override var canBecomeKey: Bool { allowKey }
}
