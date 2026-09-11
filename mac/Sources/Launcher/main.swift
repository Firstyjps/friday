import Darwin
import Foundation

// ตัวเปิด Friday.app — ตั้งใจให้เล็กและแทบไม่เปลี่ยน (macOS ผูกสิทธิ์ไมค์กับตัวนี้)
// โค้ดจริงอยู่ใน FridayCore.dylib ที่ ~/Library/Application Support/Friday/ (build ใหม่แทนที่ได้โดยไม่ต้องขอสิทธิ์ใหม่)
let path = NSHomeDirectory() + "/Library/Application Support/Friday/libFridayCore.dylib"
guard let handle = dlopen(path, RTLD_NOW) else {
    FileHandle.standardError.write("Friday: โหลด \(path) ไม่ได้: \(String(cString: dlerror()))\n".data(using: .utf8)!)
    exit(1)
}
guard let sym = dlsym(handle, "friday_main") else { exit(2) }
typealias Entry = @convention(c) () -> Void
unsafeBitCast(sym, to: Entry.self)()
