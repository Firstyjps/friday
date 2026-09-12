# Friday — Handoff สำหรับ Review / Optimize

> เขียนเมื่อ 12 ก.ย. 2026 · git `0124f32` (36 commits) · โค้ด ~2,500 บรรทัด · **อัปเดต: เฟส 0–3 ตาม `REVIEW-2026-09-12.md` แก้แล้ว — ส่วนที่บรรยาย RISKY/deny lists/`claude -p` ด้านล่างเป็นสถาปัตยกรรมเดิม ดู README ส่วนความปลอดภัยสำหรับของปัจจุบัน**
> อ่านคู่กับ [README.md](README.md) (วิธีใช้) และ Vault `10-projects/friday-status.md` (ประวัติทุกเฟส)

## 1. Friday คืออะไร
ผู้ช่วยเสียงส่วนตัวภาษาไทย พูด **"Friday"** แล้วคุยต่อได้เลย (Gemini Live, native audio) และสั่งงานบน Mac ได้ (Gemini เรียก tool → Claude Code `claude -p` บน Mac) มีด่านยืนยันงานเสี่ยง ใช้ได้ทั้งบน Mac (แอป menu bar) และ iPhone (เว็บผ่าน Tailscale)

## 2. สถาปัตยกรรม

```
[ไมค์] → Friday.app (Swift) ──VAD──> /api/wake ──> whisper-server (:4851, ggml-small, th)
              │  (ได้ยิน "Friday" ต้นประโยค)
              ├──WebSocket──> Gemini Live (gemini-3.1-flash-live-preview, ephemeral token)
              │                 └─ tool calls ─┐
              └── HTTP (X-Friday) ────────────> server.mjs (:4850, Node)
                                                 ├─ /api/token      ephemeral token (API key อยู่ server เท่านั้น)
                                                 ├─ /api/mac        → claude -p (คิวต่อ convo, --resume) + Telegram สำรอง
                                                 ├─ /api/mac/:id/confirm   ด่านยืนยันงานเสี่ยง
                                                 ├─ /api/tool/:name remember / vault_lookup / get_usage
                                                 ├─ /api/context    ความจำ + บทสนทนา 3 วัน → ต่อท้าย system prompt
                                                 ├─ /api/usage      ค่าใช้จ่าย (data/usage.jsonl)
                                                 └─ หูสำรอง ffmpeg (ทำงานเฉพาะเมื่อไม่มีแอป/เว็บ ping > 35s) → open Friday.app
iPhone Safari ──Tailscale serve (HTTPS, tailnet-only)──> public/ (เว็บ, logic เดียวกัน)
```

**config กลาง** `public/config.json` — model, system prompt, tools, คำยืนยัน/คำลา (regex), เสียง (Leda), ลำดับอุปกรณ์เสียง, ราคา · แอปและเว็บโหลดจากไฟล์นี้ → แก้พฤติกรรม/เสียงได้โดยไม่ build

## 3. แผนที่ไฟล์

| ไฟล์ | หน้าที่ |
|---|---|
| `server.mjs` | server ทั้งหมด (token pre-mint, jobs/Claude ผ่าน `lib/claude-agent.mjs`, ด่านยืนยันระดับ tool, หูสำรอง, context/memory/vault/usage, fast lane) |
| `lib/rules.mjs`, `lib/claude-agent.mjs`, `test/` | กฎ (RISKY/WAKE/allowlist) · Agent SDK session + canUseTool · `npm test` |
| `.../WakeDetector.swift` | VAD struct ล้วน (แยกจาก controller) |
| `public/config.json` | prompt + tools + ค่าตั้งทั้งหมด |
| `public/app.js`, `index.html` | เว็บ (iPhone / `?room=1` สำรอง) |
| `mac/Sources/Launcher/main.swift` | ตัวเปิดแอป 13 บรรทัด — `dlopen` dylib แล้วเรียก `friday_main` (**อย่าแก้ถ้าไม่จำเป็น** ดู §6) |
| `mac/Sources/Friday/App.swift` | AppDelegate, menu bar, panel, ⌥⌘F, `friday://`, จุดเข้า `friday_main` |
| `.../FridayController.swift` | state machine (starting/sleeping/connecting/live/error), VAD คำปลุก, tools, confirm gate, idle, จบเอง, usage |
| `.../AudioIO.swift` | AVAudioEngine แยก engine ไมค์/ลำโพง, เลือกอุปกรณ์ตามลำดับ, AEC (ลองครั้งเดียว), ตรวจไมค์เงียบ, hot-plug |
| `.../AudioDevices.swift` | CoreAudio: list/default/candidates/listener |
| `.../LiveSession.swift` | Gemini Live WebSocket (setup / realtimeInput / toolResponse / usageMetadata) |
| `.../ServerAPI.swift` | HTTP ไป server |
| `.../PanelView.swift` | SwiftUI หน้าต่างลอย (ไม่มี `@State` — CLT ไม่มี SwiftUI macros) |
| `.../SelfTest.swift` | `Friday --selftest` ทดสอบ Gemini ไม่ใช้ไมค์ (`FRIDAY_TEST_PROMPT=...`) |
| `mac/build.sh`, `mac/Info.plist` | build + ติดตั้ง |

