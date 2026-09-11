// Friday — local server: เสิร์ฟหน้าเว็บ + ออก ephemeral token ของ Gemini Live (API key ไม่ออกจาก Mac)
// + /api/mac: รับงานจาก tool run_on_mac → รัน Claude Code บน Mac → คืนผล (+ Telegram สำรอง)
import http from 'node:http';
import { spawn } from 'node:child_process';
import { readFile, appendFile, mkdir } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { homedir } from 'node:os';
import { extname, join } from 'node:path';

const PORT = Number(process.env.PORT || 4850);
const HOST = process.env.HOST || '127.0.0.1';
const KEY = process.env.GEMINI_API_KEY;
const HOME = homedir();
const PUBLIC = join(import.meta.dirname, 'public');
const LOG = join(HOME, 'logs', 'friday.log');
const CLAUDE = process.env.CLAUDE_BIN || join(HOME, '.local/bin/claude');
const QUICK_WAIT_MS = 12000;   // งานที่เสร็จภายในนี้ตอบใน tool call เลย ไม่งั้นแจ้งผลตามหลัง
const TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.webmanifest': 'application/manifest+json', '.png': 'image/png' };

// Origin ที่ยอมให้เรียก API (กันเว็บอื่นในเบราว์เซอร์ยิง /api/mac มาสั่ง Claude)
const ALLOWED_ORIGINS = new Set([`http://localhost:${PORT}`, `http://127.0.0.1:${PORT}`, ...(process.env.ALLOWED_ORIGINS || '').split(',').filter(Boolean)]);

const log = (line) => mkdir(join(HOME, 'logs'), { recursive: true }).then(() => appendFile(LOG, `${new Date().toISOString()} | ${line}\n`)).catch(() => {});

// ---------- Gemini token ----------
async function createToken() {
  if (!KEY) throw new Error('GEMINI_API_KEY ไม่ได้ตั้งใน ~/Desktop/FRIDAY/.env');
  const now = Date.now();
  const res = await fetch('https://generativelanguage.googleapis.com/v1beta/auth_tokens', {
    method: 'POST',
    headers: { 'x-goog-api-key': KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      uses: 1,
      expireTime: new Date(now + 30 * 60e3).toISOString(),
      newSessionExpireTime: new Date(now + 60e3).toISOString(),
    }),
  });
  const body = await res.json();
  if (!res.ok) throw new Error(`auth_tokens ${res.status}: ${JSON.stringify(body).slice(0, 300)}`);
  return body.name;
}

// ---------- Telegram (บอท Hermes, ส่งออกอย่างเดียว) ----------
let tgCfg;
async function telegram(text) {
  try {
    tgCfg ??= Object.fromEntries((await readFile(join(HOME, '.hermes/.env'), 'utf8')).split('\n')
      .map((l) => l.match(/^(TELEGRAM_BOT_TOKEN|TELEGRAM_ALLOWED_USERS)=(.*)$/)).filter(Boolean).map((m) => [m[1], m[2].trim()]));
    const chat = tgCfg.TELEGRAM_ALLOWED_USERS?.split(',')[0];
    if (!tgCfg.TELEGRAM_BOT_TOKEN || !chat) return;
    await fetch(`https://api.telegram.org/bot${tgCfg.TELEGRAM_BOT_TOKEN}/sendMessage`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ chat_id: chat, text: text.slice(0, 4000) }),
    });
  } catch (e) { log(`telegram error: ${e.message}`); }
}

// ---------- Claude jobs ----------
// หนึ่ง Friday session (convo) = หนึ่ง Claude session → "ทำต่อจากเมื่อกี้" ได้; งานใน convo เดียวกันรันเรียงคิว
const jobs = new Map();       // id → { id, convo, task, status, result, startedAt, promise }
const convos = new Map();     // convo → { claudeSession, tail: Promise }

const VOICE_RULES = `\n\n[คำสั่งนี้มาจากผู้ใช้ผ่านผู้ช่วยเสียง Friday (ถอดจากเสียง อาจฟังผิดได้) — ทำงานให้เสร็จ แล้วจบด้วยสรุปผลภาษาไทยสั้นๆ 1-3 ประโยคแบบภาษาพูด ไม่ใช้ markdown/ตาราง/โค้ดบล็อก เพราะจะถูกอ่านออกเสียง
กฎความปลอดภัย: ทำเฉพาะสิ่งที่สั่งตรงๆ เท่านั้น ถ้างานต้องทำสิ่งที่ย้อนกลับไม่ได้หรือกระทบภายนอก (ลบ/เขียนทับไฟล์, ส่งข้อความหาคนอื่น, เงิน/เทรด, deploy/push, แก้ระบบ) ที่ไม่ได้ถูกสั่งไว้ชัดเจน ให้หยุดแล้วรายงานกลับว่าต้องให้ผู้ใช้ยืนยันอะไร · ถ้าต้องลบไฟล์ ให้ย้ายไปถังขยะ (trash/Finder) แทน rm]`;

