import SwiftUI

/// หน้าต่างลอยเล็กๆ ตอนคุย: วงกลม (สถานะ) + ข้อความถอดเสียง + ปุ่มยืนยันงานเสี่ยง
struct PanelView: View {
    @ObservedObject var c: FridayController
    private let accent = Color(red: 1, green: 0.48, blue: 0.1)

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Orb(active: c.phase == .live || c.phase == .connecting, speaking: c.speaking, accent: accent)
                    .frame(width: 44, height: 44)
                    .onTapGesture { c.toggle() }
                VStack(alignment: .leading, spacing: 2) {
                    Text("FRIDAY").font(.system(size: 11, weight: .semibold)).tracking(3).foregroundStyle(.secondary)
                    Text(status).font(.system(size: 13))
                }
                Spacer()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(c.messages) { m in bubble(m).id(m.id) }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: c.messages.last?.text) { _, _ in
                    if let id = c.messages.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                }
            }
        }
        .padding(14)
        .frame(width: 360, height: 440)
        .background(.ultraThinMaterial)
    }

    private var status: String {
        switch c.phase {
        case .starting: return "กำลังเริ่ม…"
        case .sleeping: return c.earMuted ? "🔇 ปิดหูอยู่" : "💤 รอคำปลุก \"Friday\""
        case .connecting: return "กำลังเชื่อมต่อ…"
        case .live: return c.speaking ? "กำลังพูด…" : "ฟังอยู่… พูดได้เลย"
        case .error(let e): return "⚠️ \(e)"
        }
    }

    @ViewBuilder
    private func bubble(_ m: FridayController.Message) -> some View {
        switch m.kind {
        case .me:
            HStack { Spacer(minLength: 40); Text(m.text).padding(10).background(Color.blue.opacity(0.25), in: RoundedRectangle(cornerRadius: 12)) }
        case .fri:
            HStack { Text(m.text).padding(10).background(accent.opacity(0.22), in: RoundedRectangle(cornerRadius: 12)); Spacer(minLength: 40) }
        case .sys:
            Text(m.text).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        case .confirm:
            VStack(spacing: 8) {
                Text(m.text).font(.system(size: 13, weight: .medium)).multilineTextAlignment(.center)
                HStack {
                    Button("✅ ยืนยัน") { if let j = m.jobId { Task { await c.decide(j, approve: true, via: "ปุ่ม") } } }
                        .buttonStyle(.borderedProminent).tint(accent)
                    Button("❌ ยกเลิก") { if let j = m.jobId { Task { await c.decide(j, approve: false, via: "ปุ่ม") } } }
                }
            }
            .padding(12)
            .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(accent, lineWidth: 1))
        }
    }
}

struct Orb: View {
    var active: Bool, speaking: Bool, accent: Color

    var body: some View {
        // TimelineView แทน @State (SwiftUI macro ใช้ไม่ได้เมื่อ build ด้วย Command Line Tools)
        TimelineView(.animation(paused: !speaking)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let pulse = speaking ? 1 + 0.06 * sin(t * 6) : 1
            Circle()
                .fill(RadialGradient(colors: active ? [Color(red: 1, green: 0.7, blue: 0.45), accent, Color(red: 0.48, green: 0.18, blue: 0)] : [.gray, Color(white: 0.3)],
                                     center: UnitPoint(x: 0.35, y: 0.3), startRadius: 1, endRadius: 30))
                .scaleEffect(pulse)
                .shadow(color: active ? accent.opacity(0.6) : .clear, radius: speaking ? 10 : 4)
        }
    }
}
