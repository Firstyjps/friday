import AppKit
import SwiftUI

// หน้าต่างๆ ในหน้าต่างหลัก — UI ภาษาอังกฤษ ส่วนข้อมูลของผู้ใช้ (ชื่องาน/บทสนทนา/ความจำ) คงภาษาที่ Friday บันทึกไว้

// ---------- ตัวช่วยร่วม ----------

enum Fmt {
    static let en = Locale(identifier: "en_US")
    static func baht(_ v: Double) -> String {
        if v <= 0 { return "฿0" }
        if v < 10 { return String(format: "฿%.2f", v) }
        if v < 100 { let s = String(format: "%.1f", v); return "฿" + (s.hasSuffix(".0") ? String(s.dropLast(2)) : s) }
        let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 0
        return "฿" + (f.string(from: NSNumber(value: v.rounded())) ?? "\(Int(v))")
    }
    static func time(_ d: Date) -> String { let f = DateFormatter(); f.locale = en; f.dateFormat = "h:mm a"; return f.string(from: d) }
    static func day(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        let f = DateFormatter(); f.locale = en; f.dateFormat = "EEEE, MMM d"; return f.string(from: d)
    }
    /// เวลาในแถวงาน: วันนี้ = 2:03 PM · เมื่อวาน = Yesterday · ก่อนนั้น = Oct 3
    static func when(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return time(d) }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return short(d)
    }
    static func short(_ d: Date) -> String { let f = DateFormatter(); f.locale = en; f.dateFormat = "MMM d"; return f.string(from: d) }
    static func ago(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Updated today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day ?? 0
        if days < 14 { return "\(days) days ago" }
        if days < 60 { return "\(days / 7) weeks ago" }
        return short(d)
    }
    static func minutes(_ m: Int) -> String { m < 60 ? "\(m) minute\(m == 1 ? "" : "s")" : "\(m / 60) h \(m % 60) min" }
    static func duration(_ sec: Double) -> String { sec < 60 ? "<1 min" : "\(Int((sec / 60).rounded())) min" }
    static func uptime(_ s: Double) -> String {
        let m = Int(s) / 60, h = m / 60, d = h / 24
        return d > 0 ? "up \(d) day\(d == 1 ? "" : "s") \(h % 24) h" : h > 0 ? "up \(h) h \(m % 60) min" : "up \(m) min"
    }
    static func plural(_ n: Int, _ w: String) -> String { "\(n) \(w)\(n == 1 ? "" : "s")" }
}

/// สีตามสถานะงาน: ข้อความ / พื้นไทล์
enum TaskStyle {
    static func of(_ kind: String) -> (label: String, fg: Color, bg: Color) {
        switch kind {
        case "pending": return ("Needs you", T.pending, T.accentTint)
        case "running": return ("Running", T.running, T.runningBg)
        case "done": return ("Done", T.success, T.successBg)
        case "cancelled": return ("Denied", T.faint, T.divider)
        default: return ("Failed", T.error, T.errorBg)
        }
    }
}

struct TaskIcon: View {
    let kind: String
    var body: some View {
        let s = TaskStyle.of(kind)
        Tile(bg: s.bg, fg: s.fg) {
            switch kind {
            case "running": TaskSpinner()
            case "done": Image(systemName: "checkmark").font(.system(size: 14, weight: .bold))
            case "cancelled": Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
            default: Image(systemName: "exclamationmark").font(.system(size: 14, weight: .bold))
            }
        }
    }
}

/// ไทล์คลื่นเสียงส้ม (บทสนทนา)
struct WaveTile: View {
    var body: some View {
        Tile(bg: T.accentTint, fg: T.friday) {
            HStack(spacing: 2.5) {
                ForEach([8.0, 15, 10], id: \.self) { h in RoundedRectangle(cornerRadius: 2).frame(width: 2.5, height: h) }
            }
        }
    }
}

/// แถวในการ์ดแบบรายการ: hover = พื้นจางๆ
struct HoverRow<Content: View>: View {
    @ObservedObject var ui: MainUI
    let id: String
    var vPad: CGFloat = 14
    var action: (() -> Void)? = nil
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 16) { content }
            .padding(.horizontal, 26).padding(.vertical, vPad)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ui.hover == id && action != nil ? T.hover : .clear)
            .contentShape(Rectangle())
            .onHover { inside in if inside { ui.hover = id } else if ui.hover == id { ui.hover = nil } }
            .onTapGesture { action?() }
    }
}

struct TitleMeta: View {
    let title: String
    let meta: String
    var lines = 1
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(T.f(15.5)).lineLimit(lines).truncationMode(.tail)
            Text(meta).font(T.f(13)).foregroundStyle(T.faint).lineLimit(2)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Divided<Content: View>: View {
    let show: Bool
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            content
            if show { Rectangle().fill(T.divider).frame(height: 1) }
        }
    }
}

