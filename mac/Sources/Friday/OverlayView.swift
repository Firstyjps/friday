import SwiftUI

/// Island overlay (ทิศทาง B): แถบเล็กกลางขอบบนจอตอนปลุก → ขยายเป็นการ์ดเมื่อ Friday พูด/มีงาน → การ์ดยืนยันเมื่อต้องถาม
/// ไม่มี @State (build ด้วย CLT) — ทุกอย่างอ่านจาก FridayController ที่เป็น ObservableObject
struct OverlayView: View {
    @ObservedObject var c: FridayController
    static let width: CGFloat = 380, height: CGFloat = 240

    private let ink = Color(red: 0.043, green: 0.051, blue: 0.063)        // #0b0d10
    private let accent = Color(red: 1, green: 0.48, blue: 0.1)             // #ff7a1a
    private let warn = Color(red: 1, green: 0.784, blue: 0.29)             // #ffc84a
    private let dim = Color(red: 0.54, green: 0.565, blue: 0.6)            // #8a9099

    enum Mode: Equatable { case pill, card, confirm }
    private var mode: Mode {
        if c.pendingConfirm != nil { return .confirm }
        if !c.lastFri.isEmpty || c.activeJobs > 0 { return .card }
        return .pill
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch mode {
                case .pill: pill
                case .card: card
                case .confirm: confirmCard
                }
            }
            .padding(mode == .pill ? EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 16) : EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
            .background(ink, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(mode == .confirm ? warn.opacity(0.6) : Color.white.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.55), radius: 18, y: 10)
            .frame(width: mode == .pill ? nil : 340)
            .animation(.spring(response: 0.35, dampingFraction: 0.82), value: mode)
            Spacer(minLength: 0)
        }
        .frame(width: Self.width, height: Self.height, alignment: .top)
        .padding(.top, 2)
    }

    // ---------- 1) ฟังอยู่ ----------
    private var pill: some View {
        HStack(spacing: 10) {
            orb(22)
            bars(count: 4, level: c.speaking ? c.outLevel : c.micLevel, height: 16)
            Text(status).font(.system(size: 13)).foregroundStyle(.white)
        }
    }

    // ---------- 2) คุย + งานกำลังทำ ----------
    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                orb(22)
                Text("Friday").font(.system(size: 12)).foregroundStyle(dim)
                Spacer()
                elapsed(since: c.sessionStartPublic)
            }
            if !c.lastFri.isEmpty {
                Text(c.lastFri).font(.system(size: 13)).foregroundStyle(.white).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            if c.activeJobs > 0 {
                HStack(spacing: 8) {
                    spinner
                    Text("Mac กำลังทำ").font(.system(size: 12)).foregroundStyle(Color(white: 0.8))
                    Spacer()
                    elapsed(since: c.jobStartedAt)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    // ---------- 3) ต้องยืนยัน ----------
    private var confirmCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "terminal").font(.system(size: 13, weight: .semibold)).foregroundStyle(warn)
                Text("ยืนยันไหม").font(.system(size: 12, weight: .semibold)).foregroundStyle(warn)
                Spacer()
                countdown
            }
            if let p = c.pendingConfirm {
                Text(p.reason.isEmpty ? p.task : p.reason)
                    .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.white)
                    .lineLimit(4).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                HStack(spacing: 8) {
                    Button { Task { await c.decide(p.jobId, approve: true, via: "ปุ่ม") } } label: {
                        Text("ยืนยัน").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(red: 0.1, green: 0.05, blue: 0)).frame(maxWidth: .infinity).frame(height: 34)
                    }.buttonStyle(.plain).background(accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Button { Task { await c.decide(p.jobId, approve: false, via: "ปุ่ม") } } label: {
                        Text("ยกเลิก").font(.system(size: 13)).foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 34)
                    }.buttonStyle(.plain).background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                HStack {
                    Text("หรือพูดว่า \"ยืนยัน\" / \"ยกเลิก\"").font(.system(size: 11)).foregroundStyle(dim)
                    Spacer()
                    Button { Task { await c.decide(p.jobId, approve: true, via: "ปุ่ม·ตลอด", remember: true) } } label: {
                        Text("ยืนยันตลอด · ไม่ถามอีก").font(.system(size: 11, weight: .medium)).foregroundStyle(warn)
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    // ---------- ชิ้นส่วน ----------
    private var status: String {
        switch c.phase {
        case .connecting: return "กำลังเชื่อมต่อ…"
        case .live: return c.speaking ? "กำลังพูด…" : "ฟังอยู่…"
        case .sleeping: return "พักแล้ว"
        default: return ""
        }
    }

    private func orb(_ size: CGFloat) -> some View {
        let live = c.phase == .live || c.phase == .connecting
        let level = min(1, (c.speaking ? c.outLevel : c.micLevel) / 3000)
        return Circle()
            .fill(RadialGradient(colors: live ? [Color(red: 1, green: 0.7, blue: 0.45), accent, Color(red: 0.48, green: 0.18, blue: 0)] : [.gray, Color(white: 0.3)],
                                 center: UnitPoint(x: 0.35, y: 0.3), startRadius: 1, endRadius: size * 0.7))
            .frame(width: size, height: size)
            .scaleEffect(1 + 0.12 * level)
            .shadow(color: accent.opacity(live ? 0.35 + 0.5 * level : 0), radius: 6 + 8 * level)
            .animation(.easeOut(duration: 0.12), value: level)
    }

    /// แท่งระดับเสียง 4 แท่ง ขยับตาม level จริง (ไมค์ตอนฟัง / เสียง Friday ตอนพูด)
    private func bars(count: Int, level: Double, height: CGFloat) -> some View {
        let l = min(1, level / 2500)
        return HStack(spacing: 3) {
            ForEach(0..<count, id: \.self) { i in
                let scale = [0.55, 1.0, 0.8, 0.65][i % 4]
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(accent)
                    .frame(width: 3, height: max(4, height * (0.25 + 0.75 * l * scale)))
                    .animation(.easeOut(duration: 0.1), value: l)
            }
        }
        .frame(height: height)
    }

    private var spinner: some View {
        TimelineView(.animation) { ctx in
            Circle().trim(from: 0.1, to: 0.9).stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 12, height: 12)
                .rotationEffect(.degrees(ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360))
        }
    }

    private func elapsed(since t0: Date?) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let s = Int(t0.map { ctx.date.timeIntervalSince($0) } ?? 0)
            Text(String(format: "%d:%02d", s / 60, s % 60)).font(.system(size: 11, design: .rounded).monospacedDigit()).foregroundStyle(dim)
        }
    }

    private var countdown: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let left = max(0, 300 - Int(ctx.date.timeIntervalSince(c.pendingConfirm?.at ?? ctx.date)))
            Text(String(format: "%d:%02d", left / 60, left % 60)).font(.system(size: 11, design: .rounded).monospacedDigit()).foregroundStyle(dim)
        }
    }
}
