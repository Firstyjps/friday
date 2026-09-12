import Foundation

/// VAD แบบพลังงานเสียง → ตัดช่วงพูดเป็น clip ให้ whisper เช็คคำปลุก (logic เดียวกับ server ear และ public/app.js)
/// เป็น struct ล้วน ไม่มี I/O — ป้อน chunk (PCM16 16kHz 100ms) ทีละก้อน ได้ clip กลับเมื่อจบช่วงพูด
struct WakeDetector {
    /// ระดับเสียงพื้นหลัง (ปรับตัวเอง)
    private(set) var noiseFloor = 300.0
    private(set) var peak = 0.0, frames = 0
    private var voiced = 0, silent = 0
    private var seg: [Data] = [], preroll: [Data] = []

    static let minSpeechLevel = 400.0      // ต่ำกว่านี้ไม่นับเป็นเสียงพูดแม้พื้นหลังเงียบมาก
    static let prerollChunks = 3           // เก็บ 300ms ก่อนเริ่มพูด (กันคำแรกขาด)
    static let endSilence = 6              // เงียบ 600ms = จบช่วงพูด
    static let maxChunks = 40              // ยาวเกิน 4 วิ ตัดส่ง
    static let minVoiced = 3               // ต้องมีเสียงพูดอย่างน้อย 300ms ถึงจะคุ้มค่าส่ง whisper

    /// ป้อน 1 chunk → คืน clip เมื่อจบช่วงพูดที่ยาวพอ (ไม่งั้น nil)
    mutating func feed(_ chunk: Data) -> [Data]? {
        let level = Self.rms(chunk); frames += 1; peak = max(peak, level)
        let isSpeech = level > max(noiseFloor * 3, Self.minSpeechLevel)
        if !isSpeech && seg.isEmpty {
            noiseFloor = noiseFloor * 0.95 + level * 0.05
            preroll.append(chunk); if preroll.count > Self.prerollChunks { preroll.removeFirst() }
            return nil
        }
        if seg.isEmpty { seg = preroll; preroll = [] }
        seg.append(chunk)
        if isSpeech { voiced += 1; silent = 0 } else { silent += 1 }
        guard silent >= Self.endSilence || seg.count >= Self.maxChunks else { return nil }
        let clip = seg, enough = voiced >= Self.minVoiced
        seg = []; voiced = 0; silent = 0
        return enough ? clip : nil
    }

    /// ทิ้งช่วงพูดที่ค้างอยู่ (เช่น ปิดหู)
    mutating func reset() { seg = []; voiced = 0; silent = 0 }

    /// สถิติสำหรับ ping/debug แล้วล้าง
    mutating func takeStats() -> (frames: Int, peak: Double) { defer { frames = 0; peak = 0 }; return (frames, peak) }

    static func rms(_ d: Data) -> Double {
        d.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            var acc = 0.0
            for v in s { acc += Double(v) * Double(v) }
            return (acc / Double(max(1, s.count))).squareRoot()
        }
    }
}
