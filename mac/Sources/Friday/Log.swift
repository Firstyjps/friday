import Foundation

/// log ของแอป → ~/logs/friday-app.log (อ่านได้โดยไม่ต้องเปิด Console)
enum Log {
    /// บทสนทนากับ Friday → ~/logs/friday-chat.log (ไว้ย้อนดูว่าคุยอะไรกันไป)
    static func chat(_ s: String) { append(s, to: URL(fileURLWithPath: NSHomeDirectory() + "/logs/friday-chat.log")) }

    private static let url = URL(fileURLWithPath: NSHomeDirectory() + "/logs/friday-app.log")
    private static let q = DispatchQueue(label: "friday.log")
    static func write(_ s: String) { append(s, to: url) }

    private static func append(_ s: String, to url: URL) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) | \(s)\n"
        q.async {
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
            else { try? line.write(to: url, atomically: true, encoding: .utf8) }
        }
    }
}
