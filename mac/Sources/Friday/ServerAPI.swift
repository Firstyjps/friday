import Foundation

/// เชื่อม server ของ Friday (localhost:4850) — ใช้ endpoint เดียวกับหน้าเว็บ
/// (token ของ Gemini, สั่งงาน Mac, ยืนยันงาน, เช็คคำปลุก)
enum ServerAPI {
    static let base = URL(string: "http://127.0.0.1:4850")!

    struct Job: Decodable {
        let id: String
        let status: String          // running | done | error | needs_confirmation | cancelled
        let result: String?
        let reason: String?         // ทำไมต้องยืนยัน (needs_confirmation)
        let task: String
    }

    struct Config: Decodable {
        let model: String
        let system: String
        let greeting: String
        let idleMs: Double
        let affirm: String
        let negate: String
        let tools: JSONValue
        var outputPriority: [String]? = nil
        var inputPriority: [String]? = nil
        var farewell: String? = nil
        var stopWords: String? = nil
        var speechConfig: JSONValue? = nil
        var serverTools: [String]? = nil
        var maxSessionSec: Double? = nil
        var actionTools: [String]? = nil     // เครื่องมือที่ลงมือทำ → ต้องตามหลังเสียงผู้ใช้
    }

    enum APIError: LocalizedError {
        case http(Int, String)
        var errorDescription: String? {
            if case let .http(code, body) = self { return "server \(code): \(body)" }
            return nil
        }
    }

    private static func request(_ path: String, method: String = "GET", json: Any? = nil,
                                raw: Data? = nil, timeout: TimeInterval = 30) async throws -> Data {
        var req = URLRequest(url: base.appending(path: path), timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("1", forHTTPHeaderField: "X-Friday")   // ด่านกัน CSRF ของ server
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        } else if let raw {
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            req.httpBody = raw
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) || code == 409 else {
            throw APIError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    static func config() async throws -> Config {
        try JSONDecoder().decode(Config.self, from: try await request("/config.json"))
    }

    static func token() async throws -> String {
        let obj = try JSONSerialization.jsonObject(with: try await request("/api/token", method: "POST", json: [:])) as? [String: Any]
        guard let t = obj?["token"] as? String else { throw APIError.http(0, "no token") }
        return t
    }

    /// forceConfirm: แอปไม่ได้ยินผู้ใช้สั่งงานนี้ → ให้ server กักไว้ถามยืนยันก่อน
    static func runOnMac(task: String, convo: String, forceConfirm: Bool = false) async throws -> Job {
        try JSONDecoder().decode(Job.self, from: try await request("/api/mac", method: "POST", json: ["task": task, "convo": convo, "confirm": forceConfirm], timeout: 60))
    }

    static func confirm(id: String, approve: Bool) async throws -> Job {
        try JSONDecoder().decode(Job.self, from: try await request("/api/mac/\(id)/confirm", method: "POST", json: ["approve": approve], timeout: 60))
    }

    static func job(_ id: String) async throws -> Job {
        try JSONDecoder().decode(Job.self, from: try await request("/api/mac/\(id)"))
    }

    /// ส่งเสียงช่วงที่มีคนพูด (PCM16 16kHz mono) ให้ whisper ในเครื่องเช็คคำว่า Friday
    static func wake(pcm: Data) async throws -> (wake: Bool, text: String) {
        let obj = try JSONSerialization.jsonObject(with: try await request("/api/wake", method: "POST", raw: pcm)) as? [String: Any]
        return (obj?["wake"] as? Bool ?? false, obj?["text"] as? String ?? "")
    }

    /// บอก server ว่าแอปยังฟังอยู่ (หูเบื้องหลังของ server จะได้ไม่ปลุกซ้ำ) · wake=true ถ้าแอปถูกเปิดเพราะหูเบื้องหลังได้ยินคำปลุก
    static func hello() async -> Bool {
        guard let data = try? await request("/api/room-hello", method: "POST", json: [:]),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return obj["wake"] as? Bool ?? false
    }

    /// ตอนแอปปิด (ต้องเสร็จก่อน process จบ) → server ปิดหูสำรองจนกว่าแอปจะเปิดใหม่
    static func quitSync() { postSync("/api/app-quit") }

    /// POST แบบรอให้เสร็จ (ใช้เฉพาะตอน process กำลังจะจบ)
    static func postSync(_ path: String, json: [String: Any] = [:]) {
        var req = URLRequest(url: base.appending(path: path), timeoutInterval: 2)
        req.httpMethod = "POST"; req.setValue("1", forHTTPHeaderField: "X-Friday")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: json)
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 2)
    }

    /// ความจำ + บทสนทนาล่าสุด → ต่อท้าย system prompt ตอนเริ่มคุย
    static func contextText() async -> String {
        guard let data = try? await request("/api/context"),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        var out = ""
        if let m = o["memory"] as? String, !m.isEmpty { out += "\n\nความจำ (สิ่งที่เคยจดไว้):\n\(m)" }
        if let r = o["recent"] as? String, !r.isEmpty { out += "\n\nบทสนทนาล่าสุด (3 วัน):\n\(r)" }
        if let sc = o["shortcuts"] as? String, !sc.isEmpty { out += "\n\nShortcuts ที่สั่งได้: \(sc)" }
        return out
    }

    /// tools ที่ server ทำให้ (remember / vault_lookup / get_usage)
    static func tool(_ name: String, args: [String: Any]) async -> [String: Any] {
        guard let data = try? await request("/api/tool/\(name)", method: "POST", json: args),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ["ok": false, "result": "server ไม่ตอบ"] }
        return o
    }

    static func reportUsage(_ u: [String: Any]) async {
        _ = try? await request("/api/usage", method: "POST", json: u)
    }

    static func usageLine() async -> String? {
        guard let data = try? await request("/api/usage"),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return "เดือนนี้ \(o["minutes"] ?? 0) นาที · ≈ ฿\(o["thb"] ?? 0) ($\(o["usd"] ?? 0))"
    }

    static func ping(_ info: [String: Any]) async {
        _ = try? await request("/api/ping", method: "POST", json: info)
    }
}

/// JSON แบบไม่รู้โครงสร้างล่วงหน้า (tools ใน config.json ส่งต่อให้ Gemini ตรงๆ)
enum JSONValue: Decodable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a): return a.map(\.any)
        case .object(let o): return o.mapValues(\.any)
        }
    }
}