/// ภาพรวมสุขภาพระบบ (pill หน้า Home / หน้า System): 0 ปกติ · 1 เตือน · 2 มีปัญหา
@MainActor func systemHealth(_ s: SystemInfo?, offline: Bool, c: FridayController) -> (Int, String) {
    if offline { return (2, "Server not responding") }
    guard let s else { return (0, "Checking…") }
    if !s.gemini.keySet { return (2, "Gemini key missing") }
    if !s.whisper.up { return (2, "Whisper is down") }
    if case .error = c.phase { return (1, "Friday.app has a problem") }
    if c.earMuted { return (1, "Not listening") }
    if s.agent.waiting > 0 { return (1, "A task needs you") }
    return (0, "All systems normal")
}

struct HealthPill: View {
    let level: Int
    let text: String
    var body: some View {
        let (fg, bg, dot): (Color, Color, Color) = level == 2 ? (T.error, T.errorBg, T.error) : level == 1 ? (T.warnText, T.warnBg, T.warn) : (T.success, T.successBg, T.successDot)
        HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 7, height: 7)
            Text(text).font(T.f(13, .semibold)).lineLimit(1)
        }
        .foregroundStyle(fg).padding(.horizontal, 12).frame(height: 28)
        .background(Capsule().fill(bg)).fixedSize()
    }
}

struct LinkText: View {
    let text: String
    var weight: Font.Weight = .medium
    let action: () -> Void
    var body: some View {
        Text(text).font(T.f(14, weight)).foregroundStyle(T.accentText).contentShape(Rectangle()).onTapGesture(perform: action)
    }
}

/// จัดชิปให้ขึ้นบรรทัดใหม่เมื่อเต็ม
struct Flow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > w { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing; row = max(row, s.height)
        }
        return CGSize(width: w, height: y + row)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = b.minX, y = b.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > b.minX, x + s.width > b.maxX { x = b.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; row = max(row, s.height)
        }
    }
}

/// ease-out cubic ของแอนิเมชันที่เริ่มเมื่อ `at` (0…1)
func easeOut(_ now: Date, from at: Date, delay: Double = 0, duration: Double) -> Double {
    let k = max(0, min(1, (now.timeIntervalSince(at) - delay) / duration))
    return 1 - pow(1 - k, 3)
}

// ---------- Home ----------

struct HomePage: View {
    @ObservedObject var ui: MainUI
    @ObservedObject var c: FridayController

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SpendCard(ui: ui)
            statusCard
            HStack(alignment: .firstTextBaseline) {
                Text("Lately").font(T.f(17, .semibold))
                Spacer()
                LinkText(text: "See everything") { ui.page = .tasks }
            }.padding(.horizontal, 4).padding(.top, 4)
            lately
        }
    }

    private var todayTasks: [TaskItem] { ui.tasks.filter { Calendar.current.isDateInToday($0.date) } }

    private var statusCard: some View {
        let done = todayTasks.filter { $0.kind == "done" }.count
        let u = ui.usage
        let h = systemHealth(ui.system, offline: ui.offline, c: c)
        return HStack(spacing: 16) {
            sentence("Today Friday finished **\(Fmt.plural(done, "task"))** on your Mac and you talked for **\(Fmt.minutes(u?.todayMinutes ?? 0))** — about **\(Fmt.baht(u?.todayThb ?? 0))** of Gemini.")
                .lineSpacing(4).frame(maxWidth: .infinity, alignment: .leading)
            HealthPill(level: h.0, text: h.1).onTapGesture { ui.page = .system }
        }.card(20, 26)
    }

    private var lately: some View {
        let tasks = Array(todayTasks.prefix(4))
        let convo = ui.sessions.first
        return VStack(spacing: 0) {
            ForEach(tasks) { t in
                let s = TaskStyle.of(t.kind)
                HoverRow(ui: ui, id: "late-\(t.id)", vPad: 12, action: { ui.openTask = t.id; ui.taskFilter = "all"; ui.page = .tasks }) {
                    TaskIcon(kind: t.kind)
                    TitleMeta(title: t.task, meta: "\(s.label) · \(t.via ?? "Claude") · \(Fmt.time(t.date))")
                }
            }
            if let convo {
                HoverRow(ui: ui, id: "late-convo", vPad: 12, action: { ui.openSession = convo.start; ui.page = .history }) {
                    Tile(bg: T.accentTint, fg: T.friday) { Image(systemName: "bubble.left").font(.system(size: 15, weight: .semibold)) }
                    TitleMeta(title: convo.title, meta: "Conversation · \(Fmt.when(convo.startDate)) · \(Fmt.duration((convo.end - convo.start) / 1000))")
                }
            }
            if tasks.isEmpty && convo == nil {
                Text("Nothing yet today. Say “Friday” to get started.").font(T.f(15)).foregroundStyle(T.faint)
                    .padding(.horizontal, 26).padding(.vertical, 14)
            }
        }.card(10)
    }
}

/// การ์ดค่าใช้จ่าย: ตัวเลขนับขึ้น 1.1 วิ + sparkline รายวันงอกขึ้นทีละแท่ง (คลิกตัวเลข = เล่นใหม่)
struct SpendCard: View {
    @ObservedObject var ui: MainUI

