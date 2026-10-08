import Foundation

/// Gemini Live API ผ่าน WebSocket ตรง (โปรโตคอลเดียวกับ @google/genai: ephemeral token → BidiGenerateContentConstrained)
class LiveSession: NSObject, URLSessionWebSocketDelegate {
    enum Event {
        case open
        case audio(Data)                  // PCM16 24kHz
        case inputText(String)            // ถอดเสียงผู้ใช้
        case outputText(String)           // ถอดเสียง Friday
        case interrupted
        case turnComplete
        case toolCall(id: String, name: String, args: [String: Any])
        case toolCancelled([String])      // ผู้ใช้พูดแทรกระหว่าง tool call → Gemini ยกเลิก
        case goAway(String)               // Gemini เตือนว่าจะปิดการเชื่อมต่อ (timeLeft)
        case closed(String)
    }

    var onEvent: ((Event) -> Void)?
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var setup: [String: Any] = [:]
    private var closedReported = false

    /// token ที่ Gemini รายงาน (รวมทั้ง session) แยกตามชนิด → คิดค่าใช้จ่าย
    var usage: [String: Int] = ["inText": 0, "inAudio": 0, "outText": 0, "outAudio": 0]
    /// usageMetadata ดิบทุก message (ไว้เทียบสูตรค่าใช้จ่ายกับบิลจริง — ดูใน selftest)
    private(set) var usageLog: [String] = []
    /// handle สำหรับต่อ session เดิมหลัง goAway (Gemini ส่ง sessionResumptionUpdate มาให้เป็นระยะ)
    private(set) var resumeHandle: String?

    /// ต่อ session ใหม่จากของเดิม → ยอดใช้งานนับต่อ
    func carryUsage(_ u: [String: Int]) { usage = u }

    func connect(token: String, config: ServerAPI.Config, extraSystem: String = "", resumeHandle: String? = nil) {
        let q = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token
        let url = URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContentConstrained?access_token=\(q)")!
        setup = ["setup": [
            "model": "models/\(config.model)",
            "generationConfig": generationConfig(config),
            "systemInstruction": ["parts": [["text": config.system + extraSystem]]],
            "tools": config.tools.any,
            "inputAudioTranscription": [:] as [String: Any],
            "outputAudioTranscription": [:] as [String: Any],
            "contextWindowCompression": ["slidingWindow": [:] as [String: Any]],
            "sessionResumption": (resumeHandle.map { ["handle": $0] } ?? [:]) as [String: Any],
        ]]
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        task = session?.webSocketTask(with: url)
        task?.maximumMessageSize = 16 * 1024 * 1024
        task?.resume()
        receive()
    }

    /// เสียงของ Friday มาจาก config.json (speechConfig) — เปลี่ยนเสียงได้โดยไม่ต้อง build ใหม่
    private func generationConfig(_ c: ServerAPI.Config) -> [String: Any] {
        var g: [String: Any] = ["responseModalities": ["AUDIO"]]
        if let sc = c.speechConfig { g["speechConfig"] = sc.any }
        return g
    }

    func urlSession(_ s: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol p: String?) {
        send(setup)
    }

    func urlSession(_ s: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith code: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        reportClosed(reason.flatMap { String(data: $0, encoding: .utf8) } ?? "code \(code.rawValue)")
    }

    private func reportClosed(_ why: String) {
        guard !closedReported else { return }
        closedReported = true
        onEvent?(.closed(why))
    }

    func close() {
        closedReported = true
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        task = nil
    }

    // ---------- ส่ง ----------
    func sendAudio(_ pcm16k: Data) {
        send(["realtimeInput": ["audio": ["data": pcm16k.base64EncodedString(), "mimeType": "audio/pcm;rate=16000"]]])
    }

    /// ไมค์ถูกปิดชั่วคราว → บอก Gemini ว่าเสียงหยุด (VAD จะไม่รอประโยคที่ค้าง) · ส่งเสียงใหม่เมื่อไหร่ก็เปิด stream ต่อเอง
    func sendAudioStreamEnd() {
        send(["realtimeInput": ["audioStreamEnd": true]])
    }

    func sendText(_ text: String) {
        send(["realtimeInput": ["text": text]])
    }

    func sendToolResponse(id: String, name: String, response: [String: Any]) {
        send(["toolResponse": ["functionResponses": [["id": id, "name": name, "response": response]]]])
    }

    private func send(_ obj: [String: Any]) {
        guard let task, let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else { return }
        task.send(.string(str)) { [weak self] err in
            if let err { DispatchQueue.main.async { self?.reportClosed("send: \(err.localizedDescription)") } }
        }
    }

    // ---------- รับ ----------
    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                DispatchQueue.main.async { self.reportClosed(err.localizedDescription) }
            case .success(let msg):
                let data: Data?
                switch msg {
                case .data(let d): data = d
                case .string(let s): data = s.data(using: .utf8)
                @unknown default: data = nil
                }
                if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    DispatchQueue.main.async { self.handle(obj) }
                }
                self.receive()
            }
        }
    }

    private func handle(_ m: [String: Any]) {
        if m["setupComplete"] != nil { onEvent?(.open) }
        if let u = m["sessionResumptionUpdate"] as? [String: Any], u["resumable"] as? Bool == true, let h = u["newHandle"] as? String, !h.isEmpty {
            resumeHandle = h
        }
        if let u = m["usageMetadata"] as? [String: Any] {
            usageLog.append("prompt=\(u["promptTokenCount"] ?? 0) response=\(u["responseTokenCount"] ?? 0) total=\(u["totalTokenCount"] ?? 0)")
            for (key, dir) in [("promptTokensDetails", "in"), ("responseTokensDetails", "out")] {
                for d in u[key] as? [[String: Any]] ?? [] {
                    let kind = (d["modality"] as? String ?? "").uppercased() == "AUDIO" ? "Audio" : "Text"
                    usage[dir + kind, default: 0] += d["tokenCount"] as? Int ?? 0
                }
            }
        }
        if let tc = m["toolCall"] as? [String: Any], let calls = tc["functionCalls"] as? [[String: Any]] {
            for c in calls {
                onEvent?(.toolCall(id: c["id"] as? String ?? "", name: c["name"] as? String ?? "", args: c["args"] as? [String: Any] ?? [:]))
            }
        }
        if let tc = m["toolCallCancellation"] as? [String: Any] { onEvent?(.toolCancelled(tc["ids"] as? [String] ?? [])) }
        if let g = m["goAway"] as? [String: Any] { onEvent?(.goAway(g["timeLeft"] as? String ?? "")) }
        guard let sc = m["serverContent"] as? [String: Any] else { return }
        if sc["interrupted"] as? Bool == true { onEvent?(.interrupted) }
        if let turn = sc["modelTurn"] as? [String: Any], let parts = turn["parts"] as? [[String: Any]] {
            for p in parts {
                if let inline = p["inlineData"] as? [String: Any], let b64 = inline["data"] as? String, let d = Data(base64Encoded: b64) {
                    onEvent?(.audio(d))
                }
            }
        }
        if let t = (sc["inputTranscription"] as? [String: Any])?["text"] as? String, !t.isEmpty { onEvent?(.inputText(t)) }
        if let t = (sc["outputTranscription"] as? [String: Any])?["text"] as? String, !t.isEmpty { onEvent?(.outputText(t)) }
        if sc["turnComplete"] as? Bool == true { onEvent?(.turnComplete) }
    }
}
