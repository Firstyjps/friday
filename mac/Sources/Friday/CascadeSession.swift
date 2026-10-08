import Foundation

/// โหมด cascade (config.engine = "cascade"): ฟังเสียงเอง → ส่งทีละช่วงพูดไป server `/api/turn`
/// → server ให้ Gemini (text) ฟัง/คิด แล้วทำเสียงด้วย Gemini TTS → ส่ง event กลับมาเป็น NDJSON
/// หน้าตา event เหมือน LiveSession ทุกอย่าง → FridayController ใช้ด่านความปลอดภัย/เครื่องมือเดิมได้หมด
/// (ผลวัด + เหตุผล: Vault friday-status.md 8 ต.ค. · server: lib/cascade.mjs)
final class CascadeSession: LiveSession {
    private let id = UUID().uuidString
    private var closed = false
    private var busy = false                       // รอบคุยกำลังวิ่ง (รอ server / รอผลเครื่องมือ) → ไม่ฟังเสียงใหม่
    private var queuedTexts: [String] = []
    private var pendingTools = 0
    private var awaitingTools = false              // server ส่ง done แล้ว รอผลเครื่องมือครบ (กันตอบก่อนได้ tool ครบทุกตัว)
    private var toolResponses: [[String: Any]] = []
    private var current: Task<Void, Never>?

    // ---- VAD: ตัดช่วงพูด (PCM16 16k ทีละ 100ms) ----
    private var noiseFloor = 300.0
    private var seg: [Data] = [], preroll: [Data] = []
    private var voiced = 0, silent = 0
    private static let minSpeech = 400.0, prerollChunks = 3, endSilence = 7, maxChunks = 300, minVoiced = 3

    override func connect(token: String, config: ServerAPI.Config, extraSystem: String = "", resumeHandle: String? = nil) {
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
        let isSpeech = level > max(noiseFloor * 3, Self.minSpeech)
        if !isSpeech && seg.isEmpty {
            noiseFloor = noiseFloor * 0.95 + level * 0.05
            preroll.append(pcm16k); if preroll.count > Self.prerollChunks { preroll.removeFirst() }
            return
        }
        if seg.isEmpty { seg = preroll; preroll = [] }
        seg.append(pcm16k)
        if isSpeech { voiced += 1; silent = 0 } else { silent += 1 }
        guard silent >= Self.endSilence || seg.count >= Self.maxChunks else { return }
        let clip = seg.reduce(Data(), +), enough = voiced >= Self.minVoiced
        resetVAD()
        if enough { run(audio: clip) }
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
        start { try await ServerAPI.turn(session: self.id, audio: audio) }
    }
    private func run(json: [String: Any]) { start { try await ServerAPI.turn(session: self.id, json: json) } }

    private func start(_ open: @escaping () async throws -> URLSession.AsyncBytes) {
        busy = true
        current = Task { @MainActor [weak self] in
            guard let self else { return }
            var pending = -1
            do {
                let bytes = try await open()
                for try await line in bytes.lines {
                    if self.closed { return }
                    guard let d = line.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                    switch o["t"] as? String {
                    case "user": if let t = o["text"] as? String { self.onEvent?(.inputText(t)) }
                    case "text": if let t = o["text"] as? String { self.onEvent?(.outputText(t)) }
                    case "audio": if let b = o["b64"] as? String, let a = Data(base64Encoded: b) { self.onEvent?(.audio(a)) }
                    case "tool":
                        self.pendingTools += 1
                        self.onEvent?(.toolCall(id: o["id"] as? String ?? "", name: o["name"] as? String ?? "", args: o["args"] as? [String: Any] ?? [:]))
                    case "done": pending = o["pending"] as? Int ?? 0
                    case "error": Log.write("cascade: server error \(o["error"] ?? "")")
                    default: break
                    }
                }
            } catch {
                if self.closed || Task.isCancelled { return }
                Log.write("cascade: ผิดพลาด \(error.localizedDescription)")
            }
            if self.closed { return }
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