    var body: some View {
        let u = ui.usage
        TimelineView(.animation(paused: Date().timeIntervalSince(ui.countUpAt) > 1.3)) { ctx in
            HStack(spacing: 22) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Spent this month").font(T.f(13)).foregroundStyle(T.faint)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("฿").font(T.f(18, .semibold)).foregroundStyle(T.accentText)
                        Text(amount((u?.monthThb ?? 0) * easeOut(ctx.date, from: ui.countUpAt, duration: 1.1)))
                            .font(T.f(32, .bold)).tracking(-1).monospacedDigit()
                    }
                    .contentShape(Rectangle()).onTapGesture { ui.replayCountUp() }
                }.fixedSize()
                spark(u?.daysMtd ?? [], now: ctx.date)
                Rectangle().fill(T.sparkDivider).frame(width: 1, height: 36)
                if let u {
                    sentence("Today **\(Fmt.baht(u.todayThb))** · about **\(Fmt.baht(u.avgThb))** a day · on track for **~\(Fmt.baht(u.projectedThb))** by \(u.monthShort) \(u.daysInMonth)", size: 15, color: T.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else { Spacer() }
                LinkText(text: "Details →", weight: .semibold) { ui.page = .usage }.fixedSize()
            }
        }.card(16, 26)
    }

    private func amount(_ v: Double) -> String { v < 100 ? String(format: v < 10 ? "%.2f" : "%.1f", v) : "\(Int(v.rounded()))" }

    private func spark(_ days: [Double], now: Date) -> some View {
        let mx = max(days.max() ?? 0, 0.01), n = max(days.count, 1)
        let stagger = min(0.06, 0.7 / Double(n))
        return HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(days.enumerated()), id: \.offset) { i, v in
                let e = easeOut(now, from: ui.barsAt, delay: Double(i) * stagger, duration: 0.5)
                RoundedRectangle(cornerRadius: 2).fill(i == days.count - 1 ? T.accent : T.accentLight)
                    .frame(width: 7, height: max(2, v / mx * 36 * e))
            }
        }.frame(height: 36, alignment: .bottom).fixedSize()
    }
}

// ---------- Tasks ----------

struct TasksPage: View {
    @ObservedObject var ui: MainUI
    @ObservedObject var c: FridayController
    static let filters = [("all", "All"), ("pending", "Needs you"), ("running", "Running"), ("done", "Finished")]

    private func match(_ f: String, _ t: TaskItem) -> Bool {
        switch f {
        case "pending", "running": return t.kind == f
        case "done": return ["done", "cancelled", "error"].contains(t.kind)
        default: return true
        }
    }

    var body: some View {
        let list = ui.tasks.filter { match(ui.taskFilter, $0) }
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                ForEach(Self.filters, id: \.0) { k, l in
                    Pill(label: l, count: ui.tasks.filter { match(k, $0) }.count, on: ui.taskFilter == k) { ui.taskFilter = k }
                }
            }
            VStack(spacing: 0) {
                if list.isEmpty {
                    Text(ui.tasks.isEmpty ? "No tasks yet. Ask Friday to do something on your Mac." : "Nothing here right now.")
                        .font(T.f(15)).foregroundStyle(T.faint).padding(.horizontal, 26).padding(.vertical, 14)
                }
                ForEach(Array(list.enumerated()), id: \.element.id) { i, t in
                    Divided(show: i < list.count - 1) { row(t) }
                }
            }.card(8)
        }
    }

    private func row(_ t: TaskItem) -> some View {
        let s = TaskStyle.of(t.kind), open = ui.openTask == t.id
        return VStack(alignment: .leading, spacing: 0) {
            HoverRow(ui: ui, id: "task-\(t.id)", action: { withAnimation(.easeOut(duration: 0.2)) { ui.openTask = open ? nil : t.id } }) {
                TaskIcon(kind: t.kind)
                TitleMeta(title: t.task, meta: "\(t.via ?? "Claude") · \(Fmt.when(t.date))", lines: open ? 3 : 1)
                Text(s.label).font(T.f(13, .semibold)).foregroundStyle(s.fg)
            }
            if open { detail(t).transition(.opacity.combined(with: .move(edge: .top))) }
        }.clipped()
    }

    private func detail(_ t: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let o = t.origin, !o.isEmpty { Text("You said: “\(o)”").font(T.f(14)).foregroundStyle(T.secondary) }
            if let cmd = t.cmd, !cmd.isEmpty {
                Text(cmd).font(T.mono()).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(T.hex(0xF6F3EE)))
            }
            Text(resultText(t)).font(T.f(14)).lineSpacing(5).textSelection(.enabled)
            if t.kind == "pending" {
                HStack(spacing: 18) {
                    LinkText(text: "Approve →", weight: .semibold) { decide(t, true) }
                    Text("Deny").font(T.f(14)).foregroundStyle(T.muted).onTapGesture { decide(t, false) }
                }
            }
        }
        .padding(.leading, 78).padding(.trailing, 26).padding(.bottom, 16)
    }

    private func resultText(_ t: TaskItem) -> String {
        switch t.kind {
        case "pending": return t.reason.map { "Waiting for your OK — \($0)" } ?? "Waiting for your OK before doing anything."
        case "running": return t.result ?? "Working on it…"
        case "cancelled": return t.result == "หมดเวลายืนยัน" ? "Nobody approved it in 5 minutes, so nothing happened." : "You denied it. Nothing was done."
        default: return t.result ?? ""
        }
    }

    /// ถ้า Friday กำลังถามยืนยันงานนี้อยู่ → ผ่าน controller (overlay/เสียงจะรู้ด้วย) ไม่งั้นยิง server ตรง
    private func decide(_ t: TaskItem, _ approve: Bool) {
        Task {
            let r = await c.decide(t.id, approve: approve, via: "ปุ่ม (หน้าต่าง)")
            if (r["result"] as? String) == "ไม่พบงาน" { _ = try? await ServerAPI.confirm(id: t.id, approve: approve) }
            await ui.loadTasks()
        }
    }
}

