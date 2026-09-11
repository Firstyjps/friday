import AVFoundation

/// ไมค์ + ลำโพงของ Friday บน AVAudioEngine เดียว
/// เปิด voice processing ของ Apple → ตัดเสียง Friday ออกจากไมค์ (ใช้ลำโพง Mac ได้ พูดแทรกได้) + ปรับระดับเสียงอัตโนมัติ
final class AudioIO {
    /// ไมค์ทุก ~100ms: PCM16 16kHz mono
    var onMic: ((Data) -> Void)?
    /// เปลี่ยนสถานะกำลังพูด/เงียบ
    var onSpeakingChanged: ((Bool) -> Void)?

    private var engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
    private let micFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private var micBuffer = Data()
    private let micQueue = DispatchQueue(label: "friday.mic")
    private var pending = 0 { didSet { if (pending > 0) != (oldValue > 0) { onSpeakingChanged?(pending > 0) } } }
    private var configObserver: NSObjectProtocol?

    var isSpeaking: Bool { pending > 0 }
    private(set) var inputName = "?"
    /// voice processing (ตัดเสียงสะท้อน) เปิดได้ไหม — บางคู่อุปกรณ์ (เช่น เสียงออกจอ HDMI/DP + ไมค์ช่องหูฟัง) เปิดไม่ได้
    private(set) var aecEnabled = true

    func start() throws {
        engine.attach(player)
        do { try configure() } catch {
            // voice processing เปิดไม่ได้กับอุปกรณ์ชุดนี้ → เปิดเสียงแบบปกติแทน (ใช้หูฟัง/ลำโพงประชุมที่ตัดเสียงเองได้)
            Log.write("audio: voice processing ใช้ไม่ได้ (\((error as NSError).code)) → ปิด AEC แล้วลองใหม่")
            aecEnabled = false
            engine.stop(); engine.inputNode.removeTap(onBus: 0)
            engine = AVAudioEngine()
            engine.attach(player)
            try configure()
        }
        // เสียบ/ถอดหูฟัง, เปลี่ยนไมค์ → engine หยุดเอง ต้องตั้งค่าใหม่
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self else { return }
            Log.write("audio: configuration changed → restart")
            self.engine.stop()
            self.engine.inputNode.removeTap(onBus: 0)
            do { try self.configure() } catch { Log.write("audio: restart error \(error)") }
        }
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
        converter = AVAudioConverter(from: inFormat, to: micFormat)
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buf, _ in
            self?.micQueue.async { self?.convertAndEmit(buf) }
        }
        engine.prepare()
        try engine.start()
        player.play()
        inputName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "default"
        Log.write("audio: started input=\(inputName) aec=\(aecEnabled) format=\(inFormat)")
    }

    private func convertAndEmit(_ buf: AVAudioPCMBuffer) {
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
