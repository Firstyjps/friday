import Foundation

/// โหมด cascade (config.engine = "cascade"): ฟังเสียงเอง → ส่งทีละช่วงพูดไป server `/api/turn`
/// → server ให้ Gemini (text) ฟัง/คิด แล้วทำเสียงด้วย Gemini TTS → ส่ง event กลับมาเป็น NDJSON
/// หน้าตา event เหมือน LiveSession ทุกอย่าง → FridayController ใช้ด่านความปลอดภัย/เครื่องมือเดิมได้หมด
/// (ผลวัด + เหตุผล: Vault friday-status.md 8 ต.ค. · server: lib/cascade.mjs)
final class CascadeSession: LiveSession {
    private let id = UUID().uuidString
    private var closed = false
    private var busy = false                       // รอบคุยกำลังวิ่ง (รอ server / รอผลเครื่องมือ) → ไม่ฟังเสียงใหม่
    override var inTurn: Bool { busy }
    private var queuedTexts: [String] = []
    private var pendingTools = 0
    private var awaitingTools = false              // server ส่ง done แล้ว รอผลเครื่องมือครบ (กันตอบก่อนได้ tool ครบทุกตัว)
    private var toolResponses: [[String: Any]] = []
    private var current: Task<Void, Never>?
    private var gen = 0
    private var extra = ""                         // system เพิ่มเติม (ความจำ/บทสนทนาล่าสุด) ไว้เปิด session ใหม่ตอน server รีสตาร์ท
    /// ตื่นด้วยคำปลุก → คลิปแรกให้ server ยืนยันด้วย Scribe ว่ามีคำปลุกจริง (ไม่มี = ตื่นผิด ปิดเงียบๆ)
    var wakeCheck = false                            // รอบที่ถูกพูดแทรกแล้ว → event ที่ค้างมาทีหลังทิ้ง

    // ---- VAD: ตัดช่วงพูด (PCM16 16k ทีละ 100ms) ----
    private var noiseFloor: Double
    private var seg: [Data] = [], preroll: [Data] = []
    private var voiced = 0, silent = 0
    private var firstSegment = true
    // ---- ข้อความสดระหว่างพูด: ส่งช่วงที่พูดไปแล้วให้ whisper ในเครื่องถอดทุก ~0.5 วิ ----
    private var segId = 0                          // ช่วงพูดปัจจุบัน (ทิ้งผลที่มาช้าของช่วงเก่า)
    private var finalSeg = -1                      // ช่วงที่ได้ข้อความจริง (Scribe) แล้ว → ไม่เอาผลชั่วคราวทับ
    private var partialBusy = false
    private var partialAt = Date.distantPast
    private static let minSpeech = 400.0, prerollChunks = 3, endSilence = 7, maxChunks = 300, minVoiced = 3
    /// คลิปแรกหลังคำปลุก: ตัดที่ 8 วิ (เสียงรบกวนต่อเนื่องเคยลากยาว 30 วิก่อน Scribe จะได้ตัดสินว่าตื่นผิด · คำสั่งจริงยาวสุดที่วัดได้ 8.6 วิ)
    private static let wakeMaxChunks = 80
    /// ปลุกแล้วยังไม่มีเสียงพูดเลย (ยังไม่ได้ส่งคลิปให้ Scribe ยืนยัน) — controller ใช้ตัดสินว่าตื่นผิด
    var awaitingWakeSpeech: Bool { wakeCheck && seg.isEmpty && !busy && !closed }

    /// noise = ระดับเสียงพื้นหลังที่หูคำปลุกเรียนรู้มาแล้ว (เริ่ม 300 แบบเดิม → เกณฑ์ 900 สูงไป ประโยคต่อจากคำปลุกหาย 8 ต.ค.)
    init(noise: Double) { noiseFloor = min(max(noise, 50), 300); super.init() }

    override func connect(token: String, config: ServerAPI.Config, extraSystem: String = "", resumeHandle: String? = nil) {
        extra = extraSystem
        Task { @MainActor in
            do {
                try await ServerAPI.cascadeOpen(session: id, extra: extraSystem)
                if !closed { onEvent?(.open) }
            } catch {
                onEvent?(.closed("cascade open: \(error.localizedDescription)"))
            }
        }
    }