**Runtime**: LaunchAgents `com.kron.friday` (server, caffeinate -i, KeepAlive) · `com.kron.friday-whisper` · `com.kron.friday-room` (เปิดแอปตอน login) · แอป `~/Applications/Friday.app` · dylib `~/Library/Application Support/Friday/libFridayCore.dylib`
**Logs**: `~/logs/friday.log` (WAKE/JOB/ear) · `friday-app.log` · `friday-chat.log` (บทสนทนาหลังปลุกเท่านั้น) · `friday-server.log` · `friday-whisper.log`
**Data**: `data/memory.md`, `data/usage.jsonl` (gitignored) · `.env` = `GEMINI_API_KEY`, `ALLOWED_ORIGINS`

## 4. การตัดสินใจสำคัญ (และเหตุผล)
- **Gemini Live สำหรับเสียง / Claude สำหรับลงมือ** — Claude ไม่มี realtime voice; Gemini ถูกสุด (แต่ **ไม่มี free tier**, ~$0.02/นาที)
- **Native Swift แทน Chrome** — Chrome ต้อง flag autoplay, AEC ไม่ครอบ Web Audio, RAM สูง
- **แยก Launcher + dylib** — แอปเซ็น ad-hoc; TCC ผูกสิทธิ์ไมค์กับ cdhash ของ launcher → build ใหม่แทนที่แค่ dylib ไม่ต้อง Allow ซ้ำ (ไม่ใช้ self-signed cert เพราะต้องแก้ trust ใน Keychain)
- **แยก engine ไมค์/ลำโพง** — AVAudioEngine เดียวใช้คนละอุปกรณ์ไม่ได้ (-10851)
- **Half-duplex** — Apple voice processing ใช้ไม่ได้บนเครื่องนี้ทุกคู่อุปกรณ์ (-10875) → ปิดไมค์ระหว่าง Friday พูด + 0.8s (กันลูปคุยกับตัวเอง) — พูดแทรกไม่ได้; ทางแก้ที่วางแผนไว้ = USB speakerphone (hardware AEC)
- **คำปลุกด้วย whisper ในเครื่อง** (ไม่ส่งเสียงออกนอกจนกว่าจะปลุก) · ต้องอยู่ต้นประโยค (prefix เฮ/เฮ้ย/นี่/hey ≤2 คำ) กันตื่นตอนพูดถึง
- **ด่านความปลอดภัย 3 ชั้น** — RISKY regex → ต้องยืนยัน (เช็คจาก transcript ผู้ใช้ ไม่เชื่อ Gemini อย่างเดียว) · Claude ของ Friday ไม่มี MCP (`--strict-mcp-config` + `ENABLE_CLAUDEAI_MCP_SERVERS=false`) · `--disallowedTools` (ยืนยันแล้วว่าใช้ได้แม้ skip-permissions)
- **Privacy** — ไม่ log เสียงที่ได้ยินทั่วไป; log เฉพาะคำปลุก + บทสนทนาหลังปลุก

## 5. ปัญหา/ข้อจำกัดที่รู้แล้ว (จุดเริ่ม review)
| # | เรื่อง | สถานะ |
|---|---|---|
| 1 | AEC ของ Apple ใช้ไม่ได้ (-10875) → พูดแทรกไม่ได้ | สาเหตุยังไม่รู้ ลองวิเคราะห์ได้ (อาจเกี่ยวกับ aggregate device / sample rate / Teams virtual device) |
| 2 | Gemini บางครั้งพูด "call end_conversation" ออกเสียง / ไม่เรียก tool ตอนลา | มี fallback regex คำลา + ตรวจชื่อ tool ใน transcript; ยังเกิดบ้าง |
| 3 | Gemini เรียก tool ซ้ำ (เช่น เปิด Chrome 2 รอบ) | server dedupe 30s แล้ว |
| 4 | ปลุกผิด (false wake) → งานไม่ได้ตั้งใจ (เคยเกิด: backtest katana 7 นาที) | แก้ด้วย wake ต้นประโยค; ยังไม่มีด่าน "ยืนยันก่อนงานที่ใช้เวลานาน/เขียนไฟล์" |
| 5 | งาน Claude ที่ไม่เข้า RISKY แต่เขียนไฟล์ได้ (cwd = HOME) | พิจารณา: จำกัด cwd / allowlist โฟลเดอร์ / งาน > N วินาทีต้องยืนยัน |
| 6 | whisper-server RAM ~650MB ตลอด | ตัวเลือก: ggml-base/tiny, หรือโหลดเมื่อใช้ |
| 7 | คำนวณค่าใช้จ่ายจาก usageMetadata (รวมทุก message) | ยังไม่ยืนยันว่าตรงกับบิลจริง — เทียบกับ AI Studio Usage |
| 8 | ความจำ = append-only `memory.md` + chat 3 วันต่อท้าย prompt | ไม่มีสรุป/ลบซ้ำ; prompt จะยาวขึ้นเรื่อยๆ (กินเงิน input text) |
| 9 | Live session ยาว > ~10–15 นาที อาจถูกตัด | ยังไม่ทำ session resumption / goAway handling |
| 10 | เว็บ iPhone ต้องแตะครั้งแรก (autoplay policy iOS) | ข้อจำกัด iOS |
| 11 | ค่า RISKY regex กว้าง (เช่น "อัปเดต", "ย้าย") → ถามยืนยันบ่อย | ปรับตามการใช้งานจริง |
| 12 | ไม่มี unit test เลย | มีแค่ `--selftest` + ทดสอบ API ด้วย curl |

