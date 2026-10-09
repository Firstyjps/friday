import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// "Fri the Fox" — มาสคอตพิกเซล 13×12 (ไอคอนแอป บนพื้น Night Sky + ไอคอนเมนูบาร์แบบ template + อารมณ์)
/// วาดด้วยช่องจำนวนเต็มและตำแหน่งจำนวนเต็มเสมอ ขอบจะได้คมไม่มีรอยต่อ
enum Fox {
    enum Mood { case listening, thinking, sleeping }

    static let map = [
        ".o.........o.", ".oo.......oo.", ".ooo.....ooo.", ".ooooooooooo.", "ooooooooooooo", "oooeoooooeooo",
        "wwoooodooooww", ".wwwwwwwwwww.", "..wwwwwwwww..", "...ooooooo...", "..ooooooooo..", "..dd.....dd..",
    ]
    static let cols = 13, rows = 12
    static let eyes = [(3, 5), (9, 5)]
    static let orange = CGColor(srgbRed: 0xE8 / 255, green: 0x70 / 255, blue: 0x1E / 255, alpha: 1)
    static let cream = CGColor(srgbRed: 1, green: 0xF6 / 255, blue: 0xEC / 255, alpha: 1)
    static let brown = CGColor(srgbRed: 0x7A / 255, green: 0x34 / 255, blue: 0x10 / 255, alpha: 1)
    static let eye = CGColor(srgbRed: 0x2A / 255, green: 0x1A / 255, blue: 0x10 / 255, alpha: 1)

    /// วางตาตามอารมณ์ (หน่วย = ช่อง) — ฟัง: 1×1 · คิด: ขวา 1 ขึ้น 0.3 · หลับ: แถบบาง 1.3×0.35 ครึ่งล่าง
    static func eyeRect(_ ex: Int, _ ey: Int, _ mood: Mood) -> CGRect {
        switch mood {
        case .listening: return CGRect(x: ex, y: ey, width: 1, height: 1)
        case .thinking: return CGRect(x: Double(ex + 1), y: Double(ey) - 0.3, width: 1, height: 1)
        case .sleeping: return CGRect(x: Double(ex) - 0.15, y: Double(ey) + 0.55, width: 1.3, height: 0.35)
        }
    }

    /// วาดจิ้งจอกสีลงใน context (y ลงล่าง) ที่มุมซ้ายบน origin ขนาดช่อง cell
    static func draw(_ g: CGContext, origin: CGPoint, cell: CGFloat, mood: Mood) {
        for (y, row) in map.enumerated() {
            for (x, ch) in row.enumerated() where ch != "." {
                g.setFillColor(ch == "w" ? cream : ch == "d" ? brown : orange)
                g.fill(CGRect(x: origin.x + CGFloat(x) * cell, y: origin.y + CGFloat(y) * cell, width: cell, height: cell))
            }
        }
        g.setFillColor(eye)
        for (ex, ey) in eyes {
            let r = eyeRect(ex, ey, mood)
            g.fill(CGRect(x: origin.x + r.minX * cell, y: origin.y + r.minY * cell, width: r.width * cell, height: r.height * cell))
        }
    }

    // ---------- ไอคอนแอป (Night Sky) ----------