// ---------- ด่านความปลอดภัย ----------
// 1) งานที่คำสั่งดูเสี่ยง → ไม่รันทันที ต้องให้ผู้ใช้ยืนยันก่อน (เสียง "ใช่/ยืนยัน" หรือกดปุ่มบนจอ)
// 2) Claude ของ Friday ไม่มี MCP เลย (ตัด paybox/ms365/…) + deny คำสั่งอันตรายด้วย permission layer ของ Claude Code
const RISKY = new RegExp([
  'ลบ', 'ล้าง', 'ทิ้ง', 'เขียนทับ', 'แทนที่', 'ย้าย', 'เปลี่ยนชื่อ', 'แก้ไฟล์', 'แก้โค้ด', 'ฟอร์แมต',
  'ส่งข้อความ', 'ส่งอีเมล', 'ส่งเมล', 'ส่งไลน์', 'ตอบกลับ', 'โพสต์', 'ทวีต', 'แชร์', 'อัปโหลด', 'อัพโหลด',
  'ซื้อ', 'ขาย', 'จ่าย', 'โอน', 'เทรด', 'ออเดอร์', 'เปิดไม้', 'ปิดไม้', 'โพซิชัน', 'สั่งซื้อ', 'ถอนเงิน', 'ฝากเงิน',
  'ติดตั้ง', 'ถอนการติดตั้ง', 'อัปเดต', 'อัพเดท', 'ดีพลอย', 'พุช', 'ปิดเครื่อง', 'รีสตาร์ท', 'รีบูต', 'ตั้งค่า', 'รหัสผ่าน',
  'kill', 'ฆ่า', 'หยุดบอท', 'ปิดบอท',
  '\\b(delete|remove|rm|erase|wipe|overwrite|move|rename|send|reply|email|message|post|tweet|upload|share|buy|sell|pay|transfer|trade|order|position|flatten|install|uninstall|update|upgrade|deploy|push|merge|release|publish|shutdown|restart|reboot|kill|config|settings?|password)\\b',
].join('|'), 'i');

const HARD_DENY = ['Bash(sudo:*)', 'Bash(shutdown:*)', 'Bash(reboot:*)', 'Bash(diskutil:*)', 'Bash(rm -rf /*)', 'Bash(rm -rf ~*)', 'Bash(dd:*)', 'Bash(mkfs:*)'];
const UNCONFIRMED_DENY = ['Bash(rm:*)', 'Bash(rmdir:*)', 'Bash(git push:*)', 'Bash(git reset:*)', 'Bash(git clean:*)', 'Bash(ssh:*)', 'Bash(scp:*)', 'Bash(rsync:*)', 'Bash(osascript:*)', 'Bash(npm publish:*)', 'Bash(launchctl:*)', 'Bash(kill:*)', 'Bash(pkill:*)', 'Bash(killall:*)', 'Bash(curl -X POST:*)', 'Bash(vercel:*)'];

function runClaude(task, resumeId, confirmed) {
  return new Promise((resolve) => {
    const deny = confirmed ? HARD_DENY : [...HARD_DENY, ...UNCONFIRMED_DENY];
    const args = ['-p', '--dangerously-skip-permissions', '--output-format', 'json',
      '--strict-mcp-config', '--mcp-config', '{"mcpServers":{}}', '--disallowedTools', ...deny];
    if (resumeId) args.push('--resume', resumeId);
    args.push('--', task + VOICE_RULES);
    const child = spawn(CLAUDE, args, { cwd: HOME, env: { ...process.env, ENABLE_CLAUDEAI_MCP_SERVERS: 'false', PATH: `${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:${process.env.PATH}` } });
    let out = '', err = '';
    child.stdout.on('data', (d) => { out += d; });
    child.stderr.on('data', (d) => { err += d; });
    child.on('error', (e) => resolve({ ok: false, text: `รัน Claude ไม่ได้: ${e.message}` }));
    child.on('close', (code) => {
      try {
        const j = JSON.parse(out);
        resolve({ ok: !j.is_error, text: String(j.result ?? '').trim(), sessionId: j.session_id });
      } catch {
        resolve({ ok: false, text: (out || err || `claude exit ${code}`).trim().slice(0, 1500) });
      }
    });
  });
}

