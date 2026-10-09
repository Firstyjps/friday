import AVFoundation
import AudioToolbox

/// ตัวตัดเสียงสะท้อนของ Apple (VoiceProcessingIO) แบบเรียก AudioUnit ตรง — เล่นเสียง Friday + อ่านไมค์ที่ตัดเสียง Friday ออกแล้ว
/// ทำไมไม่ใช้ AVAudioEngine.setVoiceProcessingEnabled: กับไมค์หูฟัง + ลำโพงจอ เปิดไม่ได้ (-10875) แต่ AudioUnit ตรงเปิดได้
/// วัด 9 ต.ค.: เสียง Friday ที่เข้าไมค์ 7176 → 574 (-22 dB), เสียงพื้น 920 → 140 (ผล --vp-test --vpio-echo)
final class VPIOUnit {
    let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
    /// ไมค์ (Float 24k mono) — เรียกจาก thread เสียง
    var onMic: ((AVAudioPCMBuffer) -> Void)?
    /// คิวเสียงหมด (พูดจบ) — เรียกจาก thread เสียง
    var onDrained: (() -> Void)?

    private let au: AudioUnit
    private let lock = NSLock()
    private var q: [Float] = []
    private var head = 0
    private var micScratch = [Float](repeating: 0, count: 8192)

    init(input: AudioDeviceID, output: AudioDeviceID) throws {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_VoiceProcessingIO,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw NSError(domain: "VPIO", code: 1) }
        var unit: AudioUnit?
        let st = AudioComponentInstanceNew(comp, &unit)
        guard st == noErr, let unit else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(st)) }
        au = unit
        do { try configure(input: input, output: output) }
        catch { AudioComponentInstanceDispose(au); throw error }
    }

    deinit { stop(); AudioComponentInstanceDispose(au) }

    private func configure(input: AudioDeviceID, output: AudioDeviceID) throws {
        func chk(_ st: OSStatus) throws { if st != noErr { throw NSError(domain: NSOSStatusErrorDomain, code: Int(st)) } }
        var one: UInt32 = 1, i = input, o = output
        try chk(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, 4))
        try chk(AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 1, &i, 4))
        try chk(AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &o, 4))
        // ปิด AGC: ขยายเสียงไกลๆ ในห้อง (ทีวี/คนคุย) จนหูคำปลุกได้ยินเหมือน "ฟรายเดย์" แล้วตื่นเอง (9 ต.ค. 5 ครั้ง/ชม.)
        // ตัดเสียงสะท้อนยังได้ -22 dB เท่าเดิม (วัดตอน AGC ปิด)
        var agc: UInt32 = 0
        _ = AudioUnitSetProperty(au, kAUVoiceIOProperty_VoiceProcessingEnableAGC, kAudioUnitScope_Global, 0, &agc, 4)
        // เสียงแอปอื่น (เพลง/วิดีโอ) ไม่ต้องหรี่ลงตอน Friday ฟัง
        var duck = AUVoiceIOOtherAudioDuckingConfiguration(mEnableAdvancedDucking: true, mDuckingLevel: .min)
        _ = AudioUnitSetProperty(au, kAUVoiceIOProperty_OtherAudioDuckingConfiguration, kAudioUnitScope_Global, 0, &duck,
                                 UInt32(MemoryLayout<AUVoiceIOOtherAudioDuckingConfiguration>.size))
        var fmt = format.streamDescription.pointee
        let fsz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try chk(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, fsz))    // เสียงที่เราเล่น
        try chk(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &fmt, fsz))   // ไมค์ที่เราอ่าน
        let me = Unmanaged.passUnretained(self).toOpaque()
        var render = AURenderCallbackStruct(inputProc: { ref, _, _, _, frames, data in
            Unmanaged<VPIOUnit>.fromOpaque(ref).takeUnretainedValue().fill(frames, data)
        }, inputProcRefCon: me)
        try chk(AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &render, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
        var mic = AURenderCallbackStruct(inputProc: { ref, flags, ts, bus, frames, _ in
            Unmanaged<VPIOUnit>.fromOpaque(ref).takeUnretainedValue().capture(flags, ts, bus, frames)
        }, inputProcRefCon: me)
        try chk(AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 1, &mic, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
        try chk(AudioUnitInitialize(au))
    }

    func start() throws {
        let st = AudioOutputUnitStart(au)
        if st != noErr { throw NSError(domain: NSOSStatusErrorDomain, code: Int(st)) }
    }
    func stop() { AudioOutputUnitStop(au) }

    // ---------- เล่นเสียง ----------
    func enqueue(_ samples: UnsafeBufferPointer<Float>) {
        lock.lock(); q.append(contentsOf: samples); lock.unlock()
    }
    func clear() { lock.lock(); q.removeAll(keepingCapacity: true); head = 0; lock.unlock() }
    var queued: Int { lock.lock(); defer { lock.unlock() }; return q.count - head }

    private func fill(_ frames: UInt32, _ data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let abl = UnsafeMutableAudioBufferListPointer(data), let p = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
        let n = Int(frames)
        lock.lock()
        let had = head < q.count
        let k = min(n, q.count - head)
        for j in 0..<k { p[j] = q[head + j] }
        head += k
        let drained = had && head >= q.count
        if head >= q.count { q.removeAll(keepingCapacity: true); head = 0 }
        else if head > 48000 { q.removeFirst(head); head = 0 }
        lock.unlock()
        for j in k..<n { p[j] = 0 }
        if drained { onDrained?() }
        return noErr
    }

    // ---------- ไมค์ ----------
    private func capture(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ ts: UnsafePointer<AudioTimeStamp>, _ bus: UInt32, _ frames: UInt32) -> OSStatus {
        guard frames <= 8192 else { return noErr }
        return micScratch.withUnsafeMutableBufferPointer { mb -> OSStatus in
            var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4, mData: UnsafeMutableRawPointer(mb.baseAddress)))
            let st = AudioUnitRender(au, flags, ts, bus, frames, &abl)
            guard st == noErr, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return st }
            buf.frameLength = frames
            buf.floatChannelData![0].update(from: mb.baseAddress!, count: Int(frames))
            onMic?(buf)
            return noErr
        }
    }
}