// ---------- History ----------

struct HistoryPage: View {
    @ObservedObject var ui: MainUI

    var body: some View {
        let groups = Dictionary(grouping: ui.sessions) { Calendar.current.startOfDay(for: $0.startDate) }
        let days = groups.keys.sorted(by: >)
        VStack(alignment: .leading, spacing: 16) {
            if days.isEmpty { Text("No conversations yet.").font(T.f(15)).foregroundStyle(T.faint).padding(.horizontal, 4) }
            ForEach(days, id: \.self) { d in
                VStack(alignment: .leading, spacing: 10) {
                    Text(Fmt.day(d)).font(T.f(17, .semibold)).padding(.horizontal, 4)
                    VStack(spacing: 0) {
                        ForEach(groups[d] ?? []) { s in row(s) }
                    }.card(8)
                }
            }
        }
    }

    private func row(_ s: ChatSession) -> some View {
        let open = ui.openSession == s.start
        let meta = [Fmt.time(s.startDate), Fmt.duration((s.end - s.start) / 1000), Fmt.plural(s.tasks, "task")] + (s.homepod ? ["HomePod"] : [])
        return VStack(alignment: .leading, spacing: 0) {
            HoverRow(ui: ui, id: "c-\(s.start)", action: { withAnimation(.easeOut(duration: 0.2)) { ui.openSession = open ? nil : s.start } }) {
                WaveTile()
                TitleMeta(title: s.title, meta: meta.joined(separator: " · "))
            }
            if open {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(s.lines.enumerated()), id: \.offset) { _, l in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(l.who == "you" ? "You" : "Friday").font(T.f(12.5, .semibold))
                                .foregroundStyle(l.who == "you" ? T.faint : T.friday).frame(width: 52, alignment: .leading)
                            Text(l.text).font(T.f(14.5)).foregroundStyle(T.body).lineSpacing(6).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.leading, 78).padding(.trailing, 26).padding(.bottom, 16)
                .transition(.opacity)
            }
        }.clipped()
    }
}

// ---------- Usage ----------

struct UsagePage: View {
    @ObservedObject var ui: MainUI

    var body: some View {
        if let u = ui.usage {
            VStack(alignment: .leading, spacing: 20) {
                chartCard(u)
                HStack(alignment: .top, spacing: 20) {
                    moneyCard(u)
                    topsCard(u)
                }
            }
        } else {
            Text("Loading…").font(T.f(15)).foregroundStyle(T.faint)
        }
    }

    private func chartCard(_ u: UsageReport) -> some View {
        let week = ui.range == "week"
        let bars = week ? u.week.bars : u.monthBars
        let text = week
            ? "This week you talked for **\(Fmt.minutes(u.week.minutes))** and spent about **\(Fmt.baht(u.week.thb))**." + (u.week.busiest.map { " Busiest day was **\($0)**." } ?? "")
            : "In \(u.monthName) so far you’ve spent about **\(Fmt.baht(u.monthThb))** across **\(Fmt.plural(u.monthConversations, "conversation"))** — on track for **~\(Fmt.baht(u.projectedThb))**."
        let mx = max(bars.map(\.thb).max() ?? 0, 0.01)
        return VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                sentence(text).lineSpacing(4).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Pill(label: "Week", on: week, height: 30) { ui.range = "week"; ui.barsAt = Date(); ui.replayCountUp() }
                    Pill(label: "Month", on: !week, height: 30) { ui.range = "month"; ui.barsAt = Date(); ui.replayCountUp() }
                }
            }
            TimelineView(.animation(paused: Date().timeIntervalSince(ui.barsAt) > 1.3)) { ctx in
                HStack(alignment: .bottom, spacing: 16) {
                    ForEach(Array(bars.enumerated()), id: \.offset) { i, b in
                        let e = easeOut(ctx.date, from: ui.barsAt, delay: Double(i) * 0.06, duration: 0.5)
                        VStack(spacing: 6) {
                            Text(Fmt.baht(b.thb)).font(T.f(11.5)).foregroundStyle(T.faint)
                            UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 2, bottomTrailingRadius: 2, topTrailingRadius: 6)
                                .fill(i == bars.count - 1 ? T.accent : T.accentLight)
                                .frame(height: max(2, b.thb / mx * 140 * e))
                        }.frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 170, alignment: .bottom)
                .padding(.bottom, 4)
                .overlay(alignment: .bottom) { Rectangle().fill(T.hex(0xEEE9E2)).frame(height: 1) }
            }
            HStack(spacing: 16) {
                ForEach(Array(bars.enumerated()), id: \.offset) { _, b in
                    Text(b.label).font(T.f(12)).foregroundStyle(T.faint).frame(maxWidth: .infinity)
                }
            }.padding(.top, -10)
        }.card(22, 26)
    }

    private func moneyCard(_ u: UsageReport) -> some View {
        let p = u.parts
        let rows = [("Voice out", p.voiceOut), ("Voice in", p.voiceIn), ("Text out", p.textOut), ("Text in", p.textIn)]
        let total = max(rows.map(\.1).reduce(0, +), 0.0001)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Where the money goes").font(T.f(16, .semibold))
            ForEach(rows, id: \.0) { n, v in
                HStack(spacing: 12) {
                    Text(n).frame(width: 110, alignment: .leading)
                    Bar(value: v / total)
                    Text(Fmt.baht(v)).foregroundStyle(T.faint).monospacedDigit().frame(width: 56, alignment: .trailing)
                }
            }
            Text("This month. Gemini has no free tier on these models. Prices from config.json → pricing.")
                .font(T.f(12.5)).foregroundStyle(T.faint)
        }.card(20, 26)
    }

    private func topsCard(_ u: UsageReport) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("You ask for these most").font(T.f(16, .semibold)).padding(.bottom, 8)
            if u.tops.isEmpty { Text("Nothing yet.").foregroundStyle(T.faint) }
            ForEach(Array(u.tops.enumerated()), id: \.offset) { i, t in
                HStack(spacing: 12) {
                    Text("\(i + 1)").foregroundStyle(T.placeholder).monospacedDigit().frame(width: 18, alignment: .leading)
                    Text(t.n).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(t.c)×").foregroundStyle(T.faint)
                }
                .frame(height: 36)
                .overlay(alignment: .bottom) { Rectangle().fill(T.divider).frame(height: 1) }
            }
        }.card(20, 26)
    }
}

