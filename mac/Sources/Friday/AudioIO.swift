import AVFoundation
import CoreAudio
import ObjCTry

/// ไมค์ + ลำโพงของ Friday
/// - เลือกอุปกรณ์เองตามลำดับใน config.json อันไหนเปิดไม่ได้ข้ามไปตัวถัดไป (ไม่เปลี่ยน default ของทั้งเครื่อง)
/// - แยก engine ไมค์ / engine ลำโพง: บน Mac engine ตัวเดียวใช้คนละอุปกรณ์ไม่ได้ (-10851)
/// - ถ้าอุปกรณ์ที่อยากใช้อันดับแรกเป็น default ทั้งคู่ → ลอง voice processing ของ Apple (ตัดเสียงสะท้อน) บน engine เดียวก่อน
final class AudioIO {
    /// ไมค์ทุก ~100ms: PCM16 16kHz mono
    var onMic: ((Data) -> Void)?
    /// เปลี่ยนสถานะกำลังพูด/เงียบ
    var onSpeakingChanged: ((Bool) -> Void)?
    /// ระบบเสียงพังระหว่างทาง (เลือกใหม่แล้วเปิดไม่ได้) → ให้ controller วนลองใหม่
    var onFailure: (() -> Void)?
    /// ใช้อุปกรณ์ชุดใหม่แล้ว (ไว้อัปเดตเมนู)
    var onDevicesChanged: (() -> Void)?
    /// มีการเสียบ/ถอดอุปกรณ์ (ใช้ปลุก controller ที่กำลังรอไมค์ให้ลองใหม่ทันที)
    var onHardwareChange: (() -> Void)?

    /// ลำดับอุปกรณ์ที่อยากใช้ (ชื่อบางส่วน) — มาจาก config.json
    var outputPriority: [String] = []
    var inputPriority: [String] = []

    private(set) var inputName = "?"
    private(set) var outputName = "?"
    /// voice processing (ตัดเสียงสะท้อน) ทำงานอยู่ไหม — ถ้าไม่ controller จะปิดไมค์ระหว่าง Friday พูด
    private(set) var aecEnabled = false
    private(set) var outputAirPlay = false
    var isSpeaking: Bool { pending > 0 }

    private var inEngine = AVAudioEngine()
    private var outEngine = AVAudioEngine()          // โหมด AEC: ตัวเดียวกับ inEngine
    private var player = AVAudioPlayerNode()
    private let playFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
    private let micFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private var micBuffer = Data()
    private let micQueue = DispatchQueue(label: "friday.mic")
    private var pending = 0 { didSet { if (pending > 0) != (oldValue > 0) { onSpeakingChanged?(pending > 0) } } }
    private var generation = 0      // flush แล้ว completion ของ buffer เก่าที่ตามมาทีหลังต้องไม่ไปลด pending ของรอบใหม่
    private var observers: [(engine: AVAudioEngine, token: NSObjectProtocol)] = []

    private var vpUnsupported = false                 // ลอง voice processing แล้วไม่ได้ → ไม่ลองซ้ำจนกว่าจะเปิดแอปใหม่
    private var benchedInputs: [String: Date] = [:]   // ไมค์ที่เงียบสนิท (ไมค์ MacBook ตอนปิดฝา) → พักไว้ชั่วคราว
    private var zeroSince: Date?
    private var building = false
    private var listening = false
    private var pendingReselect: DispatchWorkItem?
    /// ปิดหูอยู่ → ไม่เปิดไมค์เลย (ไอคอนไมค์สีส้มของ macOS จะหาย)
    private(set) var inputPaused = false

    /// ปล่อยไมค์ (ปิดหู / แอปกำลังปิด) — ปิดทั้งระบบเสียง เพราะตอนนี้ไม่มีอะไรต้องพูด
    func pauseInput() {
        inputPaused = true
        pendingReselect?.cancel(); pendingHealth?.cancel()
        teardownAll()
        Log.write("audio: ปล่อยไมค์ (ปิดหู)")
    }

