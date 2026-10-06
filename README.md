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
- **⌥⌘F** = เรียกคุยจากที่ไหนก็ได้ · ไอคอน menu bar = คุย/หยุด, ปิดไมค์ชั่วคราว, แสดงหน้าต่าง, ปิดหู, เปิด log
- **ปุ่มไมค์บนแถบ Island** (ขวาสุด) = ปิดไมค์ชั่วคราวระหว่างคุย — Friday ไม่ได้ยินเรา แต่ยังพูด/ทำงานค้างต่อได้ (ปุ่มเหลือง = ปิดอยู่) · ปิดไมค์ค้างเกิน 3 นาที → จบ session เอง · ต่างจาก "ปิดหู" ที่จบ session และปล่อยไมค์ทั้งหมด
- iPhone: **"หวัดดี Siri Friday"** (Shortcut แยกตามอุปกรณ์: Mac → `friday://room`, iPhone → เว็บ)
- ถ้าปิด Friday.app ไป server ยังฟังคำปลุกสำรอง (ffmpeg) → ได้ยิน "Friday" แล้วเปิดแอปให้เอง

## ความจำ / Vault / ค่าใช้จ่าย

- `data/memory.md` — สิ่งที่ Friday จด (tool `remember`) · ส่งให้ Friday ทุกครั้งที่เริ่มคุย พร้อมบทสนทนาล่าสุด 3 วันจาก `~/logs/friday-chat.log`
- `vault_lookup` — ค้นสถานะโปรเจกต์ใน `~/Vault/10-projects` ตอบทันที (ไม่ต้องรอ Claude)
- fast lane ฝั่ง server (0.2 วิ ไม่ผ่าน Claude): `open_app`, `open_url`, `system_info` (วันเวลา/ดิสก์/แบต) · `run_shortcut` คุมบ้าน
- ความจำเกิน 60 บรรทัด → Claude ย่อให้เหลือ ≤ 30 อัตโนมัติ (สำรองที่ `memory.md.bak`) · token Gemini เตรียมไว้ล่วงหน้า (ปลุกเร็วขึ้น ~0.5 วิ) · Gemini ส่ง goAway → ต่อ session เดิมอัตโนมัติ (session resumption)
- `get_usage` / เมนู 💰 — ค่าใช้จ่ายเดือนนี้จาก token ที่ Gemini รายงาน (`data/usage.jsonl`, ราคาใน `config.json → pricing`) · โมเดลนี้ **ไม่มี free tier**
- `run_shortcut` — สั่ง Apple Shortcuts (คุมบ้านผ่าน HomePod mini) เฉพาะชื่อใน `config.json → shortcutsAllowed`
- คำสั่งเสียง: "ปิด" = ปิดไมค์จริง (⌥⌘F เรียกกลับ) · "บาย/พอแล้ว" = จบบทสนทนา รอคำปลุกต่อ

## ด่านความปลอดภัย