// ---------- Memory ----------

struct MemoryPage: View {
    @ObservedObject var ui: MainUI

    var body: some View {
        let n = ui.notes.count
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                sentence("Friday remembers **\(Fmt.plural(n, "thing"))** — **\(n) of 60 lines**. Past 60, Claude condenses it to 30 and keeps a backup.")
                    .lineSpacing(4).frame(maxWidth: .infinity, alignment: .leading)
                Bar(value: Double(n) / 60).frame(width: 160)
            }.card(20, 26)
            VStack(spacing: 0) {
                if ui.addingNote {
                    HStack(spacing: 16) {
                        Circle().fill(T.accent).frame(width: 8, height: 8)
                        TextField("Something Friday should keep in mind…", text: $ui.noteDraft)
                            .textFieldStyle(.plain).font(T.f(15.5))
                            .onSubmit { ui.addNote() }
                        Text("Save").font(T.f(13, .semibold)).foregroundStyle(T.accentText).onTapGesture { ui.addNote() }
                        Text("Cancel").font(T.f(13)).foregroundStyle(T.placeholder).onTapGesture { ui.addingNote = false; ui.noteDraft = "" }
                    }
                    .padding(.horizontal, 26).padding(.vertical, 13)
                    .background(T.hover)
                }
                if ui.notes.isEmpty && !ui.addingNote {
                    Text("Nothing yet. Say “จำไว้ว่า…” or use Add note.").font(T.f(15)).foregroundStyle(T.faint).padding(.horizontal, 26).padding(.vertical, 13)
                }
                ForEach(ui.notes) { note in
                    HoverRow(ui: ui, id: "n-\(note.line)", vPad: 13) {
                        Circle().fill(T.accent).frame(width: 8, height: 8)
                        Text(note.text).font(T.f(15.5)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        Text(note.date.flatMap(dateLabel) ?? "").font(T.f(13)).foregroundStyle(T.faint)
                        ForgetButton(ui: ui, id: "f-\(note.line)") { ui.forget(note) }
                    }
                }
            }.card(8)
        }
    }

    private func dateLabel(_ s: String) -> String? {
        let f = DateFormatter(); f.locale = Fmt.en; f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s).map(Fmt.short)
    }
}

struct ForgetButton: View {
    @ObservedObject var ui: MainUI
    let id: String
    let action: () -> Void
    var body: some View {
        Text("Forget").font(T.f(13)).foregroundStyle(ui.hover == id ? T.hex(0xD63C2F) : T.placeholder)
            .onHover { inside in if inside { ui.hover = id } else if ui.hover == id { ui.hover = nil } }
            .onTapGesture(perform: action)
    }
}

// ---------- Vault ----------