    func resumeInput() throws {
        inputPaused = false
        try start()
    }

    // ---------- เปิด/เลือกอุปกรณ์ ----------
    func start() throws {
        if inputPaused { return }
        if !listening {
            listening = true
            AudioDevices.onChange { [weak self] in self?.scheduleReselect() }
            startWatchdog()
        }
        building = true; defer { building = false }
        benchedInputs = benchedInputs.filter { $0.value > Date() }
        let outs = AudioDevices.candidates(input: false, priority: outputPriority)
        let ins = AudioDevices.candidates(input: true, priority: inputPriority, skip: Set(benchedInputs.keys))
        guard !outs.isEmpty, !ins.isEmpty else {
            teardownAll()      // ปิด engine เก่าด้วย ไม่งั้นไมค์ที่ตายยังส่งเสียง 0 มาให้ตรวจซ้ำทุก 4 วิ (วน 4 วิแทน 60 วิ)
            throw NSError(domain: "Friday", code: 1, userInfo: [NSLocalizedDescriptionKey: "ไม่พบ\(outs.isEmpty ? "ลำโพง" : "ไมค์")ที่ใช้ได้"])
        }

        if !vpUnsupported, !outs[0].airplay, outs[0].id == AudioDevices.defaultDevice(input: false), ins[0].id == AudioDevices.defaultDevice(input: true) {
            do { try buildAEC(out: outs[0], inp: ins[0]); return }
            catch { vpUnsupported = true; Log.write("audio: voice processing ใช้ไม่ได้ (\((error as NSError).code)) → แยกไมค์/ลำโพง") }
        }

        // ลำโพง: ตัวแรกที่เปิดได้
        var outOK: AudioDevice?
        for d in outs {
            do { try buildOutput(d); outOK = d; break }
            catch { Log.write("audio: 🔊 \(d.name) ใช้ไม่ได้ (\((error as NSError).code)) → ตัวถัดไป") }
        }
        guard let outOK else { throw NSError(domain: "Friday", code: 2, userInfo: [NSLocalizedDescriptionKey: "เปิดลำโพงไม่ได้สักตัว"]) }
        // ไมค์: ตัวแรกที่เปิดได้
        var inOK: AudioDevice?
        for d in ins {
            do { try buildInput(d); inOK = d; break }
            catch { Log.write("audio: 🎤 \(d.name) ใช้ไม่ได้ (\((error as NSError).code)) → ตัวถัดไป") }
        }
        guard let inOK else { throw NSError(domain: "Friday", code: 3, userInfo: [NSLocalizedDescriptionKey: "เปิดไมค์ไม่ได้สักตัว"]) }
        aecEnabled = false
        outputAirPlay = outOK.airplay
        started(out: outOK.name, inp: inOK.name)
    }

    private func started(out: String, inp: String) {
        outputName = out; inputName = inp
        Log.write("audio: 🔊 \(out) · 🎤 \(inp) · aec=\(aecEnabled) · airplay=\(outputAirPlay)")
        onDevicesChanged?()
    }

