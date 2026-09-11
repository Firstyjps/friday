import Foundation

/// `Friday --selftest` — ทดสอบ server + Gemini Live ผ่าน WebSocket โดยไม่ใช้ไมค์ (ส่งข้อความแทนเสียง)
@MainActor
enum SelfTest {
    static func run() {
        Task {
            do {
                let cfg = try await ServerAPI.config()
                print("config ok: model=\(cfg.model) tools=\(String(describing: cfg.tools.any).count) chars")
                let token = try await ServerAPI.token()
                print("token ok")
                let s = LiveSession()
                var audioBytes = 0, text = "", tool = ""
                s.onEvent = { e in
                    switch e {
                    case .open: print("setupComplete ✅"); s.sendText("ช่วยนับหน่อยว่าบนเดสก์ท็อปมีกี่โฟลเดอร์ ตอบแค่เรียก tool")
                    case .audio(let d): audioBytes += d.count
                    case .outputText(let t): text += t
                    case .toolCall(let id, let name, let args):
                        tool = "\(name) \(args)"; print("toolCall ✅ \(tool)")
                        s.sendToolResponse(id: id, name: name, response: ["status": "done", "result": "มี 33 โฟลเดอร์ (selftest)"])
                    case .turnComplete where !tool.isEmpty:
                        print("audio bytes=\(audioBytes) text=\(text)"); s.close(); exit(0)
                    case .closed(let why): print("closed: \(why)"); exit(tool.isEmpty ? 1 : 0)
                    default: break
                    }
                }
                s.connect(token: token, config: cfg)
                try await Task.sleep(for: .seconds(40)); print("timeout audio=\(audioBytes) text=\(text) tool=\(tool)"); exit(2)
            } catch { print("error: \(error)"); exit(1) }
        }
    }
}