function createJob(convo, task) {
  const id = randomUUID().slice(0, 8);
  const job = { id, convo, task, status: 'new', result: null, confirmed: false, startedAt: Date.now() };
  jobs.set(id, job);
  if (RISKY.test(task)) {
    job.status = 'needs_confirmation';
    log(`JOB ${id} HOLD (risky) | ${task}`);
    setTimeout(() => { if (job.status === 'needs_confirmation') { job.status = 'cancelled'; job.result = 'หมดเวลายืนยัน'; log(`JOB ${id} expired`); } }, 5 * 60e3);
  } else startJob(job);
  return job;
}

function startJob(job) {
  const { id, convo, task } = job;
  const c = convos.get(convo) ?? { claudeSession: null, tail: Promise.resolve() };
  convos.set(convo, c);
  job.status = 'running'; job.startedAt = Date.now();
  log(`JOB ${id} start${job.confirmed ? ' (confirmed)' : ''} | ${task}`);
  job.promise = c.tail = c.tail.then(async () => {
    const r = await runClaude(task, c.claudeSession, job.confirmed);
    if (r.sessionId) c.claudeSession = r.sessionId;
    job.status = r.ok ? 'done' : 'error';
    job.result = r.text || '(ไม่มีผลลัพธ์)';
    const secs = Math.round((Date.now() - job.startedAt) / 1000);
    log(`JOB ${id} ${job.status} ${secs}s | ${job.result.slice(0, 300).replace(/\n/g, ' ')}`);
    telegram(`🎙️ Friday → Mac (${secs}s)\n${task}\n\n${job.result}`);
  });
  return job;
}

const view = (j) => ({ id: j.id, status: j.status, result: j.result, task: j.task });

// ---------- คำปลุก (โหมดห้อง) ----------
// หน้าเว็บส่งเสียงช่วงที่มีคนพูด (PCM16 16kHz mono) มา → whisper-server ในเครื่องถอดความ → เช็คคำว่า Friday
const WHISPER = process.env.WHISPER_URL || 'http://127.0.0.1:4851/inference';
const WAKE = /ฟรายเด|ไฟรเด|ฟายเด|ไฟร์เด|ฟรายเด้|ไฟเดย์|fri\s*day/i;

function pcmToWav(pcm) {
  const h = Buffer.alloc(44);
  h.write('RIFF', 0); h.writeUInt32LE(36 + pcm.length, 4); h.write('WAVE', 8);
  h.write('fmt ', 12); h.writeUInt32LE(16, 16); h.writeUInt16LE(1, 20); h.writeUInt16LE(1, 22);
  h.writeUInt32LE(16000, 24); h.writeUInt32LE(32000, 28); h.writeUInt16LE(2, 32); h.writeUInt16LE(16, 34);
  h.write('data', 36); h.writeUInt32LE(pcm.length, 40);
  return Buffer.concat([h, pcm]);
}

async function detectWake(pcm) {
  const form = new FormData();
  form.append('file', new Blob([pcmToWav(pcm)], { type: 'audio/wav' }), 'clip.wav');
  form.append('response_format', 'json');
  const r = await fetch(WHISPER, { method: 'POST', body: form });
  const text = ((await r.json()).text || '').trim();
  return { text, wake: WAKE.test(text) };
}

// ---------- หูเบื้องหลัง: ฟังคำปลุกตอนหน้าต่าง Friday ปิดอยู่ → เปิดหน้าต่างขึ้นมาเอง ----------
// หน้าต่างโหมดห้องส่ง ping ทุก 15s → ถ้ายังมีชีวิต หน้าต่างฟังเอง หูนี้ไม่ทำอะไร
const EAR = process.env.FRIDAY_EAR !== '0';
let roomSeenAt = 0, pendingWakeAt = 0, earCooldownUntil = 0;
const roomAlive = () => Date.now() - roomSeenAt < 35000;

const sh = (cmd, args) => new Promise((resolve) => {
  const p = spawn(cmd, args); let out = '';
  p.stdout.on('data', (d) => { out += d; }); p.stderr.on('data', (d) => { out += d; });
  p.on('close', () => resolve(out)); p.on('error', () => resolve(''));
});

