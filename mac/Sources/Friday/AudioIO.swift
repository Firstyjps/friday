import AVFoundation
import CoreAudio

/// ไมค์ + ลำโพงของ Friday บน AVAudioEngine เดียว
/// เปิด voice processing ของ Apple → ตัดเสียง Friday ออกจากไมค์ (ใช้ลำโพง Mac ได้ พูดแทรกได้) + ปรับระดับเสียงอัตโนมัติ
final class AudioIO {
    /// ไมค์ทุก ~100ms: PCM16 16kHz mono
    var onMic: ((Data) -> Void)?
    /// เปลี่ยนสถานะกำลังพูด/เงียบ
    var onSpeakingChanged: ((Bool) -> Void)?

    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private let playFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
    private let micFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private var micBuffer = Data()
    private let micQueue = DispatchQueue(label: "friday.mic")
    private var pending = 0 { didSet { if (pending > 0) != (oldValue > 0) { onSpeakingChanged?(pending > 0) } } }
    private var configObserver: NSObjectProtocol?

    var isSpeaking: Bool { pending > 0 }
    private(set) var inputName = "?"
    private(set) var outputName = "?"
    /// voice processing (ตัดเสียงสะท้อน) เปิดได้ไหม — บางคู่อุปกรณ์ (เช่น เสียงออกจอ HDMI/DP + ไมค์ช่องหูฟัง) เปิดไม่ได้
    private(set) var aecEnabled = true

    /// ลำดับอุปกรณ์ที่อยากใช้ (ชื่อบางส่วน) — มาจาก config.json
    var outputPriority: [String] = []
    var inputPriority: [String] = []
    /// ไมค์ที่ส่งเสียงเงียบสนิท (เช่น ไมค์ MacBook ตอนปิดฝา) → พักไว้ชั่วคราว ข้ามไปตัวถัดไป
    private var benchedInputs: [String: Date] = [:]
    private var zeroSince: Date?

    /// ระบบเสียงพังระหว่างทาง (เปลี่ยนอุปกรณ์แล้วเปิดใหม่ไม่ได้) → ให้ controller วนลองใหม่
    var onFailure: (() -> Void)?
    /// ใช้อุปกรณ์ชุดใหม่แล้ว (ไว้อัปเดตเมนู)
    var onDevicesChanged: (() -> Void)?

    private var listening = false

    /// เปิดระบบเสียง: ไล่ลำโพง/ไมค์ตามลำดับ อันไหนเปิดไม่ได้ข้ามไปตัวถัดไป · เรียกซ้ำได้ (สร้าง engine ใหม่ทุกครั้ง)
    func start() throws {
        if !listening {                                    // เสียบ/ถอดอุปกรณ์ → เลือกใหม่ (ถ้าตัวที่ดีกว่าโผล่มา)
            listening = true
            AudioDevices.onChange { [weak self] in self?.devicesChanged() }
        }
        benchedInputs = benchedInputs.filter { $0.value > Date() }
        let outs = AudioDevices.candidates(input: false, priority: outputPriority)
        let ins = AudioDevices.candidates(input: true, priority: inputPriority, skip: Set(benchedInputs.keys))
        guard !outs.isEmpty, !ins.isEmpty else {
            throw NSError(domain: "Friday", code: 1, userInfo: [NSLocalizedDescriptionKey: "ไม่พบ\(outs.isEmpty ? "ลำโพง" : "ไมค์")ที่ใช้ได้"])
        }
        // ตัวตัดเสียงสะท้อนของ Apple ใช้ได้เฉพาะอุปกรณ์ default ของเครื่อง → ลองเฉพาะเมื่อ default ตรงกับตัวที่อยากใช้อันดับแรก
        if outs[0].id == AudioDevices.defaultDevice(input: false) && ins[0].id == AudioDevices.defaultDevice(input: true) {
            aecEnabled = true
            do { try build(output: nil, input: nil); return }
            catch { Log.write("audio: voice processing ใช้ไม่ได้ (\((error as NSError).code)) → เปิดแบบปกติ") }
        }
        aecEnabled = false
        var lastError: Error?
        for out in outs {
            for inp in ins.prefix(3) {
                do { try build(output: out, input: inp); return }
                catch { lastError = error; Log.write("audio: ใช้ \(out.name) + \(inp.name) ไม่ได้ (\((error as NSError).code)) → ลองตัวถัดไป") }
            }
        }
        throw lastError ?? NSError(domain: "Friday", code: 2)
    }

