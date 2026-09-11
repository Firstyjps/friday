#!/bin/zsh
# build แอป Friday (Swift, menu bar) → ~/Applications/Friday.app
# ใช้ Command Line Tools ได้ ไม่ต้องมี Xcode · เซ็นแบบ ad-hoc (build ใหม่ macOS อาจถามสิทธิ์ไมค์ใหม่)
set -euo pipefail
cd "${0:A:h}"
APP="$HOME/Applications/Friday.app"
ICON_SRC="../public/icon-512.png"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Friday"

# ปิดตัวเก่าก่อนแทนที่
pkill -x Friday 2>/dev/null || true

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Friday"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Friday</string>
  <key>CFBundleDisplayName</key><string>Friday</string>
  <key>CFBundleIdentifier</key><string>com.kron.friday</string>
  <key>CFBundleExecutable</key><string>Friday</string>
  <key>CFBundleIconFile</key><string>Friday</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Friday ใช้ไมค์เพื่อฟังคำปลุก "Friday" และคุยกับคุณ (ประมวลคำปลุกในเครื่อง)</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>com.kron.friday</string>
    <key>CFBundleURLSchemes</key><array><string>friday</string></array>
  </dict></array>
</dict></plist>
EOF

ICONSET="$(mktemp -d)/Friday.iconset"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2)); [[ $d -le 512 ]] && sips -z $d $d "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Friday.icns"

codesign --force --sign - --identifier com.kron.friday "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "✅ $APP"