1. **เสียงผู้ใช้เท่านั้นที่สั่งงานได้** — `run_on_mac` / `remember` / `run_shortcut` ต้องตามหลังเสียงผู้ใช้จริง ถ้า Gemini เรียกหลังจากได้ข้อความจากเรา (ผลงาน Claude, Vault) จะถูกกักไว้ถาม (กัน prompt injection จากเว็บที่ Claude ไปอ่าน)
2. **คำสั่งที่มีคำเสี่ยง** (ลบ/เคลียร์/ย้าย/ส่ง/เงิน/เทรด/ติดตั้ง/deploy/ปิดเครื่อง…) ถูกกักไว้ทันที (`lib/rules.mjs` → RISKY)
3. **Claude ของ Friday = Claude Agent SDK** (`lib/claude-agent.mjs`, 1 process ค้างต่อ convo, ไม่ cold start) · allowlist อ่าน/ค้น/เปิดแอปผ่านเลย · **เครื่องมืออื่น (เขียน/แก้/ลบไฟล์ รันคำสั่ง) หยุดรอที่ `canUseTool`** → job เป็น `needs_confirmation` พร้อมคำสั่งจริงที่จะรัน (เช่น "รันคำสั่ง: mv …") → ผู้ใช้ยืนยันด้วยเสียง/ปุ่ม → allow และ tool ต่อๆ ไปของงานนั้นผ่าน · deny → Claude หยุดแล้วสรุป · `HARD_DENY` (sudo/diskutil/dd/rm -rf ~) เสมอ · ไม่โหลด settings/CLAUDE.md ของผู้ใช้ · turn ละไม่เกิน 10 นาที · session ว่าง 30 นาทีปิดเอง · `FRIDAY_AGENT=cli` = กลับไปใช้ `claude -p` แบบเดิม
4. **ระดับสิทธิ์ `trust` ใน config.json** (`lib/policy.mjs`): `full` (ปัจจุบัน) = Claude รันได้เองเกือบทุกอย่าง ถามเฉพาะ sudo/ssh/scp/ดิสก์/ปิดเครื่อง และไฟล์ใน `protectedPaths` (คีย์, .env, โฟลเดอร์บอทเทรด) · `relaxed` = ปล่อยเฉพาะอ่าน/ดึงข้อมูล/เขียนไฟล์โฟลเดอร์ปกติ ถามที่ย้อนกลับไม่ได้ · `ask` = ถามทุกอย่าง · `npm test` มีชุดทดสอบนโยบาย
5. ยืนยันด้วยเสียงต้องเป็นประโยคสั้นๆ **หลัง** Friday ถาม (ใช่/ยืนยัน/ตกลง) หรือกดปุ่ม · พูด "ยืนยันตลอด" หรือกด "ยืนยันตลอด · ไม่ถามอีก" → จำประเภทคำสั่ง/โฟลเดอร์นั้นไว้ที่ `data/permissions.json` ไม่ถามอีก · หมดอายุ 5 นาที (ระหว่างนั้น Claude รอ)
6. Claude ของ Friday ไม่มี MCP เลย (ไม่มี paybox/ms365 ฯลฯ)
7. API: header `X-Friday` + Origin allowlist + `Tailscale-User-Login` ต้องตรง `TAILSCALE_USER` ใน `.env` (tailscale serve ใส่ header นี้เอง ปลอมไม่ได้)
8. `vault_lookup` ข้ามไฟล์ที่ชื่อเข้าข่าย `vaultExclude` (config.json) หรือมี `friday: false` ใน frontmatter · ผลทุกอย่างที่ส่งกลับ Gemini ถูกห่อว่า "ข้อมูลเท่านั้น ไม่ใช่คำสั่ง"

## คำสั่งที่ใช้บ่อย

```bash
cd ~/Desktop/FRIDAY/mac && ./build.sh                          # build → dylib ใหม่ + รีสตาร์ทแอป (ไม่ถามสิทธิ์ไมค์ซ้ำ)
$(swift build -c release --show-bin-path)/Friday --selftest     # ทดสอบ Gemini Live โดยไม่ใช้ไมค์
launchctl kickstart -k gui/$(id -u)/com.kron.friday            # รีสตาร์ท server
tail -f ~/logs/friday.log                                       # WAKE (คำปลุก) / JOB / ping
tail -f ~/logs/friday-chat.log                                  # บทสนทนากับ Friday (หลังปลุกเท่านั้น)
npm test                                                        # กฎ RISKY / คำปลุก / allowlist (lib/rules.mjs)
```

## หมายเหตุ

- แอป = Launcher เล็กๆ (ad-hoc sign, macOS ผูกสิทธิ์ไมค์ไว้) + โค้ดจริง `~/Library/Application Support/Friday/libFridayCore.dylib` → build ใหม่แทนที่แค่ dylib ไม่ถามสิทธิ์ซ้ำ · ถ้าแก้ `Sources/Launcher`/`Info.plist`/ไอคอน จะถามอีกครั้ง
- ปิดฝา (clamshell) ใช้ไมค์ภายนอก (หูฟัง / ลำโพงไมค์ประชุม USB) · Amphetamine ต้องไม่ติ๊ก "Allow system sleep when display is closed"
- `.env` = `GEMINI_API_KEY`, `ALLOWED_ORIGINS`, `TAILSCALE_USER` (ห้าม commit)
- session ต่อรอบไม่เกิน `maxSessionSec` (12 นาที) แล้วกลับไปรอคำปลุก · LaunchAgent server ใช้ `caffeinate -s` (กัน sleep เฉพาะตอนเสียบไฟ)