    private func devicesChanged() {
        let bestOut = AudioDevices.candidates(input: false, priority: outputPriority).first?.name
        let bestIn = AudioDevices.candidates(input: true, priority: inputPriority, skip: Set(benchedInputs.keys)).first?.name
        guard bestOut != outputName || bestIn != inputName else { return }
        Log.write("audio: อุปกรณ์เปลี่ยน (\(bestOut ?? "-") / \(bestIn ?? "-")) → เลือกใหม่")
        do { try start() } catch { Log.write("audio: เลือกใหม่ไม่สำเร็จ \(error)"); onFailure?() }
    }

    private func build(output: AudioDevice?, input: AudioDevice?) throws {
        teardown()
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        engine.attach(player)
        generation += 1; pending = 0; zeroSince = nil
        do {
            if let output { try setDevice(engine.outputNode.audioUnit, output.id) }
            if let input { try setDevice(engine.inputNode.audioUnit, input.id) }
            try configure()
        } catch { teardown(); throw error }
        outputName = output?.name ?? AudioDevices.all().first { $0.id == AudioDevices.defaultDevice(input: false) }?.name ?? "default"
        inputName = input?.name ?? AudioDevices.all().first { $0.id == AudioDevices.defaultDevice(input: true) }?.name ?? "default"
        Log.write("audio: 🔊 \(outputName) · 🎤 \(inputName) · aec=\(aecEnabled)")
        onDevicesChanged?()
        // ระบบเสียงเปลี่ยนเอง (sample rate/ช่องสัญญาณ) → engine หยุด ต้องสร้างใหม่
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self else { return }
            Log.write("audio: configuration changed → restart")
            do { try self.start() } catch { Log.write("audio: restart error \(error)"); self.onFailure?() }
        }
    }

    private func setDevice(_ unit: AudioUnit?, _ id: AudioDeviceID) throws {
        guard let unit else { throw NSError(domain: "Friday", code: 3) }
        var dev = id
        let st = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        if st != noErr { throw NSError(domain: NSOSStatusErrorDomain, code: Int(st)) }
    }

    private func teardown() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }

    private func configure() throws {
        let input = engine.inputNode
        if aecEnabled {
            if !input.isVoiceProcessingEnabled { try input.setVoiceProcessingEnabled(true) }
            input.isVoiceProcessingAGCEnabled = true
            // อย่ากดเสียงแอปอื่น (เพลง/YouTube) ลงมากตอน Friday ทำงาน
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: true, duckingLevel: .min)
        }

        engine.connect(player, to: engine.mainMixerNode, format: playFormat)

        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw NSError(domain: "Friday", code: 4, userInfo: [NSLocalizedDescriptionKey: "ไมค์ไม่มีสัญญาณ"]) }
        converter = AVAudioConverter(from: inFormat, to: micFormat)
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buf, _ in
            self?.micQueue.async { self?.convertAndEmit(buf) }
        }
        engine.prepare()
        try engine.start()
        player.play()
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
        let name = inputName
        DispatchQueue.main.async { [weak self] in
            guard let self, name == self.inputName else { return }
            Log.write("audio: ไมค์ \(name) เงียบสนิท → พักไว้ 2 นาที เปลี่ยนตัวถัดไป")
            self.benchedInputs[name] = Date().addingTimeInterval(120)
            do { try self.start() } catch { Log.write("audio: เปลี่ยนไมค์ไม่สำเร็จ \(error)"); self.onFailure?() }
        }
    }

    private func convertAndEmit(_ buf: AVAudioPCMBuffer) {
        checkDeadInput(buf)
        guard let converter else { return }
        let ratio = micFormat.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: micFormat, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buf
        }
        guard err == nil, out.frameLength > 0, let p = out.int16ChannelData else { return }
        micBuffer.append(Data(bytes: p[0], count: Int(out.frameLength) * 2))
        while micBuffer.count >= 3200 {                     // 100ms @16kHz
            let chunk = micBuffer.prefix(3200)
            micBuffer.removeFirst(3200)
            onMic?(Data(chunk))
        }
    }

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

    private var generation = 0      // flush แล้ว completion ของ buffer เก่าที่ตามมาทีหลังต้องไม่ไปลด pending ของรอบใหม่

    private func schedule(_ buf: AVAudioPCMBuffer) {
        pending += 1
        let gen = generation
        player.scheduleBuffer(buf) { [weak self] in
            DispatchQueue.main.async { if let self, gen == self.generation, self.pending > 0 { self.pending -= 1 } }
        }
        if !player.isPlaying { player.play() }
    }

    /// ผู้ใช้พูดแทรก → หยุดเสียงที่ค้างในคิวทันที
    func flush() {
        generation += 1
        player.stop()
        pending = 0
        player.play()
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
