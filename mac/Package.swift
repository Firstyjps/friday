// swift-tools-version: 5.10
// Friday — แอป Mac (menu bar): ฟังคำปลุก → คุยกับ Gemini Live → สั่งงาน Mac ผ่าน server เดิม (:4850)
// Launcher (ตัวแอป, แทบไม่เปลี่ยน) + FridayCore (dylib, โค้ดจริง) → build ใหม่ไม่ต้องขอสิทธิ์ไมค์ซ้ำ
import PackageDescription

let package = Package(
    name: "Friday",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FridayCore", type: .dynamic, targets: ["FridayCore"]),
        .executable(name: "Friday", targets: ["Launcher"]),
    ],
    targets: [
        .target(name: "ObjCTry", path: "Sources/ObjCTry"),   // ดัก NSException จาก AVAudioEngine (Swift จับไม่ได้)
        .target(name: "FridayCore", dependencies: ["ObjCTry"], path: "Sources/Friday"),
        .executableTarget(name: "Launcher", path: "Sources/Launcher"),
    ]
)
