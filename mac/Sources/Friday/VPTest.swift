import AVFoundation
import CoreAudio

/// `Friday --vp-test` (เปิดผ่าน `open -n Friday.app --args --vp-test` เพื่อใช้สิทธิ์ไมค์ของแอป)
/// ลองเปิดตัวตัดเสียงสะท้อนของ Apple (voice processing) กับไมค์+ลำโพงที่ใช้อยู่หลายวิธี แล้ววัดว่าเสียงสะท้อนลดลงกี่ dB
/// ผล → ~/logs/friday-vptest.log · เล่นเสียงทดสอบ ~2.5 วิ ต่อวิธี
@MainActor
enum VPTest {
    private static let url = URL(fileURLWithPath: NSHomeDirectory() + "/logs/friday-vptest.log")
    private static func out(_ s: String) {
        print(s)
        let line = "\(ISO8601DateFormatter().string(from: Date())) | \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }

    static func run() {
        Task {
            let mic = AudioDevices.defaultDevice(input: true), spk = AudioDevices.defaultDevice(input: false)
            out("vp-test เริ่ม · ไมค์ \(name(mic)) · ลำโพง \(name(spk))")
            // 0) ไม่มี VP: engine แยก (แบบที่แอปใช้ตอนนี้) → ค่าอ้างอิง
            if CommandLine.arguments.contains("--vpio-echo") {
                let base = await measure("ไม่มี VP (อ้างอิง)") { try plain(mic: mic, spk: spk) }
                for bypass in [true, false] {
                    _ = await measure(bypass ? "VPIO ปิดตัดเสียงสะท้อน (bypass)" : "VPIO ตัดเสียงสะท้อน", base: base) { try vpioRig(input: mic, output: spk, bypass: bypass) }
                }
                out("vp-test จบ"); exit(0)
            }
            let quick = CommandLine.arguments.contains("--vpio-only")
            let base = quick ? nil : await measure("ไม่มี VP (อ้างอิง)") { try plain(mic: mic, spk: spk) }
            // 1) VP บน default (แบบเดิมที่ล้ม -10875)
            if !quick { _ = await measure("VP default", base: base) { try vpEngine(device: nil) } }
            // 2) aggregate (ไมค์+ลำโพง) แล้วตั้งอุปกรณ์ก่อนเปิด VP / หลังเปิด VP
            if !quick, let agg = makeAggregate(mic: mic, spk: spk) {
                out("aggregate id \(agg) สร้างแล้ว")
                _ = await measure("VP aggregate (ตั้งอุปกรณ์ก่อน)", base: base) { try vpEngine(device: agg, setFirst: true) }
                _ = await measure("VP aggregate (ตั้งอุปกรณ์หลัง)", base: base) { try vpEngine(device: agg, setFirst: false) }
                AudioHardwareDestroyAggregateDevice(agg)
            } else { out("สร้าง aggregate ไม่ได้") }
            // 3) VoiceProcessingIO ตรงๆ จับคู่อุปกรณ์หลายแบบ → ดูว่าตัวไหนเป็นปัญหา (ไม่เล่นเสียง)
            let devs = AudioDevices.all()
            let ins = devs.filter { $0.usableInput && !$0.virtual }, outs = devs.filter { $0.usableOutput && !$0.virtual }
            for i in ins { for o in outs { out("VPIO \(i.name) + \(o.name): \(vpio(input: i.id, output: o.id))") } }
            out("vp-test จบ")
            exit(0)
        }
    }

    // ---------- engine แต่ละแบบ: คืน (เล่นเสียง, เริ่มอัด, หยุด) ----------
    struct Rig { let play: (AVAudioPCMBuffer) -> Void; let stop: () -> Void; let fmt: AVAudioFormat }
    nonisolated(unsafe) static var levels: [Double] = []

    private static func tap(_ e: AVAudioEngine) {
        let f = e.inputNode.isVoiceProcessingEnabled ? e.inputNode.outputFormat(forBus: 0) : e.inputNode.inputFormat(forBus: 0)
        e.inputNode.installTap(onBus: 0, bufferSize: 1024, format: f) { b, _ in
            guard let d = b.floatChannelData?[0] else { return }
            var acc: Float = 0
            for i in 0..<Int(b.frameLength) { acc += d[i] * d[i] }
            let r = Double((acc / Float(max(1, b.frameLength))).squareRoot()) * 32768
            DispatchQueue.main.async { levels.append(r) }
        }
    }

    private static func plain(mic: AudioDeviceID, spk: AudioDeviceID) throws -> Rig {
        let o = AVAudioEngine(), p = AVAudioPlayerNode(), i = AVAudioEngine()
        try setDevice(o.outputNode.audioUnit, spk); o.attach(p)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        o.connect(p, to: o.mainMixerNode, format: fmt); o.prepare(); try o.start(); p.play()
        try setDevice(i.inputNode.audioUnit, mic); tap(i); i.prepare(); try i.start()
        return Rig(play: { p.scheduleBuffer($0) }, stop: { i.inputNode.removeTap(onBus: 0); i.stop(); o.stop() }, fmt: fmt)
    }

    private static func vpEngine(device: AudioDeviceID?, setFirst: Bool = true) throws -> Rig {
        let e = AVAudioEngine(), p = AVAudioPlayerNode()
        if let device, setFirst { try setDevice(e.inputNode.audioUnit, device); try setDevice(e.outputNode.audioUnit, device) }
        try e.inputNode.setVoiceProcessingEnabled(true)
        e.inputNode.isVoiceProcessingAGCEnabled = false
        if let device, !setFirst { try setDevice(e.inputNode.audioUnit, device); try setDevice(e.outputNode.audioUnit, device) }
        e.attach(p)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        e.connect(p, to: e.mainMixerNode, format: fmt)
        tap(e); e.prepare(); try e.start(); p.play()
        return Rig(play: { p.scheduleBuffer($0) }, stop: { e.inputNode.removeTap(onBus: 0); e.stop() }, fmt: fmt)
    }

    /// เงียบ 0.8 วิ (วัดเสียงพื้น) → เล่นเสียงคล้ายคำพูด 2.5 วิ (วัดเสียงสะท้อน) → ค่า RMS
    private static func measure(_ label: String, base: Double? = nil, _ make: () throws -> Rig) async -> Double? {
        let rig: Rig
        do { rig = try make() } catch { out("\(label): เปิดไม่ได้ \((error as NSError).domain) \((error as NSError).code)"); return nil }
        levels = []
        try? await Task.sleep(for: .milliseconds(800))
        let noise = median(levels); levels = []
        rig.play(signal(rig.fmt, sec: 2.5))
        try? await Task.sleep(for: .milliseconds(2700))
        let echo = levels.sorted().dropFirst(levels.count / 5).reduce(0, +) / Double(max(1, levels.count - levels.count / 5))
        rig.stop()
        try? await Task.sleep(for: .milliseconds(400))
        var line = String(format: "%@: เสียงพื้น %.0f · ระหว่างเล่น %.0f (%.1f เท่าของเสียงพื้น)", label, noise, echo, echo / max(1, noise))
        if let base, base > 0 { line += String(format: " · เทียบไม่มี VP %.1f dB", 20 * log10(max(1, echo) / base)) }
        out(line)
        return echo
    }

    private static func signal(_ f: AVAudioFormat, sec: Double) -> AVAudioPCMBuffer {
        let n = AVAudioFrameCount(f.sampleRate * sec)
        let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: n)!; b.frameLength = n
        let d = b.floatChannelData![0]; var t = 0.0, seg = 0.0, on = true
        for i in 0..<Int(n) {
            if t >= seg { on.toggle(); seg = t + (on ? Double.random(in: 0.12...0.3) : Double.random(in: 0.03...0.12)) }
            let x = on ? (sin(2 * .pi * 180 * t) * 0.6 + sin(2 * .pi * 420 * t) * 0.3 + Double.random(in: -0.2...0.2)) : 0
            d[i] = Float(x * 0.35); t = Double(i) / f.sampleRate
        }
        return b
    }