    /// วาดไอคอนเต็มขนาด px×px: squircle 824/1024 ของผืน + เงา (ขนาดมาตรฐานไอคอน macOS)
    static func appIcon(px: Int, mood: Mood = .listening) -> CGImage? {
        guard let g = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        g.interpolationQuality = .none
        g.setShouldAntialias(true)
        let P = CGFloat(px)
        let S = (P * 824 / 1024).rounded()
        let o = ((P - S) / 2).rounded()
        g.translateBy(x: 0, y: P); g.scaleBy(x: 1, y: -1)        // พิกัดแบบจอ: (0,0) มุมซ้ายบน
        let rect = CGRect(x: o, y: o, width: S, height: S)
        let squircle = CGPath(roundedRect: rect, cornerWidth: S * 0.2237, cornerHeight: S * 0.2237, transform: nil)

        // เงา (offset ของเงาไม่ถูกพลิกตาม CTM → y ลบ = ลงล่าง)
        g.saveGState()
        g.setShadow(offset: CGSize(width: 0, height: -max(1, P * 0.012)), blur: max(1, P * 0.03), color: CGColor(gray: 0, alpha: 0.3))
        g.addPath(squircle); g.setFillColor(CGColor(srgbRed: 0x0E / 255, green: 0x14 / 255, blue: 0x24 / 255, alpha: 1)); g.fillPath()
        g.restoreGState()

        g.saveGState()
        g.addPath(squircle); g.clip()
        let sky = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
            CGColor(srgbRed: 0x24 / 255, green: 0x30 / 255, blue: 0x55 / 255, alpha: 1),
            CGColor(srgbRed: 0x0E / 255, green: 0x14 / 255, blue: 0x24 / 255, alpha: 1)] as CFArray, locations: [0, 1])!
        g.drawLinearGradient(sky, start: CGPoint(x: 0, y: o), end: CGPoint(x: 0, y: o + S), options: [])

        let cell = max(1, (S * 0.056).rounded(.down))
        // ดาวพิกเซล 6 ดวง ตัวสลับเล็ก 0.6 ช่อง
        g.setShouldAntialias(false)
        for (i, (fx, fy)) in [(0.16, 0.18), (0.80, 0.14), (0.88, 0.42), (0.10, 0.56), (0.72, 0.82), (0.24, 0.86)].enumerated() {
            let s = max(1, (cell * (i % 2 == 1 ? 0.6 : 1)).rounded())
            g.setFillColor(CGColor(gray: 1, alpha: 0.8))
            g.fill(CGRect(x: o + (S * fx).rounded(), y: o + (S * fy).rounded(), width: s, height: s))
        }
        let left = o + ((S - CGFloat(cols) * cell) / 2).rounded(), top = o + ((S - CGFloat(rows) * cell) / 2).rounded()
        draw(g, origin: CGPoint(x: left, y: top), cell: cell, mood: mood)
        g.setShouldAntialias(true)

        // เงามันด้านบน: ขาว 18% → 0 ที่ 40% ความสูง
        let gloss = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [CGColor(gray: 1, alpha: 0.18), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
        g.drawLinearGradient(gloss, start: CGPoint(x: 0, y: o), end: CGPoint(x: 0, y: o + S * 0.4), options: [])
        g.restoreGState()
        g.addPath(squircle); g.setStrokeColor(CGColor(gray: 0, alpha: 0.08)); g.setLineWidth(max(0.5, P * 0.004)); g.strokePath()
        return g.makeImage()
    }

    static func appIconImage(px: Int = 512) -> NSImage? {
        guard let cg = appIcon(px: px) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: px, height: px))
    }

    /// สร้าง AppIcon iconset (16…512 @1x/@2x) — build.sh เรียกผ่าน `Friday --make-iconset <dir>`
    static func writeIconset(to dir: String) -> Bool {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for s in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = "icon_\(s)x\(s)\(scale == 2 ? "@2x" : "").png"
                guard let img = appIcon(px: s * scale) else { return false }
                let url = URL(fileURLWithPath: dir).appendingPathComponent(name) as CFURL
                guard let d = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else { return false }
                CGImageDestinationAddImage(d, img, nil)
                guard CGImageDestinationFinalize(d) else { return false }
            }
        }
        return true
    }

    // ---------- ไอคอนเมนูบาร์ (template) ----------

    /// เงาดำทั้งตัว ช่องละ 1pt (13×12 pt) ส่วนขาว (w) และตาเป็นรู · isTemplate → ปรับสีตามเมนูบาร์สว่าง/มืดเอง
    static func menuBarImage(mood: Mood, dim: Bool = false) -> NSImage {
        let img = NSImage(size: NSSize(width: cols, height: rows), flipped: true) { _ in
            guard let g = NSGraphicsContext.current?.cgContext else { return false }
            g.setShouldAntialias(false)
            g.setFillColor(CGColor(gray: 0, alpha: dim ? 0.45 : 1))
            for (y, row) in map.enumerated() {
                for (x, ch) in row.enumerated() where ch != "." && ch != "w" { g.fill(CGRect(x: x, y: y, width: 1, height: 1)) }
            }
            g.setBlendMode(.clear)
            g.setShouldAntialias(true)
            for (ex, ey) in eyes { g.fill(eyeRect(ex, ey, mood)) }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Friday"
        return img
    }
}

/// จิ้งจอกใน SwiftUI (ใช้ในหน้า Home / Help) — กะพริบตาเป็นพักๆ เมื่อ blink = true
struct FoxView: View {
    var cell: CGFloat = 4
    var mood: Fox.Mood = .listening
    var blink = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
            let closed = blink && Self.blinking(ctx.date)
            Canvas { g, _ in
                g.withCGContext { cg in Fox.draw(cg, origin: .zero, cell: cell, mood: closed ? .sleeping : mood) }
            }
            .frame(width: CGFloat(Fox.cols) * cell, height: CGFloat(Fox.rows) * cell)
        }
    }

    /// ปิดตา 150ms ทุก 2.8–5 วิ (สุ่มแบบกำหนดได้จากรอบเวลา ไม่ต้องเก็บ state)
    static func blinking(_ d: Date) -> Bool {
        let t = d.timeIntervalSinceReferenceDate
        var start = floor(t / 6) * 6
        let r = sin(start * 12.9898) * 43758.5453
        start += 2.8 + (r - floor(r)) * 2.2
        return t >= start && t < start + 0.15
    }
}