struct VaultPage: View {
    @ObservedObject var ui: MainUI
    static let tints: [(Color, Color, Color)] = [(T.accentTint, T.friday, T.accent), (T.runningBg, T.running, T.running), (T.successBg, T.success, T.successDot), (T.divider, T.faint, T.standby)]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(spacing: 0) {
                if ui.projects.isEmpty { Text("No project status files in ~/Vault/10-projects.").font(T.f(15)).foregroundStyle(T.faint).padding(.horizontal, 26).padding(.vertical, 14) }
                ForEach(ui.projects) { row($0) }
            }.card(8)
            (Text("From ~/Vault/10-projects. Files matching ") + Text(ui.vaultExclude).font(T.mono(12.5)) + Text(" or marked ") + Text("friday: false").font(T.mono(12.5)) + Text(" are never sent."))
                .font(T.f(13)).foregroundStyle(T.faint).padding(.horizontal, 4)
        }
    }

    private func row(_ p: VaultProject) -> some View {
        let stale = Date().timeIntervalSince1970 * 1000 - p.updatedAt > 14 * 86400e3
        let tint = p.protected ? (T.errorBg, T.error, T.error) : stale ? Self.tints[3] : Self.tints[abs(p.name.hashValue) % 3]
        return HStack(spacing: 16) {
            Tile(bg: tint.0, fg: tint.1) { Text(p.name.prefix(1).uppercased()).font(T.f(15, .bold)) }
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name).font(T.f(15.5, .medium))
                Text(p.protected ? "Protected — Friday won’t read or touch it" : (p.status ?? "")).font(T.f(13)).foregroundStyle(T.faint).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Bar(value: (p.progress ?? 0) / 100, height: 6, color: tint.2).frame(width: 140).opacity(p.progress == nil && !p.protected ? 0.35 : 1)
            Text(p.protected ? "—" : Fmt.ago(Date(timeIntervalSince1970: p.updatedAt / 1000))).font(T.f(13)).foregroundStyle(T.faint)
                .frame(width: 110, alignment: .trailing)
        }
        .padding(.horizontal, 26).padding(.vertical, 14)
    }
}

// ---------- Tools ----------

struct ToolsPage: View {
    @ObservedObject var ui: MainUI

    var body: some View {
        let s = ui.settings
        let tools: [(String, String, String)] = [
            ("run_on_mac", "Work on your Mac", "Hands the task to Claude Code. Risky steps always ask you first. Always on."),
            ("open_app", "Open apps", "Instant, skips Claude."),
            ("open_url", "Open websites", "Instant, in your default browser."),
            ("system_info", "Mac status", "Date, battery, disk space, uptime."),
            ("run_shortcut", "Home Shortcuts", "Only the ones you allow below."),
            ("announce_homepod", "Speak on HomePod", "Main Bedroom\(s?.homepod.map { ", Thai voice \($0)" } ?? "")."),
            ("remember", "Remember things", "Writes to memory.md."),
            ("vault_lookup", "Look up projects", "Reads your Vault notes."),
        ]
        VStack(alignment: .leading, spacing: 20) {
            SectionLabel(text: "What Friday can do")
            VStack(spacing: 0) {
                ForEach(tools, id: \.0) { n, label, d in
                    let locked = n == "run_on_mac", on = locked || !(s?.toolsOff.contains(n) ?? false)
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            (Text(label).font(T.f(15.5)) + Text("  " + n).font(T.mono(12)).foregroundColor(T.placeholder))
                            Text(d).font(T.f(13)).foregroundStyle(T.faint)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(s?.uses[n] ?? 0) this week").font(T.f(12.5)).foregroundStyle(T.faint)
                        Switch(on: on, locked: locked)
                    }
                    .padding(.horizontal, 26).padding(.vertical, 12)
                    .contentShape(Rectangle())
                    .onTapGesture { if !locked { ui.toggleTool(n) } }
                }
            }.card(8)
            SectionLabel(text: "Home Shortcuts Friday may run")
            VStack(alignment: .leading, spacing: 14) {
                Flow(spacing: 8) {
                    ForEach(s?.shortcuts ?? [], id: \.name) { sc in chip(sc) }
                }
                Text("Names must match Shortcuts.app exactly. Never add ones that send messages or pay for things. Add new names in config.json → shortcutsAllowed.")
                    .font(T.f(13)).foregroundStyle(T.faint)
            }.card(20, 26)
        }
    }

    private func chip(_ sc: AppSettings.Shortcut) -> some View {
        HStack(spacing: 7) {
            Circle().fill(sc.on ? T.accent : T.hex(0xD8D2CA)).frame(width: 7, height: 7)
            Text(sc.name).font(T.f(14))
        }
        .foregroundStyle(sc.on ? T.accentDeep : T.placeholder)
        .padding(.horizontal, 14).frame(height: 34)
        .background(Capsule().fill(sc.on ? T.accentTint : .white)
            .overlay(Capsule().strokeBorder(sc.on ? T.accent.opacity(0.35) : .black.opacity(0.1), lineWidth: 1)))
        .contentShape(Capsule())
        .onTapGesture { ui.toggleShortcut(sc.name) }
        .animation(.easeOut(duration: 0.15), value: sc.on)
    }
}

// ---------- System ----------

struct SystemPage: View {
    @ObservedObject var ui: MainUI
    @ObservedObject var c: FridayController

