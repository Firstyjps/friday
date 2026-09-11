import CoreAudio
import Foundation

/// อุปกรณ์เสียงของเครื่อง (CoreAudio) + เลือกตามลำดับที่ตั้งไว้ใน config.json
/// เลือกเฉพาะให้ Friday ใช้ ไม่ไปเปลี่ยน default ของทั้งเครื่อง
struct AudioDevice: Equatable {
    let id: AudioDeviceID
    let name: String
    let inputChannels: Int
    let outputChannels: Int
    let sampleRate: Double
    let alive: Bool
    let virtual: Bool

    var usableOutput: Bool { alive && outputChannels > 0 && sampleRate > 0 }
    var usableInput: Bool { alive && inputChannels > 0 && sampleRate > 0 }
}

enum AudioDevices {
    static func all() -> [AudioDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map { id in
            AudioDevice(id: id, name: name(id), inputChannels: channels(id, kAudioObjectPropertyScopeInput),
                        outputChannels: channels(id, kAudioObjectPropertyScopeOutput), sampleRate: rate(id),
                        alive: u32(id, kAudioDevicePropertyDeviceIsAlive) != 0,
                        virtual: u32(id, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeVirtual)
        }
    }

    static func defaultDevice(input: Bool) -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    /// รายการผู้สมัครเรียงตามลำดับ: ตรงกับ priority (ชื่อบางส่วน ไม่สนตัวพิมพ์) ก่อน → default ของเครื่อง → ที่เหลือ
    /// ข้ามอุปกรณ์เสมือน (Teams/IG ฯลฯ) เว้นแต่ใส่ชื่อไว้ใน priority · ข้ามตัวที่ถูกพักไว้ (เช่น ไมค์เงียบสนิท)
    static func candidates(input: Bool, priority: [String], skip: Set<String> = []) -> [AudioDevice] {
        // ข้ามอุปกรณ์ชั่วคราวที่ macOS สร้างเอง (CADefaultDeviceAggregate ตอนเปิด voice processing) — ไม่งั้นวนเลือกใหม่ไม่จบ
        let devs = all().filter { (input ? $0.usableInput : $0.usableOutput) && !skip.contains($0.name) && !$0.name.hasPrefix("CADefaultDeviceAggregate") }
        func rank(_ d: AudioDevice) -> Int? { priority.firstIndex { d.name.localizedCaseInsensitiveContains($0) } }
        let listed = devs.filter { rank($0) != nil }.sorted { rank($0)! < rank($1)! }
        let def = defaultDevice(input: input)
        let rest = devs.filter { rank($0) == nil && !$0.virtual }.sorted { ($0.id == def ? 0 : 1) < ($1.id == def ? 0 : 1) }
        return listed + rest
    }

    /// แจ้งเมื่อเสียบ/ถอดอุปกรณ์ หรือ default เปลี่ยน
    static func onChange(_ block: @escaping () -> Void) {
        for sel in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice] {
            var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main) { _, _ in block() }
        }
    }

    // ---------- helpers ----------
    private static func name(_ id: AudioDeviceID) -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?; var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cf) == noErr, let s = cf?.takeRetainedValue() else { return "?" }
        return s as String
    }

    private static func channels(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func rate(_ id: AudioDeviceID) -> Double {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var r = Float64(0); var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &r)
        return r
    }

    private static func u32(_ id: AudioDeviceID, _ sel: AudioObjectPropertySelector) -> UInt32 {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var v = UInt32(0); var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v)
        return v
    }
}
