import AppKit
import SwiftUI

/// Edge Wave overlay: คลื่นเสียงแนวตั้งงอกจากขอบขวาของจอ (กลางแนวตั้ง)
/// เวลา Friday พูด/ทำงาน/ถามยืนยัน → ม่านมืดจางเข้ามาจากขอบขวา ข้อความลอยบนม่าน ไม่มีกรอบ
/// ไม่มี @State (build ด้วย CLT) — สถานะอ่านจาก FridayController · ค่าฝั่ง UI (hover, กรอบแผง, คลื่น) อยู่ใน OverlayUI
struct OverlayView: View {
    @ObservedObject var c: FridayController
    @ObservedObject var ui: OverlayUI
    static let width: CGFloat = 560

    enum Mode: Equatable { case sleep, wake, listen, speak, job, confirm, done, muted }

    /// ลำดับ: ยืนยัน > ปิดไมค์ > ปลุก (0.9 วิ) > เสร็จ (2.6 วิ) > งาน > พูด > ฟัง
    static func mode(_ c: FridayController, now: Date = Date()) -> Mode {
        if c.pendingConfirm != nil { return .confirm }
        let talking = c.phase == .live || c.phase == .connecting
        if talking && c.micMuted { return .muted }
        if let t = c.wokeAt, now.timeIntervalSince(t) < 0.9 { return .wake }
        if let t = c.doneAt, now.timeIntervalSince(t) < 2.6, c.activeJobs == 0 { return .done }
        if c.activeJobs > 0 { return .job }
        guard talking else { return .sleep }
        if c.speaking || !c.lastFri.isEmpty { return .speak }
        return .listen
    }

    // ---------- tokens ----------
    static let ink = Color(red: 10 / 255, green: 11 / 255, blue: 14 / 255)
    static let amber = Color(red: 1, green: 200 / 255, blue: 74 / 255)                   // #ffc84a
    static let lavenderMid = Color(red: 216 / 255, green: 179 / 255, blue: 254 / 255)    // #d8b3fe
    private let ease = Animation.spring(response: 0.6, dampingFraction: 0.88)            // cubic-bezier(.2,.8,.2,1)