## 6. ข้อห้าม / ข้อควรระวังสำหรับผู้ review
- **อย่าแก้ `mac/Sources/Launcher/`, `mac/Info.plist`, ไอคอน** โดยไม่จำเป็น → cdhash เปลี่ยน → ผู้ใช้ต้องกด Allow ไมค์ใหม่
- **อย่าสร้าง/trust certificate ใน Keychain** เอง (security setting — ให้ผู้ใช้ทำ)
- **อย่าให้ Claude ของ Friday มี MCP** (มี paybox = กระเป๋าเงิน, ms365 = ส่งอีเมล)
- **อย่า log เสียงที่ได้ยินก่อนปลุก** (บทสนทนาของคนในบ้าน)
- ห้ามแตะบอทเทรด/VPS ผ่าน Friday (ssh ถูก deny ถ้ายังไม่ยืนยัน) — ดู memory funding-executor: ไม้ HYPE ของผู้ใช้ห้ามแตะ
- `.env` ห้าม commit · build ใช้ Command Line Tools (ไม่มี Xcode) → ห้ามใช้ SwiftUI macros (`@State`, `@Observable`)

## 7. วิธีรัน / ทดสอบ
```bash
cd ~/Desktop/FRIDAY/mac && ./build.sh                                   # build + รีสตาร์ทแอป (ไม่ถาม Allow)
B=$(swift build -c release --show-bin-path); FRIDAY_TEST_PROMPT="โปรเจกต์ friday ถึงไหนแล้ว" $B/Friday --selftest
launchctl kickstart -k gui/$(id -u)/com.kron.friday                     # รีสตาร์ท server
curl -s -X POST localhost:4850/api/mac -H 'X-Friday: 1' -H 'Content-Type: application/json' -d '{"task":"บอกวันที่","convo":"t"}'
curl -s localhost:4850/api/usage -H 'X-Friday: 1'
tail -f ~/logs/friday.log ~/logs/friday-app.log
```
ทดสอบ wake regex: ดูชุดตัวอย่างใน commit `6b827b3` (ต้องปลุก: "Friday…", "เฮไฟเดย์", "เฮ้ย ไฟร์เดย์" · ต้องไม่ปลุก: "ได้ยินไหม Friday", "วันนี้ Friday…")

## 8. ขอให้ review อะไรบ้าง
1. **ความถูกต้อง/ความเสถียร** — state machine ใน FridayController (race: wake ระหว่าง connecting, endAfterSpeech, openAudio retry, config-change debounce), AudioIO teardown/rebuild, LiveSession close/reconnect
2. **ความปลอดภัย** — ช่องโหว่ด่านยืนยัน (Gemini แต่งคำสั่งเลี่ยง RISKY?), CSRF/Origin, Tailscale exposure, prompt injection จากผลงาน Claude / เนื้อหา Vault ที่ส่งกลับให้ Gemini
3. **แบต/ทรัพยากร** — CPU idle (~3–5% รวม coreaudiod), whisper RAM, VAD ใน Swift (ทุก 100ms บน main actor)
4. **Latency** — ปลุก→เสียงแรก (~2–3s), งาน Claude (~10–20s ต่องาน, cold start `claude -p`) → พิจารณา Claude session ค้างไว้ / งานเร็วทำฝั่ง server เอง
5. **ค่าใช้จ่าย** — ขนาด system prompt + context ต่อ session, idle 20s ก่อนตัด, ตรวจสูตรคำนวณ
6. **Code quality** — FridayController ใหญ่ (460 บรรทัด) ควรแยก; logic ซ้ำระหว่าง Swift กับ `public/app.js`
7. **ข้อเสนอพัฒนาต่อ** — full-duplex (USB speakerphone / WebRTC AEC), session resumption, สรุปความจำอัตโนมัติ, HomePod output, ยืนยันงานนาน, test suite

**Output ที่ต้องการ**: รายการ finding เรียงตามความรุนแรง (ไฟล์:บรรทัด + สถานการณ์ที่พัง + ข้อเสนอแก้) และแผน optimize เป็นเฟส — **ยังไม่ต้องแก้โค้ดจนกว่าผู้ใช้อนุมัติ**
