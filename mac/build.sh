#!/bin/zsh
# build Friday → FridayCore.dylib (โค้ดจริง) + Friday.app (ตัวเปิด)
# - dylib ไปที่ ~/Library/Application Support/Friday/ ทุกครั้ง
# - Friday.app ติดตั้งใหม่เฉพาะเมื่อ Launcher/Info.plist/ไอคอนเปลี่ยน → ปกติ build ใหม่ไม่ต้องกด Allow ไมค์ซ้ำ
set -euo pipefail
cd "${0:A:h}"
APP="$HOME/Applications/Friday.app"
SUPPORT="$HOME/Library/Application Support/Friday"
ICON_SRC="../public/icon-512.png"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

# 1) โค้ดจริง → แทนที่แบบ atomic (แอปที่รันอยู่ยังใช้ของเก่าในหน่วยความจำได้)
mkdir -p "$SUPPORT"
cp "$BIN_DIR/libFridayCore.dylib" "$SUPPORT/.libFridayCore.new"
codesign --force --sign - "$SUPPORT/.libFridayCore.new" 2>/dev/null
mv -f "$SUPPORT/.libFridayCore.new" "$SUPPORT/libFridayCore.dylib"

# 2) ตัวแอป — เฉพาะเมื่อเปลี่ยน
STAMP=$(cat "$BIN_DIR/Friday" Info.plist "$ICON_SRC" | shasum -a 256 | cut -c1-16)
if [[ "$(cat "$APP/Contents/Resources/.stamp" 2>/dev/null)" != "$STAMP" ]]; then
  echo "⚠️  ตัวแอปเปลี่ยน → ติดตั้งใหม่ (macOS จะถามสิทธิ์ไมค์อีกครั้ง)"
  pkill -x Friday 2>/dev/null || true
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp "$BIN_DIR/Friday" "$APP/Contents/MacOS/Friday"
  cp Info.plist "$APP/Contents/Info.plist"
  ICONSET="$(mktemp -d)/Friday.iconset"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2)); [[ $d -le 512 ]] && sips -z $d $d "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Friday.icns"
  echo "$STAMP" > "$APP/Contents/Resources/.stamp"
  codesign --force --sign - --identifier com.kron.friday "$APP"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
fi

# 3) รีสตาร์ทแอปให้ใช้โค้ดใหม่
if pgrep -x Friday >/dev/null; then
  osascript -e 'tell application id "com.kron.friday" to quit' 2>/dev/null || pkill -x Friday
  for i in {1..10}; do pgrep -x Friday >/dev/null || break; sleep 0.5; done
fi
open "$APP"
echo "✅ Friday อัปเดตแล้ว ($SUPPORT/libFridayCore.dylib)"
