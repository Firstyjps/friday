import AppKit
import SwiftUI

/// `--overlay-demo` — เล่น Edge Wave overlay ทุกสถานะด้วยข้อมูลจำลอง (ไม่ต่อไมค์/server/Gemini)
/// ไว้ดู/ปรับดีไซน์: พัก → ปลุก → ฟัง → พูด → งาน → ยืนยัน → เสร็จ → ปิดไมค์ → วนใหม่
/// FRIDAY_DEMO_MODE=confirm (ชื่อสถานะ) = ค้างสถานะเดียว
@MainActor
enum OverlayDemo {
    private static let user = "ย้ายไฟล์ PDF ใน Downloads ไป Documents ให้หน่อย"
    private static let fri = "ได้ค่ะ เดี๋ยวให้ Mac หาไฟล์ก่อนนะคะ ถ้าจะย้ายจริงขอยืนยันอีกทีค่ะ"
    private static var keep: [AnyObject] = []

    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let c = FridayController(), ui = OverlayUI()
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1470, height: 920)
        let w = OverlayPanel(contentRect: NSRect(x: screen.maxX - OverlayView.width, y: screen.minY, width: OverlayView.width, height: screen.height),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false
        w.level = .floating; w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        w.contentView = NSHostingView(rootView: OverlayView(c: c, ui: ui))
        ui.windowFrame = w.frame; ui.visible = true
        w.orderFrontRegardless()
        print("overlay-demo window=\(w.windowNumber) frame=\(w.frame)")
        keep = [c, ui, w]

        // ระดับเสียงจำลอง (เหมือนเดโม HTML: กระตุกเป็นพยางค์)
        Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { _ in
            MainActor.assumeIsolated {
                let v = Double.random(in: 0...1) < 0.8 ? Double.random(in: 1250...2500) : 250
                if c.speaking { c.outLevel = v } else { c.micLevel = v }
            }
        }

        let only = ProcessInfo.processInfo.environment["FRIDAY_DEMO_MODE"]
        func reset() {
            c.phase = .live; c.speaking = false; c.micMuted = false; c.lastMe = ""; c.lastFri = ""
            c.activeJobs = 0; c.pendingConfirm = nil; c.resultLine = ""; c.wokeAt = nil; c.doneAt = nil
        }
        func show(_ m: OverlayView.Mode) {
            reset()
            switch m {
            case .sleep: c.phase = .sleeping
            case .wake: c.phase = .connecting; c.wokeAt = Date()
            case .listen: c.lastMe = user
            case .speak: c.lastMe = user; c.lastFri = fri; c.speaking = true
            case .job: c.lastMe = user; c.lastFri = fri; c.jobTask = "หาไฟล์ PDF ใน Downloads"; c.activeJobs = 1
            case .confirm: c.pendingConfirm = .init(jobId: "demo", task: "ย้ายไฟล์ PDF 12 ไฟล์ใน Downloads ไป Documents",
                                                    reason: "รันคำสั่ง: mv ~/Downloads/*.pdf ~/Documents/PDF/", at: Date())
            case .done: c.lastMe = user; c.lastFri = fri; c.doneText = "ย้าย 12 ไฟล์ไป Documents/PDF แล้ว"; c.doneAt = Date()
            case .muted: c.lastMe = user; c.micMuted = true
            }
            print("mode: \(m)")
        }
        if let only, let m = [OverlayView.Mode.sleep, .wake, .listen, .speak, .job, .confirm, .done, .muted].first(where: { "\($0)" == only }) {
            show(m)
            if m == .wake || m == .done {             // one-shot → เล่นซ้ำทุก 3 วิ
                Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in MainActor.assumeIsolated { show(m) } }
            }
            return
        }
        let steps: [(OverlayView.Mode, Double)] = [(.sleep, 1.2), (.wake, 0.9), (.listen, 3), (.speak, 3.6), (.job, 2.6), (.confirm, 4), (.done, 2.6), (.muted, 2.4)]
        var i = 0
        func next() {
            let (m, d) = steps[i % steps.count]
            show(m); i += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { next() }
        }
        next()
    }
}
