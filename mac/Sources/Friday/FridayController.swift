import AVFoundation
import Foundation
import SwiftUI

/// สมองของแอป: หลับ (รอคำปลุก) → ต่อ Gemini → คุย → เงียบนาน → กลับไปหลับ
/// logic เดียวกับหน้าเว็บโหมดห้อง (public/app.js) — prompt/tools/คำยืนยันมาจาก config.json ของ server
@MainActor
final class FridayController: ObservableObject {
    enum Phase: Equatable { case starting, sleeping, connecting, live, error(String) }

    struct Message: Identifiable {
        enum Kind { case me, fri, sys, confirm }
        var id = UUID()
        var kind: Kind
        var text: String
        var jobId: String? = nil
    }

    @Published var phase: Phase = .starting
    @Published var speaking = false
    @Published var messages: [Message] = []
    @Published var earMuted = false
    @Published var inputName = ""
    @Published var outputName = ""

    var onPhaseChanged: ((Phase) -> Void)?
    var onWantsPanel: ((Bool) -> Void)?

    private let audio = AudioIO()
    private var live: LiveSession?
    private var config: ServerAPI.Config?
    private var affirm: NSRegularExpression?
    private var negate: NSRegularExpression?
    private var farewell: NSRegularExpression?
    private var userTurn = ""                     // ประโยคล่าสุดของผู้ใช้ (ไว้จับคำลา)
    private var friTurn = ""                      // คำตอบล่าสุดของ Friday (บางทีโมเดลพิมพ์ชื่อ tool ออกมาแทนการเรียก)
    private var ending = false
    private var pendingMute = false
    private let convo = UUID().uuidString          // หนึ่งรอบเปิดแอป = หนึ่ง Claude session (จำงานก่อนหน้าได้)

    private var connectQueue: [Data] = []
    private var speakEndedAt = Date.distantPast
    private var lastActivity = Date()
    private var meIndex: Int?, friIndex: Int?
    private var confirms: [String: (task: String, heard: String)] = [:]
    private var pendingResults: [String] = []
    private var activeJobs = 0

    // VAD (คำปลุก)
    private var noiseFloor = 300.0, voiced = 0, silent = 0, checking = false
    private var seg: [Data] = [], preroll: [Data] = []
    private var peak = 0.0, frames = 0

