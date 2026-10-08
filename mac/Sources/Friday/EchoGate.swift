import Foundation

/// แยก "เสียงผู้ใช้พูดแทรก" ออกจาก "เสียง Friday ที่สะท้อนกลับเข้าไมค์" ตอนไม่มีตัวตัดเสียงสะท้อนของ Apple
/// (เช่น เสียงออกลำโพงจอ + ไมค์หูฟัง → voice processing เปิดไม่ได้ -10875)
///
/// รู้ว่ากำลังเล่นเสียงอะไรออกลำโพง (ความดังทีละ 20ms + เวลาที่จะดังจริง) → เรียนรู้เองว่าเสียงสะท้อนช้ากี่ ms และเบาลงกี่เท่า
/// → ไมค์ดังกว่าเสียงสะท้อนที่ควรได้ยินชัดๆ ต่อเนื่อง 0.3 วิ = ผู้ใช้พูดแทรก
/// ค่าที่เรียนรู้จำไว้ตามคู่อุปกรณ์ (ลำโพง+ไมค์) ข้ามการเปิดแอปใหม่
final class EchoGate {
    struct Frame { let t: TimeInterval; let v: Double }
    static let frame = 0.02

    private var out: [Frame] = []          // เสียงออก: เวลาที่ดังจริง (ไม่รวมความหน่วงของอุปกรณ์ — delay เรียนรู้รวมไว้)
    private var mic: [Frame] = []
    private var playCursor: TimeInterval = 0
    private(set) var delay = 0.12          // วินาที
    private(set) var gain = 0.6            // ไมค์ ÷ เสียงออก (ค่าเริ่มแบบระวังไว้ก่อน — ยังไม่เรียนรู้ = พูดแทรกยากหน่อย)
    private(set) var learned = 0           // จำนวนครั้งที่เรียนรู้สำเร็จ
    private var voiceRun = 0
    private var lastCorr = 0.0
    private var key = ""

    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // ---------- ข้อมูลเข้า ----------
    /// เสียงที่เพิ่งส่งเข้าคิวลำโพง (PCM16 mono) — ต่อท้ายคิวเหมือนตัวเล่นจริง
    func played(pcm16: Data, sampleRate: Double, at t: TimeInterval = EchoGate.now) {
        playCursor = max(playCursor, t)
        let per = Int(sampleRate * Self.frame)
        pcm16.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            var i = 0
            while i < s.count {
                let e = min(s.count, i + per)
                var acc = 0.0
                for j in i..<e { acc += Double(s[j]) * Double(s[j]) }
                out.append(Frame(t: playCursor, v: (acc / Double(e - i)).squareRoot()))
                playCursor += Double(e - i) / sampleRate
                i = e
            }
        }
        trim()
    }

    /// หยุดเล่นกลางคัน → ทิ้งเสียงที่ยังไม่ได้ดัง
    func flushed(at t: TimeInterval = EchoGate.now) {
        out.removeAll { $0.t > t }
        playCursor = t
    }

    /// ไมค์ 100ms (PCM16 16k) ที่เพิ่งได้ → แตกเป็นช่วง 20ms
    func heard(_ chunk: Data, at end: TimeInterval = EchoGate.now) {
        let per = 320
        let n = chunk.count / 2
        let start = end - Double(n) / 16000
        chunk.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            var i = 0
            while i + per <= n {
                var acc = 0.0
                for j in i..<(i + per) { acc += Double(s[j]) * Double(s[j]) }
                mic.append(Frame(t: start + Double(i) / 16000, v: (acc / Double(per)).squareRoot()))
                i += per
            }
        }
        trim()
    }

    private func trim() {
        let cut = Self.now - 8
        if let i = out.firstIndex(where: { $0.t >= cut }), i > 0 { out.removeFirst(i) }
        if let i = mic.firstIndex(where: { $0.t >= cut }), i > 0 { mic.removeFirst(i) }
    }

    // ---------- ตัดสิน ----------
    /// เสียงสะท้อนที่ไมค์ควรได้ยิน ณ เวลา t (รวมหางก้อง ~0.25 วิ)
    func expectedEcho(at t: TimeInterval) -> Double {
        let src = t - delay
        var peak = 0.0
        for f in out.reversed() {
            if f.t > src + 0.02 { continue }
            if f.t < src - 0.3 { break }
            let age = max(0, src - f.t)
            peak = max(peak, f.v * (age < 0.02 ? 1 : exp(-(age - 0.02) / 0.08)))   // ±20ms + หางก้อง
        }
        return gain * peak
    }

    /// ยังมีเสียงสะท้อนค้างอยู่ไหม (Friday พูดอยู่ หรือเพิ่งหยุดไม่นาน)
    func echoActive(at t: TimeInterval = EchoGate.now) -> Bool {
        guard let last = out.last(where: { $0.v > 60 }) else { return false }
        return t < last.t + delay + 0.35
    }

    /// ผู้ใช้พูดแทรกไหม: 0.3 วิล่าสุด พลังงานไมค์มากกว่าเสียงสะท้อนที่ควรได้ยิน ≥2 เท่า (+เสียงพื้น) ติดกัน 2 ครั้ง (~0.4 วิ)
    /// เทียบพลังงานรวม ไม่ใช่ทีละช่วง: เสียงคนแทรกเข้ามาตามช่องว่างระหว่างพยางค์ของ Friday
    func isBargeIn(noise: Double, at end: TimeInterval = EchoGate.now) -> Bool {
        // ยังไม่เคยวัดห้อง (อุปกรณ์คู่ใหม่ / ตัวตัดเสียงสะท้อนเพิ่งเริ่มยังไม่ปรับตัว) → ไม่ให้แทรก ฟัง Friday ให้จบก่อน 1 ครั้ง
        guard learned > 0 else { voiceRun = 0; return false }
        let recent = mic.filter { $0.t >= end - 0.3 - 0.001 }
        guard recent.count >= 10 else { voiceRun = 0; return false }
        var eMic = 0.0, eEcho = 0.0, loud = 0
        let floor = max(noise * 2, 450)
        for f in recent {
            let echo = expectedEcho(at: f.t + Self.frame / 2)
            eMic += f.v * f.v; eEcho += echo * echo
            if f.v > max(1.5 * echo, floor) { loud += 1 }
        }
        let n = Double(recent.count)
        let voiced = eMic > 2 * eEcho + n * floor * floor && Double(loud) >= n * 0.4
        voiceRun = voiced ? voiceRun + 1 : 0
        return voiceRun >= 2
    }

    func resetRun() { voiceRun = 0 }

    /// พูดแทรกผิด (หยุด Friday แล้วไม่มีคำพูดจริง เช่น เพิ่งเร่งเสียงลำโพง) → เข้มขึ้น
    func penalize() -> String {
        gain = max(gain * 1.6, 0.05); save()
        return String(format: "echo: พูดแทรกผิด → gain %.3f", gain)
    }

    // ---------- เรียนรู้ ----------
    /// เรียกตอน Friday พูดจบแต่ละครั้ง (ถ้าไม่มีการพูดแทรก): หาความหน่วงที่ไมค์กับเสียงออกตรงกันที่สุด แล้วหาอัตราความดัง
    @discardableResult
    func learn(noise: Double, maxDelay: Double = 0.6) -> String {
        let end = Self.now, start = end - 6
        let o = out.filter { $0.t >= start && $0.t <= end }
        let m = mic.filter { $0.t >= start && $0.t <= end }
        guard o.count > 40, m.count > 40, let m0 = m.first?.t else { return "echo: ข้อมูลไม่พอ" }
        // mic เป็นช่อง 20ms ต่อเนื่อง → index ตามเวลา
        func micAt(_ t: Double) -> Double? {
            let k = Int(((t - m0) / Self.frame).rounded())
            return k >= 0 && k < m.count ? m[k].v : nil
        }
        var best = (lag: delay, corr: -1.0)
        var lag = 0.0
        while lag <= maxDelay {
            var xs: [Double] = [], ys: [Double] = []
            for f in o { if let y = micAt(f.t + lag) { xs.append(f.v); ys.append(y) } }
            let c = Self.corr(xs, ys)
            if c > best.corr { best = (lag, c) }
            lag += Self.frame
        }
        lastCorr = best.corr
        guard best.corr > 0.45 else {
            // ไม่สัมพันธ์กัน: ถ้าไมค์แทบเงียบตลอดที่ Friday พูด = เสียงสะท้อนเบามาก (ไมค์หูฟัง) → พูดแทรกได้ง่าย
            let during = o.filter { $0.v > 800 }.compactMap { micAt($0.t + delay) }.sorted()
            if during.count >= 15, during[Int(Double(during.count - 1) * 0.8)] < max(noise * 1.6, 300) {
                gain = 0.05; learned += 1; save()
                return String(format: "echo: แทบไม่มีเสียงสะท้อน (corr %.2f) → gain %.2f", best.corr, gain)
            }
            return String(format: "echo: ไม่ชัด (corr %.2f) คงค่าเดิม delay %.0fms gain %.2f", best.corr, delay * 1000, gain)
        }
        var ratios: [Double] = []
        for f in o where f.v > 800 { if let y = micAt(f.t + best.lag) { ratios.append(max(0, y - noise) / f.v) } }
        guard ratios.count >= 15 else { return "echo: เสียงออกเบาไป" }
        ratios.sort()
        let g = ratios[Int(Double(ratios.count - 1) * 0.8)]
        // ค่อยๆ ขยับ (กันครั้งเดียวผิดปกติ) · ครั้งแรกใช้ค่าที่วัดได้เลย
        delay = learned == 0 ? best.lag : delay * 0.6 + best.lag * 0.4
        gain = learned == 0 ? g : gain * 0.6 + g * 0.4
        learned += 1
        save()
        return String(format: "echo: เรียนรู้ delay %.0fms gain %.3f (corr %.2f, n=%d)", delay * 1000, gain, best.corr, learned)
    }

    static func corr(_ a: [Double], _ b: [Double]) -> Double {
        let n = Double(a.count)
        guard n > 10 else { return -1 }
        let ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
        var sab = 0.0, saa = 0.0, sbb = 0.0
        for i in 0..<a.count { let x = a[i] - ma, y = b[i] - mb; sab += x * y; saa += x * x; sbb += y * y }
        return saa > 0 && sbb > 0 ? sab / (saa * sbb).squareRoot() : -1
    }

    // ---------- จำค่าตามคู่อุปกรณ์ ----------
    func use(output: String, input: String, defaultGain: Double = 0.6) {
        let k = "echo.\(output)|\(input)"
        guard k != key else { return }
        key = k
        out = []; mic = []; voiceRun = 0
        if let d = UserDefaults.standard.dictionary(forKey: k), let dl = d["delay"] as? Double, let g = d["gain"] as? Double {
            delay = dl; gain = g; learned = d["n"] as? Int ?? 1
        } else { delay = 0.12; gain = defaultGain; learned = 0 }
    }
    private func save() { UserDefaults.standard.set(["delay": delay, "gain": gain, "n": learned], forKey: key) }
}
