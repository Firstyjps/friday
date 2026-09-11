// swift-tools-version: 5.10
// Friday — แอป Mac (menu bar): ฟังคำปลุก → คุยกับ Gemini Live → สั่งงาน Mac ผ่าน server เดิม (:4850)
import PackageDescription

let package = Package(
    name: "Friday",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Friday", path: "Sources/Friday"),
    ]
)
