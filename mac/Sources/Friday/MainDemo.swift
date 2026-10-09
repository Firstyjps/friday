import AppKit

/// `Friday --main-demo [dir]` — เปิดหน้าต่างหลักกับข้อมูลจริงจาก server โดยไม่เริ่มไมค์/คำปลุก
/// ใส่ dir = ถ่ายภาพทุกหน้าเป็น PNG (ไว้ตรวจดีไซน์) แล้วปิดเอง
@MainActor
enum MainDemo {
    static var keep: MainWindowController?

    static func run(out: String?) {
        T.registerFonts()
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let w = MainWindowController(controller: FridayController())
        keep = w
        w.window.setContentSize(NSSize(width: 1280, height: 860))
        w.window.center()
        w.show(.home)
        guard let out else { return }
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            for p in MainUI.Page.allCases {
                w.ui.page = p
                if p == .tasks { w.ui.openTask = w.ui.tasks.first?.id }
                if p == .history { w.ui.openSession = w.ui.sessions.first?.start }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                w.window.contentView?.layoutSubtreeIfNeeded(); w.window.displayIfNeeded()
                snap(w.window, to: "\(out)/\(p.rawValue).png")
            }
            exit(0)
        }
    }

    static func snap(_ win: NSWindow, to path: String) {
        guard let v = win.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