    private static func median(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.sorted()[a.count / 2] }

    // ---------- VoiceProcessingIO แบบใช้งานจริง: เล่นเสียง + อ่านไมค์ที่ตัดเสียงสะท้อนแล้ว ----------
    nonisolated(unsafe) static var vpUnit: AudioUnit?
    nonisolated(unsafe) static var playQ: [Float] = []
    nonisolated(unsafe) static var playLock = NSLock()
    nonisolated(unsafe) static var micBuf = [Float](repeating: 0, count: 8192)

    private static func vpioRig(input: AudioDeviceID, output: AudioDeviceID, bypass: Bool) throws -> Rig {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_VoiceProcessingIO,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw NSError(domain: "vp", code: 2) }
        var auOpt: AudioUnit?
        guard AudioComponentInstanceNew(comp, &auOpt) == noErr, let au = auOpt else { throw NSError(domain: "vp", code: 3) }
        func chk(_ st: OSStatus, _ what: String) throws { if st != noErr { throw NSError(domain: "vp:\(what)", code: Int(st)) } }
        var one: UInt32 = 1, i = input, o = output, by: UInt32 = bypass ? 1 : 0, agc: UInt32 = 0
        try chk(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, 4), "enableIO")
        try chk(AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 1, &i, 4), "in")
        try chk(AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &o, 4), "out")
        _ = AudioUnitSetProperty(au, kAUVoiceIOProperty_BypassVoiceProcessing, kAudioUnitScope_Global, 0, &by, 4)
        _ = AudioUnitSetProperty(au, kAUVoiceIOProperty_VoiceProcessingEnableAGC, kAudioUnitScope_Global, 0, &agc, 4)
        var fmt = AudioStreamBasicDescription(mSampleRate: 24000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                              mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        let fsz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try chk(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, fsz), "fmtOut")
        try chk(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &fmt, fsz), "fmtIn")
        var render = AURenderCallbackStruct(inputProc: { _, _, _, _, frames, data in
            guard let abl = UnsafeMutableAudioBufferListPointer(data), let p = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            VPTest.playLock.lock()
            let n = Int(frames), k = min(n, VPTest.playQ.count)
            for j in 0..<k { p[j] = VPTest.playQ[j] }
            for j in k..<n { p[j] = 0 }
            VPTest.playQ.removeFirst(k)
            VPTest.playLock.unlock()
            return noErr
        }, inputProcRefCon: nil)
        try chk(AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &render, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "render")
        var inCb = AURenderCallbackStruct(inputProc: { _, flags, ts, bus, frames, _ in
            guard let au = VPTest.vpUnit, frames <= 8192 else { return noErr }
            return VPTest.micBuf.withUnsafeMutableBufferPointer { mb -> OSStatus in
                var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4, mData: UnsafeMutableRawPointer(mb.baseAddress)))
                let st = AudioUnitRender(au, flags, ts, bus, frames, &abl)
                if st == noErr {
                    var acc: Float = 0
                    for j in 0..<Int(frames) { acc += mb[j] * mb[j] }
                    let r = Double((acc / Float(max(1, frames))).squareRoot()) * 32768
                    DispatchQueue.main.async { VPTest.levels.append(r) }
                }
                return st
            }
        }, inputProcRefCon: nil)
        try chk(AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 1, &inCb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "inputCb")
        try chk(AudioUnitInitialize(au), "init")
        vpUnit = au
        try chk(AudioOutputUnitStart(au), "start")
        let f = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        return Rig(play: { b in
            let d = b.floatChannelData![0]
            VPTest.playLock.lock(); VPTest.playQ += Array(UnsafeBufferPointer(start: d, count: Int(b.frameLength))); VPTest.playLock.unlock()
        }, stop: { AudioOutputUnitStop(au); AudioUnitUninitialize(au); AudioComponentInstanceDispose(au); VPTest.vpUnit = nil }, fmt: f)
    }

    /// สร้าง VoiceProcessingIO ตั้งไมค์/ลำโพง แล้ว initialize — คืน "ok" หรือรหัส error
    private static func vpio(input: AudioDeviceID, output: AudioDeviceID) -> String {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_VoiceProcessingIO,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { return "ไม่มี component" }
        var au: AudioUnit?
        guard AudioComponentInstanceNew(comp, &au) == noErr, let au else { return "new ล้ม" }
        defer { AudioUnitUninitialize(au); AudioComponentInstanceDispose(au) }
        var one: UInt32 = 1, i = input, o = output
        let s1 = AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, 4)
        let s2 = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 1, &i, 4)
        let s3 = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &o, 4)
        let s4 = AudioUnitInitialize(au)
        var start: OSStatus = -1
        if s4 == noErr { start = AudioOutputUnitStart(au); AudioOutputUnitStop(au) }
        return "enableIO \(s1) setIn \(s2) setOut \(s3) init \(s4) start \(start)"
    }

    // ---------- CoreAudio ----------
    private static func setDevice(_ unit: AudioUnit?, _ id: AudioDeviceID) throws {
        guard let unit else { throw NSError(domain: "vp", code: 1) }
        var dev = id
        let st = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        if st != noErr { throw NSError(domain: NSOSStatusErrorDomain, code: Int(st)) }
    }

    private static func uid(_ id: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?; var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cf) == noErr, let s = cf?.takeRetainedValue() else { return nil }
        return s as String
    }

    private static func name(_ id: AudioDeviceID) -> String { AudioDevices.all().first { $0.id == id }?.name ?? "\(id)" }

    /// อุปกรณ์รวม (ส่วนตัว ไม่โผล่ให้แอปอื่นเห็น): นาฬิกาตามลำโพง + ชดเชยความเพี้ยนของนาฬิกาไมค์
    private static func makeAggregate(mic: AudioDeviceID, spk: AudioDeviceID) -> AudioDeviceID? {
        guard let mu = uid(mic), let su = uid(spk) else { return nil }
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Friday AEC",
            kAudioAggregateDeviceUIDKey: "com.kron.friday.aec.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceMainSubDeviceKey: su,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: su, kAudioSubDeviceDriftCompensationKey: 0],
                [kAudioSubDeviceUIDKey: mu, kAudioSubDeviceDriftCompensationKey: 1],
            ],
        ]
        var id = AudioDeviceID(0)
        let st = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &id)
        if st != noErr { out("AudioHardwareCreateAggregateDevice \(st)"); return nil }
        return id
    }
}