    var body: some View {
        let m = Self.mode(c)
        ZStack(alignment: .trailing) {
            curtain(m)
            edgeGlow(m)
            WaveView(c: c, ui: ui).frame(width: 140)
            conversation(m).modifier(PanelSlot(on: [.listen, .speak, .job, .done, .muted].contains(m)))
            confirmPanel.modifier(PanelSlot(on: m == .confirm))
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .coordinateSpace(name: "overlay")
        .onPreferenceChange(PanelRectKey.self) { r in MainActor.assumeIsolated { ui.panelRect = r } }
        .environment(\.colorScheme, .dark)
    }

    // ---------- ม่าน + แสงขอบ ----------
    private func curtain(_ m: Mode) -> some View {
        let op: Double = [.sleep: 0, .wake: 0, .listen: 0.6, .muted: 0.45][m] ?? 1
        return ZStack {
            EdgeBlur().mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.55),
                                                  .init(color: .clear, location: 1)], startPoint: .trailing, endPoint: .leading))
            LinearGradient(stops: [.init(color: Self.ink.opacity(0.92), location: 0),
                                   .init(color: Self.ink.opacity(0.78), location: 0.55),
                                   .init(color: Self.ink.opacity(0), location: 1)],
                           startPoint: .trailing, endPoint: .leading)
        }
        .opacity(op)
        .animation(.easeInOut(duration: 0.7), value: op)
        .allowsHitTesting(false)
    }

    private func edgeGlow(_ m: Mode) -> some View {
        let color = m == .confirm ? Self.amber.opacity(0.16) : Self.lavenderMid.opacity(0.12)
        let op: Double = m == .wake || m == .done ? 1 : m == .sleep ? 0 : 0.5
        return Ellipse()
            .fill(EllipticalGradient(colors: [color, color.opacity(0)], center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5))
            .frame(width: 360, height: 420)
            .offset(x: 180)                           // ครึ่งซ้ายของวงรีโผล่จากขอบจอ = กว้าง 180
            .opacity(op)
            .animation(.easeInOut(duration: 0.6), value: op)
            .animation(.easeInOut(duration: 0.6), value: m == .confirm)
            .allowsHitTesting(false)
    }

    // ---------- แผงบทสนทนา (ฟัง / พูด / งาน / เสร็จ / ปิดไมค์) ----------
    private func conversation(_ m: Mode) -> some View {
        let big = m == .listen || m == .muted
        return VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Text("Friday").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Text(status(m)).font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                Spacer(minLength: 0)
                micButton
            }
            if !c.lastMe.isEmpty {
                Text(c.lastMe)
                    .font(.system(size: big ? 19 : 13, weight: big ? .medium : .regular))
                    .tracking(big ? -0.2 : 0)
                    .lineSpacing(big ? 5 : 3)
                    .foregroundStyle(.white.opacity(big ? 0.88 : 0.45))
                    .fixedSize(horizontal: false, vertical: true)
                    .animation(.spring(response: 0.45, dampingFraction: 0.9), value: big)
            }
            if !big, !c.lastFri.isEmpty {
                Text(c.lastFri)
                    .font(.system(size: 19, weight: .medium)).tracking(-0.2).lineSpacing(5)
                    .foregroundStyle(.white)
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if m == .job {
                HStack(spacing: 10) {
                    Spinner()
                    Text(c.jobTask.isEmpty ? "Mac กำลังทำ" : c.jobTask).font(.system(size: 13)).foregroundStyle(.white.opacity(0.8)).lineLimit(2)
                }
            }
            if m == .done {
                HStack(spacing: 10) {
                    Circle().fill(.white).frame(width: 6, height: 6).shadow(color: .white, radius: 5)
                    Text(c.doneText.isEmpty ? "เสร็จแล้ว" : c.doneText).font(.system(size: 13)).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                }
            }
            if !c.resultLine.isEmpty {
                Text(c.resultLine).font(.system(size: 12)).foregroundStyle(.white.opacity(0.4)).lineLimit(2)
            }
        }
        .frame(width: 330, alignment: .leading)
        .animation(.spring(response: 0.45, dampingFraction: 0.9), value: m)
    }

    private func status(_ m: Mode) -> String {
        switch m {
        case .speak: return "กำลังพูด"
        case .job: return "Mac กำลังทำ"
        case .done: return "เสร็จแล้ว"
        case .muted: return "ปิดไมค์อยู่"
        default: return c.phase == .connecting ? "กำลังเชื่อมต่อ" : "ฟังอยู่"
        }
    }

    /// ปุ่มปิด/เปิดไมค์ชั่วคราว — ปิดอยู่ = พื้นเหลือง ไอคอนขีดฆ่า
    private var micButton: some View {
        Button { c.toggleMic() } label: {
            Image(systemName: c.micMuted ? "mic.slash.fill" : "mic.fill")
                .font(.system(size: 13))
                .foregroundStyle(c.micMuted ? Color(white: 0.067) : .white.opacity(0.8))
                .frame(width: 30, height: 30)
                .background(c.micMuted ? Self.amber : Color.white.opacity(0.07), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .scaleEffect(ui.hover == "mic" ? 1.08 : 1)
        .animation(.easeOut(duration: 0.15), value: ui.hover)
        .onHover { ui.setHover("mic", $0) }
        .help(c.micMuted ? "เปิดไมค์" : "ปิดไมค์ชั่วคราว")
    }

    // ---------- แผงยืนยัน ----------
    private var confirmPanel: some View {
        let p = c.pendingConfirm
        return VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Circle().fill(Self.amber).frame(width: 6, height: 6).shadow(color: Self.amber.opacity(0.8), radius: 5)
                Text("ต้องยืนยัน").font(.system(size: 12, weight: .semibold)).tracking(0.24).foregroundStyle(Self.amber)
                Spacer(minLength: 0)
                countdown(p?.at)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(p?.task ?? "").font(.system(size: 19, weight: .medium)).tracking(-0.2).lineSpacing(5)
                    .foregroundStyle(.white).lineLimit(5).fixedSize(horizontal: false, vertical: true)
                let cmd = Self.command(p?.reason ?? "")
                if !cmd.isEmpty {
                    Text(cmd).font(.system(size: 12, design: .monospaced)).lineSpacing(3)
                        .foregroundStyle(.white.opacity(0.5)).lineLimit(6).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Button { decide(approve: false) } label: {
                    HStack(spacing: 6) {
                        Text("ยกเลิก").font(.system(size: 13.5)).foregroundStyle(.white.opacity(0.9))
                        Text("esc").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4))
                    }
                    .frame(maxWidth: .infinity).frame(height: 40)
                    .background(Color.white.opacity(ui.hover == "cancel" ? 0.16 : 0.09), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { ui.setHover("cancel", $0) }
                Button { decide(approve: true) } label: {
                    HStack(spacing: 6) {
                        Text("ยืนยัน").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Color(white: 0.067))
                        Text("↩").font(.system(size: 11)).foregroundStyle(Color(white: 0.067).opacity(0.45))
                    }
                    .frame(maxWidth: .infinity).frame(height: 40)
                    .background(Color.white, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .shadow(color: .white.opacity(ui.hover == "ok" ? 0.25 : 0.12), radius: ui.hover == "ok" ? 14 : 10, y: 6)
                .scaleEffect(ui.hover == "ok" ? 1.03 : 1)
                .onHover { ui.setHover("ok", $0) }
            }
            .animation(.easeOut(duration: 0.15), value: ui.hover)
            HStack {
                Text("หรือพูดว่า “ยืนยัน”").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.4))
                Spacer(minLength: 0)
                Button { decide(approve: true, always: true) } label: {
                    Text("ยืนยันตลอด").font(.system(size: 11.5)).foregroundStyle(.white.opacity(ui.hover == "always" ? 0.9 : 0.65))
                }
                .buttonStyle(.plain)
                .onHover { ui.setHover("always", $0) }
                .help("ยืนยัน และไม่ต้องถามงานแบบนี้อีก")
            }
        }
        .frame(width: 330, alignment: .leading)
    }

    private func decide(approve: Bool, always: Bool = false) {
        guard let p = c.pendingConfirm else { return }
        Task { await c.decide(p.jobId, approve: approve, via: always ? "ปุ่ม·ตลอด" : "ปุ่ม", remember: always) }
    }

    /// คำสั่งดิบใต้ชื่องาน — ตัดคำนำ "รันคำสั่ง:/เขียนไฟล์:/แก้ไฟล์:" ออก
    static func command(_ reason: String) -> String {
        reason.replacingOccurrences(of: #"^\s*(รันคำสั่ง|เขียนไฟล์|แก้ไฟล์)\s*:\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func countdown(_ at: Date?) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let left = max(0, 300 - Int(ctx.date.timeIntervalSince(at ?? ctx.date)))
            Text(String(format: "%d:%02d", left / 60, left % 60)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.white.opacity(0.4))
        }
    }
}