    // ---------- เริ่มต้น ----------
    func start() {
        Task {
            Log.write("start: ขอสิทธิ์ไมค์ (สถานะเดิม \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue))")
            startTimers()                               // ping ตั้งแต่ต้น → เห็นสถานะใน ~/logs/friday.log แม้ค้างกลางทาง
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                setPhase(.error("ไม่ได้รับสิทธิ์ใช้ไมค์ — System Settings → Privacy & Security → Microphone → เปิด Friday"))
                return
            }
            Log.write("start: ได้สิทธิ์ไมค์ → โหลด config")
            while config == nil {                       // รอ server (LaunchAgent) พร้อม
                do { config = try await ServerAPI.config() }
                catch { Log.write("start: config error \(error)"); try? await Task.sleep(for: .seconds(2)) }
            }
            affirm = try? NSRegularExpression(pattern: config!.affirm, options: .caseInsensitive)
            negate = try? NSRegularExpression(pattern: config!.negate, options: .caseInsensitive)
            farewell = config!.farewell.flatMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
            audio.onMic = { [weak self] chunk in Task { @MainActor in self?.onMic(chunk) } }
            audio.onSpeakingChanged = { [weak self] s in Task { @MainActor in
                self?.speaking = s; self?.lastActivity = Date()
                if !s { self?.speakEndedAt = Date() }
            } }
            audio.outputPriority = config!.outputPriority ?? []
            audio.inputPriority = config!.inputPriority ?? []
            audio.onDevicesChanged = { [weak self] in Task { @MainActor in
                guard let self else { return }
                self.inputName = self.audio.inputName; self.outputName = self.audio.outputName; self.onPhaseChanged?(self.phase)
            } }
            audio.onFailure = { [weak self] in Task { @MainActor in await self?.openAudio() } }
            await openAudio()
            let woke = await ServerAPI.hello()          // ถูกเปิดเพราะหูเบื้องหลังของ server ได้ยิน "Friday"?
            if woke { wake(prebuffer: [], greet: true) }
        }
    }

    /// เปิดระบบเสียง วนลองทุก 5 วิจนสำเร็จ (ตอนเปิดเครื่อง ลำโพง/จอนอก/ไมค์ อาจยังไม่พร้อม)
    private var openingAudio = false
    private func openAudio() async {
        guard !openingAudio else { return }
        openingAudio = true; defer { openingAudio = false }
        var attempt = 0
        while true {
            do { try audio.start(); break } catch {
                attempt += 1
                Log.write("audio: เปิดไม่สำเร็จ ครั้งที่ \(attempt): \(error)")
                phase = .starting
                if attempt == 12 { setPhase(.error("เปิดระบบเสียงไม่ได้ (ลองมา 1 นาทีแล้ว ยังลองต่อ): \(error.localizedDescription)")); onWantsPanel?(true) }
                try? await Task.sleep(for: .seconds(5))
            }
        }
        inputName = audio.inputName; outputName = audio.outputName
        Log.write("start: พร้อม 🎤 \(inputName) · 🔊 \(outputName) (aec=\(audio.aecEnabled))")
        if live == nil { setPhase(.sleeping) }
    }

    private func startTimers() {
        // บอก server ว่าแอปฟังอยู่ (หูเบื้องหลังจะได้ไม่ปลุกซ้อน) + debug ระดับเสียง
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await ServerAPI.ping(["app": "mac", "phase": "\(self.phase)", "track": "live", "ctx": "running",
                                      "input": self.audio.inputName, "frames": self.frames, "peak": Int(self.peak),
                                      "noise": Int(self.noiseFloor), "muted": self.earMuted])
                self.frames = 0; self.peak = 0
            }
        }
        // เงียบ/ไม่มีงานค้าง นานเกิน idleMs → กลับไปรอคำปลุก
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .live else { return }
                if self.speaking || !self.confirms.isEmpty || !self.pendingResults.isEmpty || self.activeJobs > 0 {
                    self.lastActivity = Date(); return
                }
                if Date().timeIntervalSince(self.lastActivity) * 1000 > (self.config?.idleMs ?? 20000) {
                    self.sys("💤 พักก่อน — เรียก \"Friday\" เมื่อต้องการ")
                    self.endSession()
                }
            }
        }
    }

    // ---------- ไมค์ ----------
    private func onMic(_ chunk: Data) {
        switch phase {
        case .live:
            // ไม่มีตัวตัดเสียงสะท้อน (เช่น เสียงออกลำโพงจอ + ไมค์หูฟัง) → ไมค์จะได้ยิน Friday แล้ววนลูปคุยกับตัวเอง
            // จึงไม่ส่งเสียงไมค์ระหว่าง Friday พูด + ช่วงหางเสียง 0.8 วิ (แลกกับการพูดแทรกไม่ได้ในโหมดนี้)
            if !audio.aecEnabled && (speaking || Date().timeIntervalSince(speakEndedAt) < 0.8) { return }
            live?.sendAudio(chunk)
        case .connecting: connectQueue.append(chunk)
        case .sleeping: if !earMuted { wakeListen(chunk) }
        default: break
        }
    }

    private func rms(_ d: Data) -> Double {
        d.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            var acc = 0.0
            for v in s { acc += Double(v) * Double(v) }
            return (acc / Double(max(1, s.count))).squareRoot()
        }
    }

    private func wakeListen(_ chunk: Data) {
        let level = rms(chunk); frames += 1; peak = max(peak, level)
        let isSpeech = level > max(noiseFloor * 3, 400)
        if !isSpeech && seg.isEmpty {
            noiseFloor = noiseFloor * 0.95 + level * 0.05
            preroll.append(chunk); if preroll.count > 3 { preroll.removeFirst() }
            return
        }
        if seg.isEmpty { seg = preroll; preroll = [] }
        seg.append(chunk)
        if isSpeech { voiced += 1; silent = 0 } else { silent += 1 }
        if silent >= 6 || seg.count >= 40 {
            let clip = seg, enough = voiced >= 3
            seg = []; voiced = 0; silent = 0
            if enough && !checking { checkWake(clip) }
        }
    }

    private func checkWake(_ clip: [Data]) {
        checking = true
        Task {
            defer { checking = false }
            guard let r = try? await ServerAPI.wake(pcm: clip.reduce(Data(), +)) else { return }
            if r.wake && phase == .sleeping {
                sys("👂 ได้ยิน: \(r.text)"); Log.write("wake: \(r.text)")
                wake(prebuffer: clip, greet: false)      // ส่งเสียงช่วงที่ปลุกให้ Gemini ด้วย ("Friday เปิด Chrome")
            }
        }
    }

    // ---------- session ----------
    /// เริ่มคุย: จากคำปลุก / เมนู / friday:// URL
    func wake(prebuffer: [Data], greet: Bool) {
        guard phase == .sleeping, let config else { return }
        audio.chime()
        setPhase(.connecting)
        connectQueue = prebuffer
        onWantsPanel?(true)
        Task {
            do {
                let token = try await ServerAPI.token()
                let s = LiveSession()
                s.onEvent = { [weak self] e in MainActor.assumeIsolated { self?.onLive(e) } }
                live = s
                s.connect(token: token, config: config)
                pendingGreeting = greet
            } catch {
                sys("⚠️ เชื่อมต่อไม่ได้: \(error.localizedDescription)")
                endSession()
            }
        }
    }

    private var pendingGreeting = false

    func toggle() {
        switch phase {
        case .live, .connecting: endSession()
        case .sleeping: wake(prebuffer: [], greet: true)
        default: break
        }
    }

    /// Friday ขอจบเอง (ผู้ใช้บอกลา/ให้หยุดฟัง) → รอพูดลาให้จบก่อน แล้วค่อยปิด (ไม่เกิน 10 วิ)
    private func endAfterSpeech(mute: Bool) {
        guard !ending else { if mute { pendingMute = true }; return }
        ending = true
        let t0 = Date()
        func tick() {
            guard phase == .live || phase == .connecting else { return }
            let quiet = !speaking && Date().timeIntervalSince(t0) > 1.5
            if quiet || Date().timeIntervalSince(t0) > 10 {
                Log.write("session: Friday จบเอง\(mute ? " + ปิดหู" : "")")
                endSession()
                if mute || pendingMute { pendingMute = false; setEarMuted(true) }
                onWantsPanel?(false)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { tick() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { tick() }
    }

    func endSession() {
        Log.write("session: end")
        ending = false; userTurn = ""
        live?.close(); live = nil
        audio.flush()
        meIndex = nil; friIndex = nil; connectQueue = []
        if case .error = phase { return }
        setPhase(.sleeping)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            if self?.phase == .sleeping { self?.onWantsPanel?(false) }
        }
    }

    private func onLive(_ e: LiveSession.Event) {
        lastActivity = Date()
        switch e {
        case .open:
            Log.write("session: open")
            setPhase(.live)
            for c in connectQueue { live?.sendAudio(c) }
            connectQueue = []
            if pendingGreeting, let g = config?.greeting { live?.sendText(g) }
            pendingGreeting = false
        case .audio(let d):
            audio.play(pcm16: d)
        case .interrupted:
            audio.flush()
        case .inputText(let t):
            if let i = meIndex { messages[i].text += t } else { messages.append(.init(kind: .me, text: t)); meIndex = messages.count - 1 }
            friIndex = nil
            userTurn += t
            for k in confirms.keys { confirms[k]?.heard += t }     // เก็บเสียงผู้ใช้หลังถามยืนยัน
        case .outputText(let t):
            friTurn += t
            if let i = friIndex { messages[i].text += t } else { messages.append(.init(kind: .fri, text: t)); friIndex = messages.count - 1 }
            meIndex = nil
        case .turnComplete:
            // บันทึกบทสนทนาที่คุยกับ Friday จริง (หลังปลุกแล้วเท่านั้น — เสียงที่ได้ยินทั่วไปไม่ถูกบันทึก)
            if !userTurn.isEmpty { Log.chat("🧑 \(userTurn)") }
            if !friTurn.isEmpty { Log.chat("🤖 \(friTurn)") }
            meIndex = nil; friIndex = nil
            // ตัวสำรอง: ผู้ใช้พูดคำลาแต่ Gemini ไม่เรียก end_conversation → ปิดเองหลัง Friday พูดจบ
            if !ending, friTurn.contains("stop_listening") { endAfterSpeech(mute: true) }
            else if !ending, confirms.isEmpty, activeJobs == 0, matches(farewell, userTurn) || friTurn.contains("end_conversation") { endAfterSpeech(mute: false) }
            userTurn = ""; friTurn = ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.flushResults() }
        case .toolCall(let id, let name, let args):
            if name == "run_on_mac" { runOnMac(id: id, name: name, task: args["task"] as? String ?? "") }
            else if name == "end_conversation" || name == "stop_listening" {
                live?.sendToolResponse(id: id, name: name, response: ["status": "ok"])
                endAfterSpeech(mute: name == "stop_listening")
            }
            else if name == "confirm_task" { confirmTask(id: id, name: name, jobId: args["job_id"] as? String ?? "", approve: args["approve"] as? Bool ?? false) }
        case .closed(let why):
            Log.write("session: closed \(why)")
            if phase == .live || phase == .connecting {
                sys("ปิดการเชื่อมต่อ\(why.isEmpty ? "" : ": \(why)")")
                endSession()
            }
        }
    }

    // ---------- tools ----------
    private func runOnMac(id: String, name: String, task: String) {
        let idx = sys("🖥️ สั่ง Mac: \(task)")
        Task {
            var resp: [String: Any]
            do { resp = jobToResponse(try await ServerAPI.runOnMac(task: task, convo: convo), at: idx) }
            catch { update(idx, text: "⚠️ ส่งงานไม่ได้: \(error.localizedDescription)"); resp = ["status": "error", "result": error.localizedDescription] }
            live?.sendToolResponse(id: id, name: name, response: resp)
        }
    }

    private func jobToResponse(_ job: ServerAPI.Job, at idx: UUID) -> [String: Any] {
        switch job.status {
        case "running":
            update(idx, text: "⏳ Mac กำลังทำ: \(job.task)")
            poll(job.id, at: idx)
            return ["status": "running", "note": "งานยังไม่เสร็จ ผลจะส่งตามมาภายหลัง"]
        case "needs_confirmation":
            update(idx, text: "⚠️ ต้องยืนยัน: \(job.task)", kind: .confirm, jobId: job.id)
            confirms[job.id] = (job.task, "")
            return ["status": "needs_confirmation", "job_id": job.id, "task": job.task,
                    "note": "งานนี้เสี่ยง ทวนงานให้ผู้ใช้ฟังแล้วถามว่ายืนยันไหม รอผู้ใช้ตอบก่อนเรียก confirm_task"]
        default:
            update(idx, text: "\(["done": "✅", "cancelled": "🚫"][job.status] ?? "⚠️") \(job.task)")
            return ["status": job.status, "result": job.result ?? ""]
        }
    }

    private func poll(_ jobId: String, at idx: UUID) {
        activeJobs += 1
        Task {
            defer { activeJobs -= 1 }
            while true {
                try? await Task.sleep(for: .seconds(3))
                guard let job = try? await ServerAPI.job(jobId), job.status != "running" else { continue }
                update(idx, text: "\(job.status == "done" ? "✅" : "⚠️") \(job.task)")
                pendingResults.append("[ผลจาก Mac] งาน \"\(job.task)\" \(job.status == "done" ? "เสร็จแล้ว" : "ผิดพลาด"): \(job.result ?? "")")
                flushResults()
                return
            }
        }
    }

    /// ส่งผลงานนานให้ Friday พูด ตอนที่ไม่ได้พูดทับ
    private func flushResults() {
        guard phase == .live, !pendingResults.isEmpty, !speaking else { return }
        live?.sendText(pendingResults.removeFirst())
    }

    private func matches(_ re: NSRegularExpression?, _ s: String) -> Bool {
        guard let re else { return false }
        return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    private func confirmTask(id: String, name: String, jobId: String, approve: Bool) {
        Task {
            var resp: [String: Any]
            if let c = confirms[jobId] {
                // ผู้ใช้ต้องพูดคำยืนยันเองจริง (เช็คจากเสียงผู้ใช้ ไม่เชื่อ Gemini อย่างเดียว)
                if approve && !(matches(affirm, c.heard) && !matches(negate, c.heard)) {
                    resp = ["status": "not_confirmed", "result": "ยังไม่ได้ยินผู้ใช้พูดยืนยันชัดเจน ให้ถามผู้ใช้อีกครั้ง"]
                } else {
                    resp = await decide(jobId, approve: approve, via: "เสียง")
                }
            } else {
                resp = ["status": "error", "result": "ไม่พบงานที่รอยืนยัน (อาจยืนยัน/ยกเลิกไปแล้ว หรือหมดเวลา)"]
            }
            live?.sendToolResponse(id: id, name: name, response: resp)
        }
    }

    /// ยืนยัน/ยกเลิกจริงที่ server — จากปุ่มบนหน้าต่าง หรือจาก confirm_task (ผ่านเช็คเสียงแล้ว)
    @discardableResult
    func decide(_ jobId: String, approve: Bool, via: String) async -> [String: Any] {
        guard let c = confirms.removeValue(forKey: jobId) else { return ["status": "error", "result": "ไม่พบงาน"] }
        let idx = messages.first { $0.jobId == jobId }?.id ?? sys("")
        update(idx, text: "\(approve ? "▶️ ยืนยันแล้ว" : "🚫 ยกเลิก") (\(via)): \(c.task)", kind: .sys)
        do {
            let job = try await ServerAPI.confirm(id: jobId, approve: approve)
            if via == "ปุ่ม" {                          // Gemini ไม่รู้ว่ากดปุ่ม → แจ้งให้รู้
                if job.status == "running" { poll(job.id, at: idx) }
                else { pendingResults.append("[ผลจาก Mac] งาน \"\(job.task)\" \(approve ? "ผู้ใช้กดยืนยันแล้ว ผล: \(job.result ?? "")" : "ผู้ใช้กดยกเลิกแล้ว")"); flushResults() }
                return [:]
            }
            return approve ? jobToResponse(job, at: idx) : ["status": "cancelled", "result": "ยกเลิกงานแล้ว"]
        } catch {
            return ["status": "error", "result": error.localizedDescription]
        }
    }

    // ---------- helpers ----------
    @discardableResult
    private func sys(_ text: String) -> UUID {
        let m = Message(kind: .sys, text: text)
        messages.append(m)
        if messages.count > 200 { messages.removeFirst(messages.count - 200); meIndex = nil; friIndex = nil }
        return m.id
    }

    private func update(_ id: UUID, text: String, kind: Message.Kind? = nil, jobId: String? = nil) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[i].text = text
        if let kind { messages[i].kind = kind }
        if kind != nil { messages[i].jobId = jobId }
    }

    private func setPhase(_ p: Phase) {
        phase = p
        onPhaseChanged?(p)
    }

    func toggleEar() { setEarMuted(!earMuted) }

    /// ปิดหู = ปล่อยไมค์จริง (ไม่ใช่แค่ไม่สนใจเสียง) · เปิดหู = เปิดไมค์กลับ
    func setEarMuted(_ mute: Bool) {
        guard mute != earMuted else { return }
        earMuted = mute; seg = []; voiced = 0; silent = 0
        if mute {
            if phase == .live || phase == .connecting { endSession() }
            audio.pauseInput()
        } else {
            Task { try? audio.resumeInput(); if audio.inputPaused == false { inputName = audio.inputName; outputName = audio.outputName } }
        }
        onPhaseChanged?(phase)
    }

    /// แอปกำลังปิด → ปล่อยไมค์ + บอก server ให้ปิดหูสำรองด้วย (จนกว่าจะเปิดแอปใหม่)
    func shutdown() {
        live?.close()
        audio.pauseInput()
        ServerAPI.quitSync()
    }
}
