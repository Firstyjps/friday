import AppKit
import Combine
import SwiftUI

/// สถานะของหน้าต่างหลัก (ไม่มี @State เพราะ build ด้วย Command Line Tools — เก็บทุกอย่างใน ObservableObject แบบ OverlayUI)
@MainActor
final class MainUI: ObservableObject {
    enum Page: String, CaseIterable { case home, tasks, history, usage, memory, vault, tools, system, settings, help }

    @Published var page: Page = .home { didSet { if page != oldValue { pageChanged() } } }
    @Published var hover: String?
    @Published var openTask: String?
    @Published var openSession: Double?
    @Published var taskFilter = "all"
    @Published var range = "week"
    @Published var addingNote = false
    @Published var noteDraft = ""
    @Published var countUpAt = Date()           // ตัวเลข "Spent this month" นับขึ้นจาก 0 (1.1 วิ)
    @Published var barsAt = Date()              // แท่งกราฟงอกขึ้น

    @Published var tasks: [TaskItem] = []
    @Published var sessions: [ChatSession] = []
    @Published var usage: UsageReport?
    @Published var notes: [MemoryNote] = []
    @Published var projects: [VaultProject] = []
    @Published var vaultExclude = "secret|password|credential|wallet|private-key"
    @Published var settings: AppSettings?
    @Published var system: SystemInfo?
    @Published var offline = false
    @Published var restartingAt: Date?

    private var timer: Timer?
    var visible = false

    // ---------- โหลดข้อมูล ----------
    func appear() {
        visible = true
        replayCountUp()
        Task { await refreshAll() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { guard let self, self.visible else { return }; Task { await self.refreshLive() } }
        }
    }
    func disappear() { visible = false; timer?.invalidate(); timer = nil }

    func refreshAll() async {
        async let t: () = loadTasks(); async let h: () = loadHistory(); async let u: () = loadUsage()
        async let m: () = loadMemory(); async let v: () = loadVault(); async let s: () = loadSettings(); async let y: () = loadSystem()
        _ = await (t, h, u, m, v, s, y)
    }

    /// ทุก 4 วิ: งาน + สถานะระบบ (ที่เปลี่ยนเร็ว) · หน้าอื่นโหลดใหม่ตอนเปิดหน้า
    private func refreshLive() async {
        await loadTasks(); await loadSystem()
        if page == .home { await loadUsage() }
    }

    private func pageChanged() {
        hover = nil; addingNote = false
        if page == .home || page == .usage { replayCountUp() }
        Task {
            switch page {
            case .home: await loadUsage(); await loadHistory()
            case .tasks: await loadTasks()
            case .history: await loadHistory()
            case .usage: await loadUsage()
            case .memory: await loadMemory()
            case .vault: await loadVault()
            case .tools, .settings: await loadSettings()
            case .system: await loadSystem()
            case .help: break
            }
        }
    }

    func replayCountUp() {
        countUpAt = Date(); barsAt = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in self?.objectWillChange.send() }   // ให้ TimelineView หยุดหลังจบแอนิเมชัน
    }

    private func load<T: Decodable>(_ path: String, _ apply: (T) -> Void) async {
        do { apply(try await ServerAPI.app(path)); offline = false }
        catch { if !(error is DecodingError) { offline = true } else { Log.write("window: อ่าน \(path) ไม่ได้ \(error)") } }
    }
    func loadTasks() async { await load("tasks") { (r: TasksResponse) in if r.tasks != tasks { tasks = r.tasks } } }
    func loadHistory() async { await load("history") { (r: HistoryResponse) in sessions = r.sessions } }
    func loadUsage() async { await load("usage") { (r: UsageReport) in usage = r } }
    func loadMemory() async { await load("memory") { (r: MemoryResponse) in notes = r.notes } }
    func loadVault() async { await load("vault") { (r: VaultResponse) in projects = r.projects; vaultExclude = r.exclude } }
    func loadSettings() async { await load("settings") { (r: AppSettings) in settings = r } }
    func loadSystem() async { await load("system") { (r: SystemInfo) in system = r } }

    // ---------- การกระทำ ----------
    func forget(_ n: MemoryNote) {
        withAnimation(.easeOut(duration: 0.2)) { notes.removeAll { $0.line == n.line } }
        Task { await ServerAPI.appPost("memory/forget", json: ["line": n.line]); await loadMemory() }
    }
    func addNote() {
        let t = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        addingNote = false; noteDraft = ""
        guard !t.isEmpty else { return }
        Task { await ServerAPI.appPost("memory/add", json: ["note": t]); await loadMemory() }
    }
    func set(_ body: [String: Any]) {
        Task { await ServerAPI.appPost("settings", json: body); await loadSettings() }
    }
    func toggleTool(_ name: String) {
        guard var s = settings else { return }
        let on = s.toolsOff.contains(name)
        if on { s.toolsOff.removeAll { $0 == name } } else { s.toolsOff.append(name) }
        settings = s                                     // เปลี่ยนสวิตช์ทันที แล้วค่อยบันทึก
        set(["tool": name, "on": on])
    }
    func toggleShortcut(_ name: String) {
        guard var s = settings, let i = s.shortcuts.firstIndex(where: { $0.name == name }) else { return }
        s.shortcuts[i].on.toggle(); settings = s
        set(["shortcut": name, "on": s.shortcuts[i].on])
    }
    func restartServer() {
        restartingAt = Date()
        Task {
            await ServerAPI.appPost("restart", json: [:])
            try? await Task.sleep(nanoseconds: 12_000_000_000)   // LaunchAgent เปิดใหม่ภายใน ~10 วิ
            restartingAt = nil
            await refreshAll()
        }
    }
}

