import AppKit
import SwiftUI

/// หน้าต่างหลัก Friday.app — ไว้ดูข้อมูล/ตั้งค่า (คุยผ่าน Edge Wave overlay) · เปิดจากเมนูบาร์ "Open Friday…" (⌘O)
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    let ui = MainUI()
    let window: NSWindow
    private let controller: FridayController

    init(controller: FridayController) {
        self.controller = controller
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Friday"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(srgbRed: 0xF3 / 255, green: 0xEF / 255, blue: 0xEA / 255, alpha: 1)
        window.appearance = NSAppearance(named: .aqua)          // ดีไซน์นี้เป็นโทนสว่างอย่างเดียว
        window.minSize = NSSize(width: 1100, height: 720)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("FridayMain")
        window.contentView = NSHostingView(rootView: MainView(ui: ui, c: controller))
        if window.frame.origin == .zero { window.center() }
    }

    func show(_ page: MainUI.Page? = nil) {
        if let page { ui.page = page }
        NSApp.setActivationPolicy(.regular)                     // ระหว่างเปิดหน้าต่าง: มีไอคอนใน Dock + ⌘Tab ได้
        // ไอคอน Dock: แอปเมนูบาร์ (LSUIElement) ที่เพิ่งเปลี่ยนเป็น .regular สร้างช่อง Dock ทีหลัง → ตั้งซ้ำหลังช่องขึ้น ไม่งั้นได้ไอคอน "exec"
        for delay in [0.0, 0.3, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { Self.setDockIcon() }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        ui.appear()
    }

    private static let dockIcon = Fox.appIconImage(px: 1024)
    static func setDockIcon() {
        guard let icon = dockIcon else { return }
        NSApp.applicationIconImage = icon
        NSApp.dockTile.display()
    }

    func windowWillClose(_ n: Notification) {
        ui.disappear()
        NSApp.setActivationPolicy(.accessory)                   // ปิดหน้าต่าง = กลับเป็นแอปเมนูบาร์
    }
}

struct MainView: View {
    @ObservedObject var ui: MainUI
    @ObservedObject var c: FridayController

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Sidebar(ui: ui, pending: pendingCount)
                .frame(width: 234)
                .padding(.top, 64).padding(.bottom, 16)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    PageHeader(ui: ui, c: c)
                    page.frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(EdgeInsets(top: 44, leading: 48, bottom: 48, trailing: 48))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(T.sheet)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.black.opacity(0.06), lineWidth: 0.5)))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.top, 48).padding(.bottom, 12)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(T.window)
        .ignoresSafeArea()
        .foregroundStyle(T.ink)
        .font(T.f(14))
    }

    private var pendingCount: Int { ui.tasks.filter { $0.kind == "pending" }.count }

    @ViewBuilder private var page: some View {
        switch ui.page {
        case .home: HomePage(ui: ui, c: c)
        case .tasks: TasksPage(ui: ui, c: c)
        case .history: HistoryPage(ui: ui)
        case .usage: UsagePage(ui: ui)
        case .memory: MemoryPage(ui: ui)
        case .vault: VaultPage(ui: ui)
        case .tools: ToolsPage(ui: ui)
        case .system: SystemPage(ui: ui, c: c)
        case .settings: SettingsPage(ui: ui, c: c)
        case .help: HelpPage()
        }
    }
}

// ---------- แถบซ้าย ----------

struct Sidebar: View {
    @ObservedObject var ui: MainUI
    let pending: Int
    static let top: [MainUI.Page] = [.home, .tasks, .history, .usage, .memory, .vault, .tools, .system]

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Self.top, id: \.self) { item($0) }
            Spacer(minLength: 12)
            item(.settings)
            item(.help)
        }
    }

    private func item(_ p: MainUI.Page) -> some View {
        let on = ui.page == p
        return HStack(spacing: 12) {
            Image(systemName: Self.icon(p)).font(.system(size: 15, weight: .medium))
                .foregroundStyle(on ? T.navActive : T.navIcon).frame(width: 20, height: 20)
            Text(Self.label(p)).font(T.f(15, on ? .semibold : .regular)).foregroundStyle(T.ink)
            Spacer(minLength: 0)
            if p == .tasks, pending > 0 {
                Text("\(pending)").font(T.f(11.5, .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 6).frame(minWidth: 20, minHeight: 20)
                    .background(Capsule().fill(T.accent))
            }
        }
        .padding(.horizontal, 14).frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on ? Color.white : .clear)
            .shadow(color: .black.opacity(on ? 0.08 : 0), radius: 1.5, y: 1)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.black.opacity(on ? 0.05 : 0), lineWidth: 0.5)))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { ui.page = p } }
    }

    static func label(_ p: MainUI.Page) -> String { p.rawValue.prefix(1).uppercased() + p.rawValue.dropFirst() }
    static func icon(_ p: MainUI.Page) -> String {
        switch p {
        case .home: return "house"
        case .tasks: return "checklist"
        case .history: return "clock"
        case .usage: return "chart.bar"
        case .memory: return "doc.text"
        case .vault: return "folder"
        case .tools: return "wrench.adjustable"
        case .system: return "waveform.path.ecg"
        case .settings: return "gearshape"
        case .help: return "questionmark.circle"
        }
    }
}

// ---------- หัวหน้า ----------

struct PageHeader: View {
    @ObservedObject var ui: MainUI
    @ObservedObject var c: FridayController

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(T.f(32, .bold)).tracking(-0.5).frame(minHeight: 38)
                Text(subtitle).font(T.f(16)).foregroundStyle(T.muted)
            }
            Spacer(minLength: 0)
            if ui.offline {
                Text("Server not responding").font(T.f(13, .semibold)).foregroundStyle(T.error)
                    .padding(.horizontal, 12).frame(height: 28).background(Capsule().fill(T.errorBg))
            }
            if let a = action {
                Text(a.0).font(T.f(14, .medium))
                    .padding(.horizontal, 16).frame(height: 34)
                    .background(Capsule().fill(.white).shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
                        .overlay(Capsule().strokeBorder(.black.opacity(0.1), lineWidth: 0.5)))
                    .contentShape(Capsule())
                    .onTapGesture(perform: a.1)
                    .opacity(ui.restartingAt != nil && ui.page == .system ? 0.5 : 1)
            }
        }
    }

    private var title: String {
        guard ui.page == .home else { return Sidebar.label(ui.page) }
        let h = Calendar.current.component(.hour, from: Date())
        let greet = h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
        let name = NSFullUserName().split(separator: " ").first.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? ""
        return name.isEmpty ? greet : "\(greet), \(name)"
    }

    private var subtitle: String {
        switch ui.page {
        case .home: return "Say “Friday” and talk. It handles the rest on your Mac."
        case .tasks: return "Everything Friday asked your Mac to do."
        case .history: return "Read back any conversation. Friday also reads the last 3 days before each new one."
        case .usage: return "How much you talk to Friday, and what it costs."
        case .memory: return "Things Friday keeps in mind every time you talk."
        case .vault: return "Projects Friday can look up instantly, without asking Claude."
        case .tools: return "Turn individual abilities on or off."
        case .system: return "Everything Friday needs to hear you and get work done."
        case .settings: return "Voice, listening and permissions."
        case .help: return "Things you can say and press."
        }
    }

    private var action: (String, () -> Void)? {
        switch ui.page {
        case .memory: return ("Add note", { ui.addingNote = true })
        case .system: return (ui.restartingAt == nil ? "Restart server" : "Restarting…", { if ui.restartingAt == nil { ui.restartServer() } })
        default: return nil
        }
    }
}