    override func close() {
        closed = true
        current?.cancel(); current = nil
        let sid = id
        Task { await ServerAPI.cascadeClose(session: sid) }
    }

    override func sendAudio(_ pcm16k: Data) {
        guard !closed else { return }
        if busy { resetVAD(); return }                 // half-duplex: ระหว่าง Friday คิด/พูด ไม่รับเสียง
        let level = WakeDetector.rms(pcm16k)
        let isSpeech = level > max(min(noiseFloor * 3, noiseFloor + 1500), Self.minSpeech)
        if !isSpeech && seg.isEmpty {
            noiseFloor = noiseFloor * 0.95 + level * 0.05
            preroll.append(pcm16k); if preroll.count > Self.prerollChunks { preroll.removeFirst() }
            return
        }
        if seg.isEmpty { seg = preroll; preroll = []; segId += 1 }
        seg.append(pcm16k)
        if isSpeech { voiced += 1; silent = 0 } else { silent += 1 }
        if voiced >= Self.minVoiced, !partialBusy, Date().timeIntervalSince(partialAt) > 0.5 { partial(seg.reduce(Data(), +)) }
        // ช่วงแรกหลังคำปลุก: คนมักเว้นจังหวะหลัง "ฟรายเดย์" → รอเงียบนานขึ้น (1.3 วิ) จะได้รวมเป็นประโยคเดียว
        // พูดยาว (>2.5 วิ) = กำลังอธิบาย มักหยุดคิดกลางประโยค → รอเงียบ 1.4 วิ (เดิม 0.7 วิ ตัดกลางประโยคแล้วที่พูดต่อหาย 9 ต.ค.)
        let endSilence = firstSegment && voiced < 15 ? 13 : voiced >= 25 ? 14 : Self.endSilence
        guard silent >= endSilence || seg.count >= (wakeCheck ? Self.wakeMaxChunks : Self.maxChunks) else { return }
        firstSegment = false
        let clip = seg.reduce(Data(), +), enough = voiced >= Self.minVoiced
        // เก็บเหตุผลที่ตัดไว้จูน endSilence/minVoiced จาก log จริง (รีวิว 9 ต.ค.: ยังไม่มีข้อมูลพอ)
        Log.write("vad: ตัด\(silent >= endSilence ? "เพราะเงียบ \(endSilence)" : "เพราะยาวเกิน") voiced=\(voiced) chunks=\(seg.count)\(enough ? "" : " → สั้นไป ทิ้ง")")
        resetVAD()
        if enough { partial(clip); run(audio: clip) }      // ถอดทั้งช่วงอีกรอบ (เร็วกว่า Scribe) ให้ข้อความสดครบก่อนข้อความจริงมา
    }

    /// ปิดไมค์ชั่วคราว → ช่วงที่พูดค้างไว้ส่งไปเลยถ้ายาวพอ
    override func sendAudioStreamEnd() {
        guard !busy, voiced >= Self.minVoiced else { resetVAD(); return }
        let clip = seg.reduce(Data(), +)
        resetVAD()
        run(audio: clip)
    }

    override func sendText(_ text: String) {
        guard !closed else { return }
        if busy { queuedTexts.append(text); return }
        run(json: ["text": text])
    }

    override func sendToolResponse(id: String, name: String, response: [String: Any]) {
        guard !closed else { return }
        toolResponses.append(["id": id, "name": name, "response": response])
        flushTools()
    }

    private func flushTools() {
        guard awaitingTools, toolResponses.count >= pendingTools else { return }
        let rs = toolResponses
        toolResponses = []; pendingTools = 0; awaitingTools = false
        run(json: ["toolResponses": rs])
    }

    private func resetVAD() { seg = []; voiced = 0; silent = 0 }

    // ---------- หนึ่งรอบ ----------
    private func run(audio: Data) {
        Log.write("cascade: ส่งเสียง \(String(format: "%.1f", Double(audio.count) / 32000))s")
        let wake = wakeCheck; wakeCheck = false
        start(seg: segId) { try await ServerAPI.turn(session: self.id, audio: audio, wake: wake) }
    }