async function defaultInputIndex() {
  const prof = JSON.parse(await sh('/usr/sbin/system_profiler', ['SPAudioDataType', '-json']) || '{}');
  const items = (prof.SPAudioDataType ?? []).flatMap((x) => x._items ?? []);
  const name = items.find((d) => d.coreaudio_default_audio_input_device === 'spaudio_yes')?._name;
  const list = await sh('/opt/homebrew/bin/ffmpeg', ['-hide_banner', '-f', 'avfoundation', '-list_devices', 'true', '-i', '']);
  const audio = list.split('AVFoundation audio devices:')[1] ?? '';
  const devs = [...audio.matchAll(/\[(\d+)\] (.+)/g)].map((m) => ({ idx: m[1], name: m[2].trim() }));
  const hit = devs.find((d) => d.name === name) ?? devs[0];
  return hit ? { ...hit } : null;
}

function startEar() {
  let ff = null, devName = null;
  let noise = 300, seg = [], voiced = 0, silent = 0, busy = false; const pre = [];
  let carry = Buffer.alloc(0);

  async function spawnFf() {
    const dev = await defaultInputIndex();
    if (!dev) { log('ear: ไม่พบไมค์'); return setTimeout(spawnFf, 30000); }
    devName = dev.name;
    ff = spawn('/opt/homebrew/bin/ffmpeg', ['-hide_banner', '-loglevel', 'error', '-f', 'avfoundation', '-i', `:${dev.idx}`,
      '-ac', '1', '-ar', '16000', '-f', 's16le', '-']);
    log(`ear: ฟังจาก "${dev.name}"`);
    ff.stdout.on('data', onPcm);
    ff.stderr.on('data', (d) => log(`ear ffmpeg: ${String(d).trim().slice(0, 200)}`));
    ff.on('close', (code) => { log(`ear: ffmpeg ปิด (${code}) — เริ่มใหม่ใน 5s`); ff = null; setTimeout(spawnFf, 5000); });
  }

  // ไมค์เปลี่ยน (เสียบ/ถอดหูฟัง/ลำโพงประชุม) → เริ่ม ffmpeg ใหม่ให้ตรงกับค่า default
  setInterval(async () => { const d = await defaultInputIndex(); if (ff && d && d.name !== devName) { log(`ear: ไมค์เปลี่ยนเป็น "${d.name}"`); ff.kill(); } }, 60000);

  function onPcm(d) {
    carry = Buffer.concat([carry, d]);
    while (carry.length >= 3200) {                 // 100ms @16kHz
      const chunk = carry.subarray(0, 3200); carry = carry.subarray(3200);
      if (roomAlive() || Date.now() < earCooldownUntil) { seg = []; voiced = silent = 0; continue; }
      vad(Buffer.from(chunk));
    }
  }

  let peak = 0, frames = 0;
  setInterval(() => { if (!roomAlive()) log(`ear level | frames=${frames} peak=${Math.round(peak)} noise=${Math.round(noise)}`); peak = 0; frames = 0; }, 60000);

  function vad(chunk) {
    let s = 0; for (let i = 0; i < chunk.length; i += 2) { const v = chunk.readInt16LE(i); s += v * v; }
    const level = Math.sqrt(s / (chunk.length / 2)); frames++; if (level > peak) peak = level;
    const speech = level > Math.max(noise * 3, 400);
    if (!speech && !seg.length) { noise = noise * 0.95 + level * 0.05; pre.push(chunk); if (pre.length > 3) pre.shift(); return; }
    if (!seg.length) seg.push(...pre.splice(0));
    seg.push(chunk);
    if (speech) { voiced++; silent = 0; } else silent++;
    if (silent >= 6 || seg.length >= 40) {
      const clip = Buffer.concat(seg), enough = voiced >= 3;
      seg = []; voiced = silent = 0;
      if (enough && !busy) check(clip);
    }
  }

  async function check(clip) {
    busy = true;
    try {
      const r = await detectWake(clip);
      log(`ear ${r.wake ? 'WAKE' : 'hear'} | ${r.text}`);
      if (r.wake && !roomAlive()) {
        pendingWakeAt = Date.now(); earCooldownUntil = Date.now() + 15000;
        spawn('/usr/bin/open', ['-a', join(HOME, 'Applications/Friday.app')]);
      }
    } catch (e) { log(`ear error: ${e.message}`); }
    finally { busy = false; }
  }

  spawnFf();
}
if (EAR) startEar();

const readRaw = (req, max = 32000 * 10) => new Promise((resolve, reject) => {
  const chunks = []; let n = 0;
  req.on('data', (d) => { n += d.length; if (n > max) req.destroy(); else chunks.push(d); });
  req.on('end', () => resolve(Buffer.concat(chunks))); req.on('error', reject);
});