    /// โหมดตัดเสียงสะท้อน: engine เดียว ใช้ default ของเครื่อง
    private func buildAEC(out: AudioDevice, inp: AudioDevice) throws {
        teardownAll()
        let e = AVAudioEngine()
        let p = AVAudioPlayerNode()
        do {
            try e.inputNode.setVoiceProcessingEnabled(true)
            e.inputNode.isVoiceProcessingAGCEnabled = true
            e.inputNode.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: true, duckingLevel: .min)
            e.attach(p)
            e.connect(p, to: e.mainMixerNode, format: playFormat)
            try installTap(e)
            e.prepare(); try e.start()
        } catch { e.stop(); e.inputNode.removeTap(onBus: 0); throw error }
        inEngine = e; outEngine = e; player = p; p.play()
        resetPlayback(); observe(e)
        aecEnabled = true
        outputAirPlay = out.airplay
        started(out: out.name, inp: inp.name)
    }

    private func buildOutput(_ d: AudioDevice) throws {
        if outEngine !== inEngine { outEngine.stop(); unobserve(outEngine) } else { teardownAll() }
        let e = AVAudioEngine()
        let p = AVAudioPlayerNode()
        do {
            try setDevice(e.outputNode.audioUnit, d.id)
            e.attach(p)
            e.connect(p, to: e.mainMixerNode, format: playFormat)
            e.prepare(); try e.start()
        } catch { e.stop(); throw error }
        outEngine = e; player = p; p.play()
        resetPlayback(); observe(e)
    }

    private func buildInput(_ d: AudioDevice) throws {
        if inEngine !== outEngine { inEngine.stop(); inEngine.inputNode.removeTap(onBus: 0); unobserve(inEngine) }
        let e = AVAudioEngine()
        do {
            try setDevice(e.inputNode.audioUnit, d.id)
            try installTap(e)
            e.prepare(); try e.start()
        } catch { e.stop(); e.inputNode.removeTap(onBus: 0); throw error }
        inEngine = e; zeroSince = nil
        observe(e)
    }

    private func installTap(_ e: AVAudioEngine) throws {
        // ตั้งอุปกรณ์เองแล้ว outputFormat ยังค้างเป็น rate ของลำโพง default (เช่น 44.1k AirPlay) ขณะไมค์จริง 48k → tap ไม่ได้ buffer เลย (8 ต.ค.)
        // จึงใช้ format ของ hardware ไมค์ · โหมด voice processing ใช้ outputFormat ตามเดิม
        let fmt = e.inputNode.isVoiceProcessingEnabled ? e.inputNode.outputFormat(forBus: 0) : e.inputNode.inputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { throw NSError(domain: "Friday", code: 4, userInfo: [NSLocalizedDescriptionKey: "ไมค์ไม่มีสัญญาณ"]) }
        let conv = AVAudioConverter(from: fmt, to: micFormat)
        micQueue.sync { converter = conv; micBuffer.removeAll() }   // สลับ converter บนคิวเดียวกับที่ใช้ (กัน data race)
        // อุปกรณ์เพิ่งเปลี่ยน (ถอดไมค์นอก) → format ที่อ่านได้อาจไม่ตรง hardware แล้ว installTap โยน NSException ทำแอปตาย (15 ก.ย.)
        // ดักไว้ → throw ปกติ → ข้ามไปไมค์ตัวถัดไป / วนลองใหม่
        var err: NSError?
        let ok = FridayObjCTry({
            e.inputNode.installTap(onBus: 0, bufferSize: 2048, format: fmt) { [weak self] buf, _ in
                self?.micQueue.async { self?.convertAndEmit(buf) }
            }
        }, &err)
        if !ok { throw err ?? NSError(domain: "Friday", code: 6) }
    }

    private func setDevice(_ unit: AudioUnit?, _ id: AudioDeviceID) throws {
        guard let unit else { throw NSError(domain: "Friday", code: 5) }
        var dev = id
        let st = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        if st != noErr { throw NSError(domain: NSOSStatusErrorDomain, code: Int(st)) }
    }

    private func teardownAll() {
        observers.forEach { NotificationCenter.default.removeObserver($0.token) }; observers = []
        inEngine.stop(); inEngine.inputNode.removeTap(onBus: 0)
        outEngine.stop()
    }

    /// ระบบแจ้ง configuration change (มักเกิดเองตอนเปิด engine อีกตัวบนอุปกรณ์เดียวกัน) → อย่ารีบสร้างใหม่
    /// รอให้นิ่ง 1.5 วิ แล้วเช็คว่า engine หยุดจริงไหม ถ้ายังวิ่งอยู่ก็ไม่ต้องทำอะไร (กันวนสร้างใหม่ไม่จบ)
    private var pendingHealth: DispatchWorkItem?
    private func observe(_ e: AVAudioEngine) {
        observers.append((e, NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: e, queue: .main) { [weak self] _ in
            self?.scheduleHealthCheck()
        }))
    }

    /// ถอด observer ของ engine ที่เลิกใช้ (ไม่งั้นรายการโตทุกครั้งที่สร้างใหม่)
    private func unobserve(_ e: AVAudioEngine) {
        observers.removeAll { if $0.engine === e { NotificationCenter.default.removeObserver($0.token); return true }; return false }
    }

    private func scheduleHealthCheck() {
        pendingHealth?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.building, !self.inputPaused else { return }
            if self.inEngine.isRunning && self.outEngine.isRunning { return }
            Log.write("audio: engine หยุด (in=\(self.inEngine.isRunning) out=\(self.outEngine.isRunning)) → เลือกใหม่")
            self.reselect(force: true)
        }
        pendingHealth = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }

    /// เสียบ/ถอดอุปกรณ์ → รอให้นิ่ง 1 วิ แล้วค่อยดูว่ามีตัวที่ดีกว่าไหม (กันวนตอน macOS สร้างอุปกรณ์ชั่วคราว)
    private func scheduleReselect() {
        onHardwareChange?()
        benchedInputs = [:]              // เสียบ/ถอดอุปกรณ์ → ให้โอกาสไมค์ที่เคยพักไว้อีกครั้ง
        guard !building else { return }
        pendingReselect?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.reselect(force: false) }
        pendingReselect = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: w)
    }

    private func reselect(force: Bool) {
        guard !building, !inputPaused else { return }
        if !force {
            let bestOut = AudioDevices.candidates(input: false, priority: outputPriority).first?.name
            let bestIn = AudioDevices.candidates(input: true, priority: inputPriority, skip: Set(benchedInputs.keys)).first?.name
            guard bestOut != outputName || bestIn != inputName else { return }
            Log.write("audio: อุปกรณ์เปลี่ยน → ใช้ \(bestOut ?? "-") / \(bestIn ?? "-")")
        }
        do { try start() } catch { Log.write("audio: เลือกใหม่ไม่สำเร็จ \(error)"); onFailure?() }
    }

    // ---------- ตัวเฝ้าไมค์ค้าง ----------
    // 9 ต.ค.: ไมค์ส่งเสียงได้ ~1–2 นาทีแล้วเงียบไปเฉยๆ (engine ยังบอกว่าวิ่งอยู่ ไม่มี error) ตอนเสียงออก AirPlay → แอปไม่ได้ยินอะไรเลย
    // ไม่รู้สาเหตุแน่ชัด จึงเฝ้า: ถ้าไม่มี buffer จากไมค์เกิน 4 วิ → สร้าง engine ไมค์ใหม่ (ไม่แตะลำโพง เสียงที่กำลังพูดไม่ขาด)
    private var lastTap = -1, stalledSec = 0, restarts = 0
    private func startWatchdog() {
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, !self.building, !self.inputPaused else { self?.stalledSec = 0; return }
            let now = self.tapCount
            if now == self.lastTap { self.stalledSec += 2 } else { self.stalledSec = 0; self.lastTap = now }
            guard self.stalledSec >= 4 else { return }
            self.stalledSec = 0; self.restarts += 1
            Log.write("audio: ไมค์ค้าง (ไม่มีเสียงเข้า 4 วิ, ครั้งที่ \(self.restarts)) → เปิดไมค์ใหม่")
            self.restartInput()
        }
    }

    private func restartInput() {
        guard !aecEnabled, let d = AudioDevices.candidates(input: true, priority: inputPriority, skip: Set(benchedInputs.keys)).first else { reselect(force: true); return }
        do { try buildInput(d); inputName = d.name } catch { Log.write("audio: เปิดไมค์ใหม่ไม่ได้ \(error) → เลือกอุปกรณ์ใหม่"); reselect(force: true) }
    }

    // ---------- ไมค์ ----------
    var inputRunning: Bool { inEngine.isRunning }
    private(set) var tapCount = 0, convFail = 0     // debug: ไมค์ส่ง buffer มากี่ก้อน / แปลงไม่สำเร็จกี่ก้อน
    private func convertAndEmit(_ buf: AVAudioPCMBuffer) {
        tapCount += 1
        checkDeadInput(buf)
        guard let converter else { convFail += 1; return }
        let ratio = micFormat.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: micFormat, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buf
        }
        guard err == nil, out.frameLength > 0, let p = out.int16ChannelData else { convFail += 1; return }
        micBuffer.append(Data(bytes: p[0], count: Int(out.frameLength) * 2))
        while micBuffer.count >= 3200 {                     // 100ms @16kHz
            let chunk = micBuffer.prefix(3200)
            micBuffer.removeFirst(3200)
            onMic?(Data(chunk))
        }
    }

    /// ไมค์ส่งแต่ค่า 0 ติดกันเกิน 4 วิ (ไมค์ MacBook ตอนปิดฝาเป็นแบบนี้) → พักไมค์นี้ 2 นาที แล้วไปตัวถัดไป
    private func checkDeadInput(_ buf: AVAudioPCMBuffer) {
        guard let ch = buf.floatChannelData?[0] else { return }
        var peak: Float = 0
        for i in 0..<Int(buf.frameLength) { peak = max(peak, abs(ch[i])) }
        if peak > 0 { zeroSince = nil; return }
        let since = zeroSince ?? Date(); zeroSince = since
        guard Date().timeIntervalSince(since) > 4 else { return }
        zeroSince = nil
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.building else { return }
            let name = self.inputName
            Log.write("audio: ไมค์ \(name) เงียบสนิท → พักไว้ 2 นาที เปลี่ยนตัวถัดไป")
            self.benchedInputs[name] = Date().addingTimeInterval(120)   // สั้นพอให้กลับมาใช้ได้เร็วหลังเปิดฝา (ไม่มีวนถี่แล้วเพราะ start() ปิด engine ก่อน throw)
            self.reselect(force: true)
        }
    }

    // ---------- ลำโพง ----------
    /// เล่นเสียงจาก Gemini (PCM16 24kHz mono) ต่อคิวแบบไร้รอยต่อ
    func play(pcm16: Data) {
        let n = pcm16.count / 2
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(n)) else { return }
        buf.frameLength = AVAudioFrameCount(n)
        let dst = buf.floatChannelData![0]
        pcm16.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<n { dst[i] = Float(Int16(littleEndian: src[i])) / 32768 }
        }
        schedule(buf)
    }

    private func schedule(_ buf: AVAudioPCMBuffer) {
        guard outEngine.isRunning else { return }
        pending += 1
        let gen = generation
        player.scheduleBuffer(buf) { [weak self] in
            DispatchQueue.main.async { if let self, gen == self.generation, self.pending > 0 { self.pending -= 1 } }
        }
        if !player.isPlaying { player.play() }
    }

    private func resetPlayback() { generation += 1; pending = 0 }

    /// ผู้ใช้พูดแทรก → หยุดเสียงที่ค้างในคิวทันที
    func flush() {
        generation += 1
        player.stop()
        pending = 0
        if outEngine.isRunning { player.play() }
    }

    /// เสียงติ๊งตอนได้ยินคำปลุก
    func chime() {
        let sr = playFormat.sampleRate, dur = 0.26
        let n = AVAudioFrameCount(sr * dur)
        guard let buf = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: n) else { return }
        buf.frameLength = n
        let d = buf.floatChannelData![0]
        for i in 0..<Int(n) {
            let t = Double(i) / sr
            let f = t < 0.09 ? 880.0 : 1320.0
            let env = min(1, t / 0.02) * exp(-t * 12)
            d[i] = Float(sin(2 * .pi * f * t) * env * 0.25)
        }
        schedule(buf)
    }
}