    private func partial(_ pcm: Data) {
        partialBusy = true; partialAt = Date()
        let sid = segId
        Task { @MainActor [weak self] in
            let t = await ServerAPI.partial(pcm: pcm)
            guard let self else { return }
            self.partialBusy = false
            if !self.closed, sid == self.segId, sid > self.finalSeg, !t.isEmpty { self.onEvent?(.inputPartial(t)) }
        }
    }
    private func run(json: [String: Any]) { start { try await ServerAPI.turn(session: self.id, json: json) } }

    /// ผู้ใช้พูดแทรก: ตัดสาย (server หยุดทำเสียงที่เหลือ) แล้วฟังต่อทันที · รอผลเครื่องมืออยู่ = ยกเลิกไม่ได้ ปล่อยไว้
    override func interrupt() {
        guard busy, !awaitingTools, current != nil else { return }
        gen += 1
        current?.cancel(); current = nil
        pendingTools = 0; toolResponses = []
        busy = false
        resetVAD()
        onEvent?(.interrupted)
        onEvent?(.turnComplete)
    }

    private func start(seg: Int = -1, retried: Bool = false, _ open: @escaping () async throws -> URLSession.AsyncBytes) {
        busy = true
        gen += 1
        let myGen = gen
        current = Task { @MainActor [weak self] in
            guard let self else { return }
            var pending = -1
            var failed: String?, gotAny = false
            do {
                let bytes = try await open()
                for try await line in bytes.lines {
                    if self.closed || self.gen != myGen { return }
                    guard let d = line.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                    if o["t"] as? String != "error" { gotAny = true }
                    switch o["t"] as? String {
                    case "user": if let t = o["text"] as? String { self.finalSeg = max(self.finalSeg, seg); self.onEvent?(.inputText(t)) }
                    case "text": if let t = o["text"] as? String { self.onEvent?(.outputText(t)) }
                    case "audio": if let b = o["b64"] as? String, let a = Data(base64Encoded: b) { self.onEvent?(.audio(a)) }
                    case "tool":
                        self.pendingTools += 1
                        self.onEvent?(.toolCall(id: o["id"] as? String ?? "", name: o["name"] as? String ?? "", args: o["args"] as? [String: Any] ?? [:]))
                    case "done":
                        pending = o["pending"] as? Int ?? 0
                        if o["falseWake"] as? Bool == true { self.onEvent?(.falseWake); return }
                    case "error": Log.write("cascade: server error \(o["error"] ?? "")"); failed = o["error"] as? String ?? "server error"
                    default: break
                    }
                }
            } catch {
                if self.closed || Task.isCancelled || self.gen != myGen { return }
                Log.write("cascade: ผิดพลาด \(error.localizedDescription)")
                failed = error.localizedDescription
            }
            if self.closed || self.gen != myGen { return }
            // server รีสตาร์ท (session หาย) หรือเน็ตหลุดก่อนได้อะไรเลย → เปิด session ใหม่แล้วส่งรอบนี้ซ้ำ 1 ครั้ง
            // (เดิมจบรอบเงียบๆ ทุกประโยคที่พูดหายจน idle 20 วิ — รีวิว 9 ต.ค.)
            if let f = failed, !gotAny, !retried {
                Log.write("cascade: รอบล้ม (\(f)) → เปิด session ใหม่แล้วลองอีกครั้ง")
                for attempt in 0..<4 {
                    if self.closed || self.gen != myGen { return }
                    do { try await ServerAPI.cascadeOpen(session: self.id, extra: self.extra); self.start(seg: seg, retried: true, open); return }
                    catch { if attempt < 3 { try? await Task.sleep(for: .seconds(1.5)) } }
                }
            }
            if failed != nil, !gotAny { self.onEvent?(.notice("ติดต่อ server ไม่ได้ ประโยคเมื่อกี้หาย — พูดใหม่อีกครั้งนะ")) }
            if pending > 0 && self.pendingTools > 0 {              // รอแอปทำเครื่องมือ → ครบแล้วเริ่มรอบต่อ
                self.awaitingTools = true; self.flushTools(); return
            }
            self.pendingTools = 0; self.toolResponses = []
            self.busy = false
            self.onEvent?(.turnComplete)
            if !self.queuedTexts.isEmpty { self.sendText(self.queuedTexts.removeFirst()) }
        }
    }
}