// ---------- HTTP ----------
const json = (res, code, obj) => { res.writeHead(code, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(obj)); };
const readBody = (req) => new Promise((resolve, reject) => {
  let b = ''; req.on('data', (d) => { b += d; if (b.length > 1e5) req.destroy(); });
  req.on('end', () => { try { resolve(b ? JSON.parse(b) : {}); } catch (e) { reject(e); } }); req.on('error', reject);
});
function apiAllowed(req) {
  // ต้องมี header เฉพาะ (เว็บอื่นส่งข้าม origin ไม่ได้ถ้าไม่ผ่าน preflight) + Origin ต้องอยู่ใน allowlist
  if (req.headers['x-friday'] !== '1') return false;
  const origin = req.headers.origin;
  return !origin || ALLOWED_ORIGINS.has(origin);
}

http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://x');
    if (url.pathname.startsWith('/api/')) {
      // หน้าต่างกำลังปิด (sendBeacon ใส่ header เองไม่ได้ — endpoint นี้แค่บอกว่าหน้าต่างปิดแล้ว ไม่มีผลอื่น)
      if (req.method === 'POST' && url.pathname === '/api/bye') { roomSeenAt = 0; log('room: หน้าต่างปิด → หูเบื้องหลังฟังแทน'); return json(res, 200, { ok: true }); }
      if (!apiAllowed(req)) return json(res, 403, { error: 'forbidden' });
      if (req.method === 'POST' && url.pathname === '/api/room-hello') {
        roomSeenAt = Date.now();
        const wake = Date.now() - pendingWakeAt < 20000; pendingWakeAt = 0;
        return json(res, 200, { wake });
      }
      if (req.method === 'POST' && url.pathname === '/api/token') return json(res, 200, { token: await createToken() });
      if (req.method === 'POST' && url.pathname === '/api/ping') {   // heartbeat จากหน้าโหมดห้อง (debug)
        const b = await readBody(req); roomSeenAt = Date.now(); if (b.track !== 'live' || b.ctx !== 'running') log(`ping ⚠️ | ${JSON.stringify(b)}`); return json(res, 200, { ok: true });
      }
      if (req.method === 'POST' && url.pathname === '/api/wake') {
        const r = await detectWake(await readRaw(req));
        log(`${r.wake ? 'WAKE' : 'hear'} | ${r.text}`);
        return json(res, 200, r);
      }
      if (req.method === 'POST' && url.pathname === '/api/mac') {
        const { task, convo } = await readBody(req);
        if (!task || typeof task !== 'string') return json(res, 400, { error: 'task required' });
        const job = createJob(String(convo || 'default'), task.slice(0, 4000));
        if (job.promise) await Promise.race([job.promise, new Promise((r) => setTimeout(r, QUICK_WAIT_MS))]);
        return json(res, 200, view(job));
      }
      const c = url.pathname.match(/^\/api\/mac\/(\w+)\/confirm$/);
      if (req.method === 'POST' && c) {
        const job = jobs.get(c[1]);
        if (!job) return json(res, 404, { error: 'no such job' });
        if (job.status !== 'needs_confirmation') return json(res, 409, view(job));
        const { approve } = await readBody(req);
        if (approve === true) { job.confirmed = true; startJob(job); }
        else { job.status = 'cancelled'; job.result = 'ผู้ใช้ยกเลิก'; log(`JOB ${job.id} cancelled`); }
        if (job.promise) await Promise.race([job.promise, new Promise((r) => setTimeout(r, QUICK_WAIT_MS))]);
        return json(res, 200, view(job));
      }
      const m = url.pathname.match(/^\/api\/mac\/(\w+)$/);
      if (req.method === 'GET' && m) {
        const job = jobs.get(m[1]);
        return job ? json(res, 200, view(job)) : json(res, 404, { error: 'no such job' });
      }
      return json(res, 404, { error: 'not found' });
    }
    const path = url.pathname === '/' ? '/index.html' : url.pathname;
    if (path.includes('..')) return json(res, 400, { error: 'bad path' });
    const data = await readFile(join(PUBLIC, path));
    res.writeHead(200, { 'Content-Type': TYPES[extname(path)] || 'application/octet-stream', 'Cache-Control': 'no-cache' });
    res.end(data);
  } catch (e) {
    if (e.code === 'ENOENT') return json(res, 404, { error: 'not found' });
    console.error(e);
    json(res, 500, { error: e.message });
  }
}).listen(PORT, HOST, () => console.log(`Friday → http://${HOST}:${PORT}`));