    /// (ชื่อ, รายละเอียด, ค่า, สถานะ 0 พัก/เทา 1 ปกติ/เขียว 2 เตือน/เหลือง 3 พัง/แดง)
    private var services: [(String, String, String, Int)] {
        let s = ui.system
        var out: [(String, String, String, Int)] = []
        let mic = c.inputName.isEmpty ? "" : " · \(c.inputName)"
        switch c.phase {
        case .error(let e): out.append(("Friday.app", e, "problem", 2))
        case .live, .connecting: out.append(("Friday.app", "Talking with you\(mic)", "in a conversation", 1))
        case .starting: out.append(("Friday.app", "Starting…", "starting", 0))
        case .sleeping: out.append(c.earMuted ? ("Friday.app", "Not listening (you turned it off)", "ear off", 2) : ("Friday.app", "Listening for “Friday”\(mic)", "running", 1))
        }
        guard let s, !ui.offline else {
            out.append(("Server :4850", "localhost:4850 · LaunchAgent com.kron.friday", ui.restartingAt != nil ? "restarting…" : "not responding", ui.restartingAt != nil ? 2 : 3))
            return out
        }
        out.append(("Server :4850", "localhost:4850 · LaunchAgent com.kron.friday", ui.restartingAt != nil ? "restarting…" : Fmt.uptime(s.server.uptimeSec), ui.restartingAt != nil ? 2 : 1))
        out.append(("Whisper :4851", "localhost:4851 · whisper.cpp, Thai · wake word check",
                    s.whisper.up ? (s.whisper.checkMs.map { String(format: "%.1f s per check", $0 / 1000) } ?? "\(Int(s.whisper.pingMs)) ms") : "down", s.whisper.up ? 1 : 3))
        let a = s.agent
        out.append(("Claude Agent", "\(Fmt.plural(a.sessions, "session")) open · no MCP",
                    a.waiting > 0 ? "\(a.waiting) waiting for you" : a.running > 0 ? "\(Fmt.plural(a.running, "task")) running" : "idle", a.waiting > 0 ? 2 : 1))
        out.append(("Gemini", s.gemini.keySet ? "\(s.gemini.model ?? "-") · \(s.gemini.engine)" : "GEMINI_API_KEY missing in .env",
                    s.gemini.tokenMs.map { "\(Int($0)) ms token" } ?? "ready", s.gemini.keySet ? 1 : 3))
        let ear = s.ear
        if !ear.enabled { out.append(("Backup ear", "Turned off (FRIDAY_EAR=0)", "off", 0)) }
        else if ear.state == "listening" { out.append(("Backup ear", "Listening because Friday.app isn’t", "listening", 1)) }
        else if ear.state == "off" { out.append(("Backup ear", "Off until Friday.app opens again", "off", 0)) }
        else { out.append(("Backup ear", "Takes over if Friday.app quits", "standing by", 0)) }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(spacing: 0) {
                ForEach(services, id: \.0) { n, d, v, st in
                    let (dot, halo): (Color, Color) = st == 1 ? (T.successDot, T.successDot.opacity(0.15)) : st == 2 ? (T.warn, T.warn.opacity(0.18)) : st == 3 ? (T.error, T.error.opacity(0.15)) : (T.standby, .black.opacity(0.05))
                    HStack(spacing: 16) {
                        Circle().fill(dot).frame(width: 10, height: 10).background(Circle().fill(halo).frame(width: 18, height: 18))
                        TitleMeta(title: n, meta: d)
                        Text(v).font(T.f(13)).foregroundStyle(T.secondary).monospacedDigit()
                    }.padding(.horizontal, 26).padding(.vertical, 13)
                }
            }.card(8)
            HStack(alignment: .firstTextBaseline) {
                Text("Recent log").font(T.f(17, .semibold))
                Spacer()
                LinkText(text: "Open friday.log") { NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/logs/friday.log")) }
            }.padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array((ui.system?.log ?? []).enumerated()), id: \.offset) { _, l in
                    HStack(spacing: 16) {
                        Text(l.time).foregroundStyle(T.placeholder)
                        Text(tagName(l.tag)).fontWeight(.semibold).foregroundStyle(tagColor(l.tag)).frame(width: 52, alignment: .leading)
                        Text(l.msg).foregroundStyle(T.body).lineLimit(1).truncationMode(.tail)
                    }
                    .font(T.mono(12.5)).frame(height: 30).padding(.horizontal, 26)
                }
            }.card(12)
        }
    }

    private func tagName(_ t: String) -> String { t == "NOWAKE" ? "WAKE" : t }
    private func tagColor(_ t: String) -> Color {
        switch t {
        case "JOB": return T.running
        case "ASK": return T.pending
        case "WAKE": return T.friday
        case "ERR": return T.error
        case "TALK", "POD": return T.secondary
        default: return T.placeholder
        }
    }
}

// ---------- Settings ----------

struct SettingsPage: View {
    @ObservedObject var ui: MainUI
    @ObservedObject var c: FridayController
    static let voices = ["Despina", "Kore", "Aoede", "Leda", "Zephyr"]   // เสียงผู้หญิง (system prompt กำหนดให้ Friday เป็นผู้หญิง)

