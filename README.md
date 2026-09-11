# Friday — ผู้ช่วยเสียงส่วนตัว

พูด **"Friday"** → คุยภาษาไทยกับ Gemini Live → สั่งงาน Mac ผ่าน Claude Code (มีด่านยืนยันงานเสี่ยง)

## ส่วนประกอบ

| ชิ้น | ที่อยู่ | หน้าที่ |
|---|---|---|
| **Friday.app** (Swift, menu bar) | `mac/` → `~/Applications/Friday.app` | หูฟังคำปลุก + คุย (AVAudioEngine + Apple voice processing ตัดเสียงสะท้อน) + หน้าต่างลอย |
| **server** (Node) | `server.mjs` · LaunchAgent `com.kron.friday` · :4850 | ออก token Gemini, `/api/mac` → Claude Code, ด่านยืนยัน, `/api/wake` → whisper, หูสำรอง |
| **whisper-server** | LaunchAgent `com.kron.friday-whisper` · :4851 | ถอดเสียงช่วงสั้นๆ เช็คคำปลุก (ggml-small, ไทย) ในเครื่อง |
| **เว็บ** | `public/` · https://macbook-air--kronkasem.tailf92605.ts.net | ใช้บน iPhone (Tailscale) · `?room=1` = โหมดห้องบนเบราว์เซอร์ (สำรอง) |
| **config กลาง** | `public/config.json` | model, system prompt, tools, คำยืนยัน — ใช้ทั้งแอปและเว็บ |

LaunchAgent `com.kron.friday-room` เปิด Friday.app ตอน login

## ใช้งาน

- พูด **"Friday"** (หรือ "Friday เปิด Chrome ให้หน่อย" รวดเดียว) → ติ๊ง → คุย · เงียบ 20 วิ → กลับไปรอคำปลุก
- **⌥⌘F** = เรียกคุยจากที่ไหนก็ได้ · ไอคอน menu bar = คุย/หยุด, แสดงหน้าต่าง, ปิดหู, เปิด log
- iPhone: **"หวัดดี Siri Friday"** (Shortcut แยกตามอุปกรณ์: Mac → `friday://room`, iPhone → เว็บ)
- ถ้าปิด Friday.app ไป server ยังฟังคำปลุกสำรอง (ffmpeg) → ได้ยิน "Friday" แล้วเปิดแอปให้เอง

## ด่านความปลอดภัย

1. คำสั่งที่มีคำเสี่ยง (ลบ/ย้าย/ส่ง/เงิน/เทรด/ติดตั้ง/deploy/ปิดเครื่อง…) ถูกกักไว้ → ต้องพูด "ยืนยัน" (เช็คจากเสียงผู้ใช้จริง) หรือกดปุ่ม · หมดอายุ 5 นาที
2. Claude ของ Friday ไม่มี MCP เลย (ไม่มี paybox/ms365 ฯลฯ)
3. deny คำสั่งอันตรายด้วย permission layer ของ Claude Code (sudo/diskutil เสมอ; rm/ssh/git push/osascript ถ้ายังไม่ยืนยัน)

## คำสั่งที่ใช้บ่อย

```bash
cd ~/Desktop/FRIDAY/mac && ./build.sh                          # build + ติดตั้งแอปใหม่
$(swift build -c release --show-bin-path)/Friday --selftest     # ทดสอบ Gemini Live โดยไม่ใช้ไมค์
launchctl kickstart -k gui/$(id -u)/com.kron.friday            # รีสตาร์ท server
tail -f ~/logs/friday.log                                       # WAKE/hear/JOB/ping
```

## หมายเหตุ

- แอปเซ็นแบบ ad-hoc → build ใหม่แล้ว macOS อาจถามสิทธิ์ไมค์อีกรอบ
- ปิดฝา (clamshell) ใช้ไมค์ภายนอก (หูฟัง / ลำโพงไมค์ประชุม USB) · Amphetamine ต้องไม่ติ๊ก "Allow system sleep when display is closed"
- `.env` = `GEMINI_API_KEY`, `ALLOWED_ORIGINS` (ห้าม commit)