// ---------- สถานะฝั่ง UI ที่แชร์กับ AppDelegate ----------
@MainActor
final class OverlayUI: ObservableObject {
    @Published var visible = false               // หน้าต่าง overlay โชว์อยู่ (ใช้หยุดวาดคลื่นตอนซ่อน)
    @Published var hover: String?                // ปุ่มที่เมาส์ชี้อยู่
    var panelRect: CGRect = .zero                // กรอบแผงที่โชว์อยู่ (พิกัดใน overlay, origin ซ้ายบน) — ใช้สลับ ignoresMouseEvents
    var windowFrame: CGRect = .zero              // กรอบหน้าต่าง overlay บนจอ — ใช้ทำคลื่นดูดตามเมาส์
    let wave = WaveEngine()

    func setHover(_ id: String, _ on: Bool) {
        if on { hover = id } else if hover == id { hover = nil }
    }
}

/// แผงที่ซ่อน: จาง + เลื่อนไปขวา 28pt + กดไม่ได้ · แผงที่โชว์ส่งกรอบให้ AppDelegate รู้ว่าตรงไหนต้องรับคลิก
private struct PanelSlot: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        content
            .background(GeometryReader { g in
                Color.clear.preference(key: PanelRectKey.self, value: on ? g.frame(in: .named("overlay")) : .zero)
            })
            .opacity(on ? 1 : 0)
            .animation(.easeOut(duration: 0.5), value: on)
            .offset(x: on ? 0 : 28)
            .animation(.spring(response: 0.6, dampingFraction: 0.88), value: on)
            .allowsHitTesting(on)
            .padding(.trailing, 64)
    }
}

