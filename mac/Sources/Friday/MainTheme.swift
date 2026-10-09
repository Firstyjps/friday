import AppKit
import CoreText
import SwiftUI

/// โทนสี/ตัวอักษร/ชิ้นส่วนร่วมของหน้าต่างหลัก Friday.app (design handoff "Friday.app main window")
enum T {
    static func hex(_ v: UInt32, _ a: Double = 1) -> Color {
        Color(.sRGB, red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255, opacity: a)
    }
    static let ink = hex(0x1F1D1B), body = hex(0x3D3935), secondary = hex(0x5D5852), muted = hex(0x6F6A64)
    static let faint = hex(0x7A746C), placeholder = hex(0xA8A199), navIcon = hex(0x77716A)
    static let window = hex(0xF3EFEA), sheet = hex(0xFBF9F6), card = Color.white, hover = hex(0xFAF8F5)
    static let divider = hex(0xF3EEE8), track = hex(0xF3EEE8), toggleOff = hex(0xE2DDD6), sparkDivider = hex(0xF0EBE4)
    static let accent = hex(0xE8701E), accentText = hex(0xC8580F), accentDeep = hex(0x9C430A), accentTint = hex(0xFDEEE2), accentLight = hex(0xF6C9A6)
    static let navActive = hex(0xE2621B), friday = hex(0xD9601A)
    static let success = hex(0x2F7D43), successBg = hex(0xE9F6EC), successDot = hex(0x34C759)
    static let running = hex(0x5B55D6), runningBg = hex(0xEEEDFB)
    static let error = hex(0xC8372D), errorBg = hex(0xFBE9E7)
    static let warn = hex(0xE8A21E), warnText = hex(0x9A6510), warnBg = hex(0xFDF3E1)
    static let pending = hex(0xC2560C)
    static let standby = hex(0xC9C3BB)

    /// Anuphan (ไทย+ละติน ในฟอนต์เดียว) — ถ้ายังไม่ได้ติดตั้งฟอนต์ ใช้ฟอนต์ระบบแทน
    static func f(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        fontReady ? .custom("Anuphan", size: size).weight(weight) : .system(size: size, weight: weight)
    }
    static func mono(_ size: CGFloat = 12.5, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }

    private(set) static var fontReady = false
    /// ฟอนต์อยู่ข้าง dylib: ~/Library/Application Support/Friday/Fonts (build.sh คัดลอกจาก mac/Resources/Fonts)
    static func registerFonts() {
        let dir = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Friday/Fonts")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?.filter { ["ttf", "otf"].contains($0.pathExtension.lowercased()) } ?? []
        for f in files {
            var err: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(f as CFURL, .process, &err) { Log.write("font: ลงทะเบียน \(f.lastPathComponent) ไม่ได้") }
        }
        fontReady = NSFont(name: "Anuphan", size: 13) != nil || (CTFontManagerCopyAvailableFontFamilyNames() as? [String])?.contains("Anuphan") == true
    }
}

// ---------- ชิ้นส่วน ----------

struct Card: ViewModifier {
    var padding: EdgeInsets = EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0)
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(T.card)
                .shadow(color: .black.opacity(0.04), radius: 1.5, y: 1)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.black.opacity(0.05), lineWidth: 0.5)))
    }
}
extension View {
    func card(_ v: CGFloat = 8, _ h: CGFloat = 0) -> some View { modifier(Card(padding: EdgeInsets(top: v, leading: h, bottom: v, trailing: h))) }
    /// แตะได้ + VoiceOver รู้ว่าเป็นปุ่มและกดได้ (onTapGesture เปล่าๆ VoiceOver มองไม่เห็นว่ากดได้ — รีวิว 9 ต.ค.)
    func tap(_ action: @escaping () -> Void) -> some View {
        onTapGesture(perform: action).accessibilityAddTraits(.isButton).accessibilityAction(.default, action)
    }
}

/// สวิตช์ 40×24 (ส้มเมื่อเปิด) — ไม่ใช้ Toggle ของระบบให้ตรงดีไซน์
struct Switch: View {
    var on: Bool
    var locked = false
    var body: some View {
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule().fill(on ? T.accent : T.toggleOff)
            Circle().fill(.white).frame(width: 20, height: 20).shadow(color: .black.opacity(0.25), radius: 1.5, y: 1).padding(2)
        }
        .frame(width: 40, height: 24)
        .opacity(locked ? 0.5 : 1)
        .accessibilityElement().accessibilityAddTraits(.isToggle).accessibilityValue(on ? "เปิด" : "ปิด")
        .animation(.easeOut(duration: 0.15), value: on)
    }
}

/// ปุ่มเม็ดยา: เลือกอยู่ = ดำ ตัวขาว · ไม่เลือก = ขาว มีเส้นบาง
struct Pill: View {
    let label: String
    var count: Int? = nil
    let on: Bool
    var height: CGFloat = 32
    let action: () -> Void
    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(T.f(14, .medium))
            if let count { Text("\(count)").font(T.f(12)).opacity(0.6) }
        }
        .foregroundStyle(on ? .white : T.body)
        .padding(.horizontal, 14).frame(height: height)
        .background(Capsule().fill(on ? T.ink : .white).shadow(color: .black.opacity(on ? 0 : 0.04), radius: 1, y: 1)
            .overlay(Capsule().strokeBorder(.black.opacity(on ? 0 : 0.1), lineWidth: 0.5)))
        .contentShape(Capsule())
        .tap(action)
        .animation(.easeOut(duration: 0.15), value: on)
    }
}

/// ไทล์ไอคอน 36×36 สีอ่อน + ไอคอนสีเข้ม
struct Tile<Content: View>: View {
    let bg: Color, fg: Color
    @ViewBuilder var content: Content
    var body: some View {
        content.foregroundStyle(fg)
            .frame(width: 36, height: 36)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(bg))
    }
}

/// วงหมุน 12pt (งานกำลังทำ)
struct TaskSpinner: View {
    var color: Color = T.running
    var body: some View {
        TimelineView(.animation) { ctx in
            let a = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360
            ZStack {
                Circle().stroke(color.opacity(0.25), lineWidth: 2)
                Circle().trim(from: 0, to: 0.25).stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(a))
            }.frame(width: 12, height: 12)
        }
    }
}

/// แถบความคืบหน้าบางๆ
struct Bar: View {
    let value: Double            // 0…1
    var height: CGFloat = 8
    var color: Color = T.accent
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(T.track)
                Capsule().fill(color).frame(width: max(0, min(1, value)) * g.size.width)
            }
        }.frame(height: height)
    }
}

/// หัวข้อย่อย 17pt
struct SectionLabel: View {
    let text: String
    var body: some View { Text(text).font(T.f(17, .semibold)).foregroundStyle(T.ink).padding(.horizontal, 4) }
}

/// ข้อความแบบประโยค: ส่วนที่อยู่ใน **…** เป็นตัวหนาสีเข้ม
func sentence(_ s: String, size: CGFloat = 16, color: Color = T.body) -> Text {
    var out = Text("")
    for (i, part) in s.components(separatedBy: "**").enumerated() {
        out = out + (i % 2 == 1 ? Text(part).font(T.f(size, .bold)).foregroundColor(T.ink) : Text(part).font(T.f(size)).foregroundColor(color))
    }
    return out
}