// ---------- ข้อมูลจาก server (/api/app/*) ----------

struct TasksResponse: Decodable { let tasks: [TaskItem] }
struct TaskItem: Decodable, Identifiable, Equatable {
    let id: String
    let tool: String?
    let via: String?
    let task: String
    let status: String
    let result: String?
    let reason: String?
    let cmd: String?
    let startedAt: Double
    let endedAt: Double?
    let origin: String?

    var date: Date { Date(timeIntervalSince1970: startedAt / 1000) }
    /// pending | running | done | cancelled | error
    var kind: String {
        switch status {
        case "needs_confirmation": return "pending"
        case "running", "new": return "running"
        case "done": return "done"
        case "cancelled": return "cancelled"
        default: return "error"
        }
    }
}

struct HistoryResponse: Decodable { let sessions: [ChatSession] }
struct ChatSession: Decodable, Identifiable {
    struct Line: Decodable { let who: String; let text: String }
    let start: Double
    let end: Double
    let homepod: Bool
    let lines: [Line]
    let tasks: Int
    var id: Double { start }
    var startDate: Date { Date(timeIntervalSince1970: start / 1000) }
    var title: String { lines.first { $0.who == "you" }?.text ?? lines.first?.text ?? "" }
}

struct UsageReport: Decodable {
    struct Bar: Decodable { let label: String; let thb: Double }
    struct Week: Decodable { let bars: [Bar]; let thb: Double; let minutes: Int; let busiest: String? }
    struct Parts: Decodable { let voiceOut: Double; let voiceIn: Double; let textOut: Double; let textIn: Double }
    struct Top: Decodable { let n: String; let c: Int }
    let monthName: String
    let monthShort: String
    let daysInMonth: Int
    let dayOfMonth: Int
    let monthThb: Double
    let todayThb: Double
    let avgThb: Double
    let projectedThb: Double
    let daysMtd: [Double]
    let todayMinutes: Int
    let week: Week
    let monthBars: [Bar]
    let monthConversations: Int
    let parts: Parts
    let tops: [Top]
}

struct MemoryResponse: Decodable { let notes: [MemoryNote] }
struct MemoryNote: Decodable, Identifiable { let id: Int; let line: String; let date: String?; let text: String }

struct VaultResponse: Decodable { let projects: [VaultProject]; let exclude: String }
struct VaultProject: Decodable, Identifiable {
    let name: String
    let status: String?
    let protected: Bool
    let progress: Double?
    let updatedAt: Double
    var id: String { name }
}

struct AppSettings: Decodable {
    struct Shortcut: Decodable { let name: String; var on: Bool }
    let trust: String
    let engine: String
    let idleMs: Double
    let maxSessionSec: Double
    let voice: String
    var toolsOff: [String]
    let uses: [String: Int]
    let homepod: String?
    var shortcuts: [Shortcut]
}

struct SystemInfo: Decodable {
    struct Server: Decodable { let uptimeSec: Double; let port: Int }
    struct Whisper: Decodable { let up: Bool; let pingMs: Double; let checkMs: Double? }
    struct Agent: Decodable { let sessions: Int; let running: Int; let waiting: Int }
    struct Gemini: Decodable { let keySet: Bool; let model: String?; let engine: String; let tokenMs: Double? }
    struct Ear: Decodable { let enabled: Bool; let state: String; let appListening: Bool }
    struct LogLine: Decodable { let time: String; let tag: String; let msg: String }
    let server: Server
    let whisper: Whisper
    let agent: Agent
    let gemini: Gemini
    let ear: Ear
    let log: [LogLine]
}