private struct PanelRectKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let n = nextValue()
        if !n.isEmpty { value = value.isEmpty ? n : value.union(n) }
    }
}

private struct Spinner: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            ZStack {
                Circle().stroke(.white.opacity(0.18), lineWidth: 1.5)
                Circle().trim(from: 0, to: 0.28).stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360))
            }
            .frame(width: 12, height: 12)
        }
    }
}

/// blur ของจอด้านหลัง จางจากขอบขวา (ทึบ 0–55% จากขวา แล้วจางถึง 0 ที่ขอบซ้าย)
private struct EdgeBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

// ---------- คลื่น ----------
/// 31 แท่งแนวนอนเรียงลงล่าง ชิดขวาติดขอบจอ · ความกว้าง/ความทึบคำนวณใหม่ทุกเฟรม
private struct WaveView: View {
    @ObservedObject var c: FridayController
    @ObservedObject var ui: OverlayUI

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !ui.visible)) { tl in
            Canvas { ctx, size in
                let m = OverlayView.mode(c, now: tl.date)
                let raw = m == .speak ? c.outLevel : m == .listen || m == .wake ? c.micLevel : 0
                let bars = ui.wave.step(now: tl.date, mode: m, level: min(1, raw / 2500), cursor: cursor())
                let top = (size.height - WaveEngine.height) / 2
                for (i, b) in bars.enumerated() {
                    let color = Color(red: b.r / 255, green: b.g / 255, blue: b.b / 255)
                    let rect = CGRect(x: size.width - b.w, y: top + CGFloat(i) * 7, width: b.w, height: 2)
                    ctx.drawLayer { l in
                        l.addFilter(.shadow(color: color.opacity(0.4 * b.a), radius: 4.5 * b.a))
                        l.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color.opacity(b.a)))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// คลื่นดูดตามเมาส์: เมาส์อยู่ใกล้ขอบขวา (320pt) และอยู่ในช่วงคลื่น ±140pt → ศูนย์กลางคลื่นตามเมาส์
    private func cursor() -> Double? {
        let f = ui.windowFrame, p = NSEvent.mouseLocation
        guard !f.isEmpty else { return nil }
        let h = Double(WaveEngine.height), waveTop = Double(f.midY) + h / 2
        let near = p.x > f.maxX - 320 && p.x < f.maxX + 10 && p.y < waveTop + 140 && p.y > waveTop - h - 140
        return near ? min(0.85, max(0.15, (waveTop - p.y) / h)) : nil
    }
}

/// คณิตของคลื่น (ตรงกับ static Wave ใน Friday Mac.dc.html) — สถานะเก็บในคลาสนี้เพราะไม่มี @State
final class WaveEngine {
    struct Bar { var w: Double; var a: Double; var r: Double; var g: Double; var b: Double }
    static let count = 31
    static let height: CGFloat = CGFloat(count) * 2 + CGFloat(count - 1) * 5   // 212pt
    private static let top: [Double] = [240, 226, 255], bottom: [Double] = [192, 132, 252]   // Lavender #f0e2ff → #c084fc

    private var amp = 0.5, sig = 0.2, len = 30.0, c = 0.5, mix = 0.0, mic = 0.0
    private var col: [Double] = [255, 200, 74]
    private var ripple = -1.0, flash = 0.0, t = 0.0
    private var last: Date?
    private var prev: OverlayView.Mode?

    private func target(_ m: OverlayView.Mode) -> (amp: Double, sig: Double, len: Double, col: [Double]?) {
        switch m {
        case .sleep: return (0, 0.06, 0, nil)
        case .wake: return (0.9, 0.3, 40, nil)
        case .listen: return (1, 0.22, 34, nil)
        case .speak: return (1, 0.3, 58, nil)
        case .job: return (0.6, 0.32, 40, nil)
        case .confirm: return (0.55, 0.3, 38, [255, 200, 74])
        case .done: return (0.8, 0.4, 48, nil)
        case .muted: return (0, 0.3, 0, [150, 150, 160])
        }
    }

    func step(now: Date, mode p: OverlayView.Mode, level: Double, cursor: Double?) -> [Bar] {
        let dt = min(0.05, max(0, now.timeIntervalSince(last ?? now)))
        last = now; t += dt
        if p != prev {
            if p == .wake { ripple = 0 }
            if p == .done { flash = 1 }
            prev = p
        }
        let g = target(p), k = 1 - pow(0.004, dt)
        amp += (g.amp - amp) * k; sig += (g.sig - sig) * k; len += (g.len - len) * k
        c += ((cursor ?? 0.5) - c) * (1 - pow(0.02, dt))
        if let gc = g.col { for j in 0..<3 { col[j] += (gc[j] - col[j]) * k } }
        mix += ((g.col == nil ? 0 : 1) - mix) * k
        let micT: Double
        switch p {
        case .listen, .speak, .wake: micT = level
        case .job: micT = 0.5
        case .confirm: micT = 0.45 + 0.2 * sin(2.4 * t)
        case .done: micT = 0.7
        default: micT = 0
        }
        mic += (micT - mic) * (1 - pow(0.0008, dt))
        if ripple >= 0 { ripple += dt / 0.75; if ripple > 1.3 { ripple = -1 } }
        if flash > 0 { flash = max(0, flash - dt / 1.1) }
        let scan = p == .job ? 0.5 + 0.42 * sin(1.9 * t) : -1

        var out: [Bar] = []
        out.reserveCapacity(Self.count)
        for i in 0..<Self.count {
            let u = Double(i) / Double(Self.count - 1)
            let e = exp(-pow((u - c) / sig, 2))
            let pc = (0..<3).map { Self.top[$0] + (Self.bottom[$0] - Self.top[$0]) * u }
            let rgb = (0..<3).map { pc[$0] + (col[$0] - pc[$0]) * mix }
            let wob = 0.6 + 0.4 * sin(5.3 * t + 0.7 * Double(i)) * sin(2.1 * t - 0.33 * Double(i))
            var w = 3 + len * amp * e * (0.35 + 0.65 * mic) * wob
            var a = 0.22 + 0.78 * e * max(0.3, amp)
            if ripple >= 0 { let d = abs(u - ripple); if d < 0.1 { let q = 1 - d / 0.1; w += 30 * q; a = max(a, q) } }
            if scan >= 0 { let d = abs(u - scan); if d < 0.09 { let q = 1 - d / 0.09; w += 14 * q; a = min(1, a + 0.6 * q) } }
            if flash > 0 {
                let front = (1 - flash) * 0.75, q = max(0, 1 - abs(abs(u - 0.5) - front) / 0.09)
                w += 34 * q * flash; a = max(a, q * flash)
            }
            if p == .muted { w = 3; a = 0.22 }
            if p == .sleep && ripple < 0 { let d = abs(u - 0.5); w = d < 0.05 ? 5 : 2; a = d < 0.05 ? 0.55 : 0.08 }
            out.append(Bar(w: w, a: min(1, a), r: rgb[0], g: rgb[1], b: rgb[2]))
        }
        return out
    }
}
