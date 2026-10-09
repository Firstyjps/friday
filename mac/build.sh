#!/bin/zsh
# build Friday → FridayCore.dylib (โค้ดจริง) + Friday.app (ตัวเปิด)
# - dylib + ฟอนต์ (Anuphan) ไปที่ ~/Library/Application Support/Friday/ ทุกครั้ง
# - Friday.app ติดตั้งใหม่เฉพาะเมื่อ Launcher/Info.plist/ไอคอนเปลี่ยน → ปกติ build ใหม่ไม่ต้องกด Allow ไมค์ซ้ำ
# - FRIDAY_NO_OPEN=1 → ติดตั้งอย่างเดียว ไม่เปิด/รีสตาร์ทแอป (แอปที่เปิดอยู่ใช้โค้ดเดิมจนกว่าจะเปิดใหม่)
set -euo pipefail
cd "${0:A:h}"
APP="$HOME/Applications/Friday.app"
SUPPORT="$HOME/Library/Application Support/Friday"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

# 1) โค้ดจริง → แทนที่แบบ atomic (แอปที่รันอยู่ยังใช้ของเก่าในหน่วยความจำได้)
mkdir -p "$SUPPORT"
cp "$BIN_DIR/libFridayCore.dylib" "$SUPPORT/.libFridayCore.new"
codesign --force --sign - "$SUPPORT/.libFridayCore.new" 2>/dev/null
mv -f "$SUPPORT/.libFridayCore.new" "$SUPPORT/libFridayCore.dylib"
mkdir -p "$SUPPORT/Fonts" && cp Resources/Fonts/*.ttf Resources/Fonts/OFL.txt "$SUPPORT/Fonts/"

# ไอคอนแอป "Fri the Fox" บน Night Sky — วาดพิกเซลตรงทุกขนาด (ไม่ย่อจากรูปใหญ่ ขอบจะได้คม)
ICONSET="$(mktemp -d)/Friday.iconset"
"$BIN_DIR/Friday" --make-iconset "$ICONSET"

# 2) ตัวแอป — เฉพาะเมื่อเปลี่ยน
# stamp คิดจาก source ของตัวเปิด (ไม่ใช่ไบนารี ซึ่งฝัง path ที่ build → build จาก worktree อื่นเคยทำให้ติดตั้งใหม่ + ถามสิทธิ์ไมค์ซ้ำ)
STAMP=$(cat Sources/Launcher/main.swift Package.swift Info.plist "$ICONSET"/*.png | shasum -a 256 | cut -c1-16)
OLD_STAMP=$(cat "$BIN_DIR/Friday" Info.plist "$ICONSET"/*.png | shasum -a 256 | cut -c1-16)   # สูตรเดิม (ก่อน 9 ต.ค.)
INSTALLED="$(cat "$APP/Contents/Resources/.stamp" 2>/dev/null)"
if [[ "$INSTALLED" == "$OLD_STAMP" && -d "$APP" ]]; then echo "$STAMP" > "$APP/Contents/Resources/.stamp"; INSTALLED="$STAMP"; fi   # ย้ายมาใช้สูตรใหม่โดยไม่ติดตั้งใหม่
if [[ "$INSTALLED" != "$STAMP" && -n "${FRIDAY_NO_OPEN:-}" && -d "$APP" ]] && pgrep -x Friday >/dev/null; then
  echo "⚠️  ตัวแอปเปลี่ยน แต่ FRIDAY_NO_OPEN → ไม่ปิดแอปที่เปิดอยู่ (build ใหม่โดยไม่ใส่ FRIDAY_NO_OPEN เพื่อติดตั้งตัวแอป)"
elif [[ "$INSTALLED" != "$STAMP" ]]; then
  echo "⚠️  ตัวแอปเปลี่ยน → ติดตั้งใหม่ (macOS จะถามสิทธิ์ไมค์อีกครั้ง)"
  pkill -x Friday 2>/dev/null || true
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp "$BIN_DIR/Friday" "$APP/Contents/MacOS/Friday"
  cp Info.plist "$APP/Contents/Info.plist"
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Friday.icns"
  echo "$STAMP" > "$APP/Contents/Resources/.stamp"
  codesign --force --sign - --identifier com.kron.friday "$APP"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
fi

# 3) รีสตาร์ทแอปให้ใช้โค้ดใหม่
if [[ -n "${FRIDAY_NO_OPEN:-}" ]]; then echo "✅ ติดตั้งแล้ว (ไม่ได้เปิดแอป)"; exit 0; fi
if pgrep -x Friday >/dev/null; then
  osascript -e 'tell application id "com.kron.friday" to quit' 2>/dev/null || pkill -x Friday
  for i in {1..10}; do pgrep -x Friday >/dev/null || break; sleep 0.5; done
fi
open "$APP"
echo "✅ Friday อัปเดตแล้ว ($SUPPORT/libFridayCore.dylib)"