    var body: some View {
        let s = ui.settings
        VStack(alignment: .leading, spacing: 20) {
            SectionLabel(text: "Listening")
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Listen for “Friday”").font(T.f(15.5))
                        Text("When off, your Mac doesn’t listen at all. ⌥⌘F still works.").font(T.f(13)).foregroundStyle(T.faint)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Switch(on: !c.earMuted)
                }
                .padding(.horizontal, 26).padding(.vertical, 14).contentShape(Rectangle())
                .onTapGesture { c.toggleEar() }
                line("Go back to sleep after silence", value: menu(s.map { "\(Int($0.idleMs / 1000)) seconds" } ?? "–", [10, 20, 30, 60].map { ("\($0) seconds", ["idleMs": $0 * 1000]) }))
                line("Longest single conversation", value: menu(s.map { "\(Int($0.maxSessionSec / 60)) minutes" } ?? "–", [5, 12, 20, 30].map { ("\($0) minutes", ["maxSessionSec": $0 * 60]) }))
            }.card(6)
            SectionLabel(text: "Voice")
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    Text("Friday’s voice").font(T.f(15.5)).frame(maxWidth: .infinity, alignment: .leading)
                    menu(s?.voice ?? "Despina", Self.voices.map { ($0, ["voice": $0]) })
                }.padding(.horizontal, 26).padding(.vertical, 14)
                Rectangle().fill(T.divider).frame(height: 1)
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Engine").font(T.f(15.5))
                        Text(s?.engine == "live" ? "Gemini Live — hears and speaks directly. Fastest." : "Listen → text → speech. Cheaper. Mac only.")
                            .font(T.f(13)).foregroundStyle(T.faint)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 6) {
                        Pill(label: "Live", on: s?.engine == "live", height: 30) { ui.set(["engine": "live"]) }
                        Pill(label: "Cascade", on: s?.engine == "cascade", height: 30) { ui.set(["engine": "cascade"]) }
                    }
                }.padding(.horizontal, 26).padding(.vertical, 12)
            }.card(6)
            SectionLabel(text: "What Claude may do without asking")
            VStack(spacing: 0) {
                ForEach(Array(Self.trusts.enumerated()), id: \.offset) { i, r in
                    let on = s?.trust == r.0
                    VStack(spacing: 0) {
                        if i > 0 { Rectangle().fill(T.divider).frame(height: 1) }
                        HStack(spacing: 16) {
                            Circle().strokeBorder(on ? T.accent : T.hex(0xD8D2CA), lineWidth: on ? 6 : 1.5).frame(width: 20, height: 20)
                                .animation(.easeOut(duration: 0.15), value: on)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.1).font(T.f(15.5, on ? .semibold : .regular))
                                Text(r.2).font(T.f(13)).foregroundStyle(T.faint)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 26).padding(.vertical, 14).contentShape(Rectangle())
                        .onTapGesture { ui.set(["trust": r.0]) }
                    }
                }
            }.card(6)
            Text("At every level Friday still asks before touching secrets (~/.ssh, .env, keys, wallets), and only acts on your own voice.")
                .font(T.f(13)).foregroundStyle(T.faint).padding(.horizontal, 4)
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    static let trusts = [
        ("ask", "Ask every time", "Anything beyond reading needs your OK."),
        ("relaxed", "Relaxed", "Reading, fetching and writing in normal folders are fine. Asks before anything you can’t undo."),
        ("full", "Full", "Almost everything runs. Still asks for sudo, ssh, disks, shutdown and protected paths."),
    ]

    private func line(_ title: String, value: some View) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(T.divider).frame(height: 1)
            HStack(spacing: 16) {
                Text(title).font(T.f(15.5)).frame(maxWidth: .infinity, alignment: .leading)
                value
            }.padding(.horizontal, 26).padding(.vertical, 14)
        }
    }

    private func menu(_ current: String, _ options: [(String, [String: Any])]) -> some View {
        Menu {
            ForEach(options, id: \.0) { label, body in Button(label) { ui.set(body) } }
        } label: {
            Text("\(current) ⌄").font(T.f(14)).foregroundStyle(T.secondary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }
}

// ---------- Help ----------

struct HelpPage: View {
    var body: some View {
        let rows = [("Talk to Friday from anywhere", "⌥⌘F"), ("Open this window", "Menu bar fox → Open Friday… (⌘O)"), ("Stop listening", "say “ปิดไมค์”"),
                    ("End the conversation", "say “บาย” or “พอแล้ว”"), ("Ask from HomePod", "“หวัดดี Siri เลขาส่วนตัว”")]
        VStack(alignment: .leading, spacing: 20) {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                    VStack(spacing: 0) {
                        if i > 0 { Rectangle().fill(T.divider).frame(height: 1) }
                        HStack(spacing: 16) {
                            Text(r.0).font(T.f(15.5)).frame(maxWidth: .infinity, alignment: .leading)
                            Text(r.1).font(T.f(14)).foregroundStyle(T.secondary)
                        }.padding(.horizontal, 26).padding(.vertical, 14)
                    }
                }
            }.card(6)
            HStack(spacing: 14) {
                FoxView(cell: 4, blink: true)
                Text("Fri the Fox is listening when its eyes are open, thinking when it glances aside, and asleep when the ear is off.")
                    .font(T.f(13)).foregroundStyle(T.faint)
            }.padding(.horizontal, 4)
        }
        .frame(maxWidth: 760, alignment: .leading)
    }
}
