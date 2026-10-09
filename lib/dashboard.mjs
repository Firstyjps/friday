// ข้อมูลหน้าต่างหลัก Friday.app (Home / Tasks / History / Usage / Memory / Vault / Tools / System / Settings)
// อ่านอย่างเดียว ยกเว้น ความจำ (เพิ่ม/ลืม) และ config.json (ตั้งค่า/เปิดปิดเครื่องมือ)
import { readFile, appendFile, writeFile, readdir, stat, mkdir } from 'node:fs/promises';
import { join } from 'node:path';

const TZ = 'Asia/Bangkok';
const readText = (f) => readFile(f, 'utf8').catch(() => '');
const dayOf = (ms) => new Date(ms).toLocaleDateString('sv-SE', { timeZone: TZ });
const FINAL = new Set(['done', 'error', 'cancelled']);

// ---------- งาน (Tasks) → data/jobs.jsonl ----------
// job ใน memory ของ server หายตอนรีสตาร์ท → เขียนทุกครั้งที่สถานะเปลี่ยน (เช็คทุกวินาที) แถวหลังสุดของ id เดียวกันคือสถานะล่าสุด
export class JobLog {
  constructor(file) { this.file = file; this.sig = new Map(); this.bootAt = Date.now(); }

  record(j) {
    return { id: j.id, tool: j.tool ?? 'run_on_mac', via: j.via ?? 'Claude', hidden: !!j.hidden, task: j.task, status: j.status,
             result: j.result ? String(j.result).slice(0, 1200) : null, reason: j.reason ? String(j.reason).slice(0, 400) : null,
             cmd: j.cmd ? String(j.cmd).slice(0, 400) : null, convo: j.convo, startedAt: j.startedAt, endedAt: j.endedAt ?? null };
  }

  async sweep(jobs) {
    const out = [];
    for (const j of jobs.values()) {
      if (j.status === 'new') continue;
      if (FINAL.has(j.status) && !j.endedAt) j.endedAt = Date.now();
      const s = `${j.status}|${j.result?.length ?? 0}|${j.reason?.length ?? 0}|${j.cmd ?? ''}`;
      if (this.sig.get(j.id) === s) continue;
      this.sig.set(j.id, s); out.push(JSON.stringify(this.record(j)));
    }
    if (out.length) await mkdir(join(this.file, '..'), { recursive: true }).then(() => appendFile(this.file, out.join('\n') + '\n')).catch(() => {});
  }

  /// ทุกงาน (ใหม่สุดก่อน) — งานค้างจากก่อนรีสตาร์ท server ถือว่าไม่สำเร็จ
  async all(jobs) {
    await this.sweep(jobs);
    const map = new Map();
    for (const l of (await readText(this.file)).split('\n')) { if (!l) continue; try { const r = JSON.parse(l); map.set(r.id, r); } catch {} }
    for (const r of map.values()) {
      if (!FINAL.has(r.status) && !jobs.has(r.id) && r.startedAt < this.bootAt) {
        r.status = 'error'; r.result = r.result || 'Server restarted before this finished.';
      }
    }
    return [...map.values()].sort((a, b) => b.startedAt - a.startedAt);
  }
}

// ---------- บทสนทนา (History) ← ~/logs/friday-chat.log ----------
// บรรทัด: 2026-10-08T18:26:21Z | 🧑 ข้อความ  (🧑🔊/🤖🔊 = HomePod) · เว้นเกิน 3 นาที = คนละบทสนทนา
export function parseChat(text) {
  const lines = [];
  for (const l of text.split('\n')) {
    const m = l.match(/^(\S+Z) \| (🧑|🤖)(🔊)? ?(.*)$/u);
    if (!m) continue;
    const at = Date.parse(m[1]);
    if (!Number.isFinite(at)) continue;
    lines.push({ at, who: m[2] === '🧑' ? 'you' : 'friday', homepod: !!m[3], text: m[4].trim() });
  }
  const sessions = [];
  let cur = null;
  for (const ln of lines) {
    if (!cur || ln.at - cur.end > 3 * 60e3 || ln.homepod !== cur.homepod) { cur = { start: ln.at, end: ln.at, homepod: ln.homepod, lines: [] }; sessions.push(cur); }
    cur.end = ln.at; cur.lines.push({ who: ln.who, text: ln.text });
  }
  return sessions;
}

/// "You said" ของงาน: ประโยคผู้ใช้ที่ใกล้เวลาสั่งที่สุด (แอปเขียนบรรทัดผู้ใช้ตอนจบรอบ ซึ่งมักช้ากว่าเวลาสั่งงานไม่กี่วินาที)
export function originFor(job, chatLines) {
  let best = null, bestD = Infinity;
  for (const l of chatLines) {
    if (l.who !== 'you') continue;
    const d = l.at - job.startedAt;
    if (d < -3 * 60e3 || d > 45e3) continue;
    const score = d >= -2000 ? Math.abs(d) : Math.abs(d) * 3;   // ชอบบรรทัดที่ตามมาทันทีมากกว่าบรรทัดเก่า
    if (score < bestD) { bestD = score; best = l.text; }
  }
  return best;
}

export function chatLines(text) {
  const out = [];
  for (const l of text.split('\n')) {
    const m = l.match(/^(\S+Z) \| (🧑|🤖)(🔊)? ?(.*)$/u);
    if (m) out.push({ at: Date.parse(m[1]), who: m[2] === '🧑' ? 'you' : 'friday', text: m[4].trim() });
  }
  return out;
}

// ---------- ค่าใช้จ่าย (Usage / Home) ← data/usage.jsonl ----------
/// แยกเงินเป็น 4 ส่วน (USD) — แถว cascade ใหม่มี parts จริง · แถวเก่าประมาณจาก token · แถว Live คิดจาก pricing
function partsOf(r, p) {
  if (r.parts) return r.parts;
  if (r.usd != null) {
    const vo = Math.min(r.usd, (r.ttsTok || 0) * 6e-6 * 0.85);   // TTS: token ส่วนใหญ่คือเสียงออก
    return { vo, vi: 0, to: 0, ti: r.usd - vo };
  }
  return { vo: (r.outAudio || 0) * p.outAudio / 1e6, vi: (r.inAudio || 0) * p.inAudio / 1e6, to: (r.outText || 0) * p.outText / 1e6, ti: (r.inText || 0) * p.inText / 1e6 };
}

export function usageReport(rowsText, cfg, jobsAll, now = Date.now()) {
  const p = cfg.pricing ?? { inText: 0.75, inAudio: 3, outText: 4.5, outAudio: 12 };
  const rate = cfg.usdThb ?? 33.6;   // เท่ากับ usageSummary (get_usage) ใน server.mjs
  const rows = rowsText.split('\n').filter(Boolean).map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter((r) => r?.date);
  const usdOf = (r) => { const q = partsOf(r, p); return r.usd ?? (q.vo + q.vi + q.to + q.ti); };
  const byDay = new Map();
  for (const r of rows) {
    const d = byDay.get(r.date) ?? { usd: 0, sec: 0, convos: 0 };
    d.usd += usdOf(r); d.sec += r.seconds || 0; if (r.seconds) d.convos++;
    byDay.set(r.date, d);
  }
  const thb = (usd) => +(usd * rate).toFixed(2);
  const today = dayOf(now), month = today.slice(0, 7);
  const y = +month.slice(0, 4), mo = +month.slice(5, 7), dom = +today.slice(8, 10);
  const daysInMonth = new Date(y, mo, 0).getDate();
  const dayKey = (d) => `${month}-${String(d).padStart(2, '0')}`;
  const daysMtd = Array.from({ length: dom }, (_, i) => thb(byDay.get(dayKey(i + 1))?.usd ?? 0));
  const monthUsd = rows.filter((r) => r.date.startsWith(month)).reduce((n, r) => n + usdOf(r), 0);
  const avg = monthUsd / dom;
  const monthName = new Date(y, mo - 1, 1).toLocaleDateString('en-US', { month: 'long' });
  const monthShort = new Date(y, mo - 1, 1).toLocaleDateString('en-US', { month: 'short' });

  // สัปดาห์: 7 วันล่าสุด รวมวันนี้
  const week = Array.from({ length: 7 }, (_, i) => {
    const t = now - (6 - i) * 86400e3, key = dayOf(t), d = byDay.get(key);
    return { label: new Date(t).toLocaleDateString('en-US', { weekday: 'short', timeZone: TZ }), long: new Date(t).toLocaleDateString('en-US', { weekday: 'long', timeZone: TZ }), thb: thb(d?.usd ?? 0), sec: d?.sec ?? 0 };
  });
  const busiest = week.reduce((a, b) => (b.thb > a.thb ? b : a), week[0]);
  // เดือน: 5 สัปดาห์ล่าสุด (จันทร์–อาทิตย์) ป้ายเป็นวันแรกของสัปดาห์
  const dow = (new Date(now).toLocaleDateString('en-US', { weekday: 'short', timeZone: TZ }));
  const offset = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'].indexOf(dow);
  const monthBars = Array.from({ length: 5 }, (_, i) => {
    const start = now - (offset + (4 - i) * 7) * 86400e3;
    let usd = 0;
    for (let k = 0; k < 7; k++) usd += byDay.get(dayOf(start + k * 86400e3))?.usd ?? 0;
    return { label: new Date(start).toLocaleDateString('en-US', { month: 'short', day: 'numeric', timeZone: TZ }), thb: thb(usd) };
  });

  const monthRows = rows.filter((r) => r.date.startsWith(month));
  const parts = monthRows.reduce((a, r) => { const q = partsOf(r, p); a.vo += q.vo; a.vi += q.vi; a.to += q.to; a.ti += q.ti; return a; }, { vo: 0, vi: 0, to: 0, ti: 0 });

  // ที่สั่งบ่อย: ชื่องาน 30 วันล่าสุด (ไม่รวมเครื่องมือเบื้องหลัง)
  const counts = new Map();
  for (const j of jobsAll) if (!j.hidden && now - j.startedAt < 30 * 86400e3) counts.set(j.task, (counts.get(j.task) ?? 0) + 1);
  const tops = [...counts.entries()].sort((a, b) => b[1] - a[1]).slice(0, 5).map(([n, c]) => ({ n, c }));

  const todayRow = byDay.get(today);
  return {
    rate, month, monthName, monthShort, daysInMonth, dayOfMonth: dom,
    monthThb: thb(monthUsd), todayThb: thb(todayRow?.usd ?? 0), avgThb: thb(avg), projectedThb: Math.round(avg * daysInMonth * rate),
    daysMtd, todayMinutes: Math.round((todayRow?.sec ?? 0) / 60),
    week: { bars: week.map(({ label, thb: v }) => ({ label, thb: v })), thb: +week.reduce((n, d) => n + d.thb, 0).toFixed(2), minutes: Math.round(week.reduce((n, d) => n + d.sec, 0) / 60), busiest: busiest.thb > 0 ? busiest.long : null },
    monthBars, monthConversations: monthRows.filter((r) => r.seconds).length,
    parts: { voiceOut: thb(parts.vo), voiceIn: thb(parts.vi), textOut: thb(parts.to), textIn: thb(parts.ti) },
    tops,
  };
}

// ---------- Vault ← ~/Vault/10-projects/*-status.md ----------
export async function vaultProjects(dir, excludeSrc) {
  const exclude = new RegExp(excludeSrc, 'i');
  const files = (await readdir(dir).catch(() => [])).filter((f) => f.endsWith('-status.md'));
  const out = [];
  for (const f of files) {
    const full = join(dir, f);
    const [body, st] = await Promise.all([readText(full), stat(full).catch(() => null)]);
    const fm = body.match(/^---\n([\s\S]*?)\n---/)?.[1] ?? '';
    const name = f.replace(/-status\.md$/, '');
    const isProtected = exclude.test(f) || /\bfriday:\s*false\b/.test(fm);
    let status = fm.match(/^status:\s*"?(.*?)"?\s*$/m)?.[1]
      ?? body.match(/^(?:สถานะ|status)\s*[:：]\s*(.+)$/im)?.[1]
      ?? body.replace(/^---[\s\S]*?---\n/, '').split('\n').find((l) => l.trim() && !l.startsWith('#') && !l.startsWith('<!--'))?.trim() ?? '';
    status = status.replace(/[*`_[\]]/g, '').replace(/\s+/g, ' ').slice(0, 140);
    const done = (body.match(/^\s*[-*] \[x\]/gim) ?? []).length, open = (body.match(/^\s*[-*] \[ \]/gm) ?? []).length;
    const fmProgress = fm.match(/^progress:\s*(\d+)/m)?.[1];
    const progress = fmProgress != null ? Math.min(100, +fmProgress) : done + open > 0 ? Math.round(done / (done + open) * 100) : null;
    out.push({ name, status: isProtected ? null : status, protected: isProtected, progress: isProtected ? 0 : progress, updatedAt: st?.mtimeMs ?? 0 });
  }
  return out.sort((a, b) => b.updatedAt - a.updatedAt);
}

// ---------- log ล่าสุด (System) ← ~/logs/friday.log ----------
const NOISE = /^(ear level|ping \||ear ffmpeg|token prefill)/;
export function logTail(text, n = 14) {
  const out = [];
  const lines = text.split('\n');
  for (let i = lines.length - 1; i >= 0 && out.length < n; i--) {
    const m = lines[i].match(/^(\S+) \| (.*)$/);
    if (!m || NOISE.test(m[2])) continue;
    const msg = m[2];
    let tag = 'INFO';
    if (/error|ผิดพลาด|ล้มเหลว|ERR/i.test(msg)) tag = 'ERR';
    else if (/^JOB \S+ HOLD|^PERMISSION|confirm/i.test(msg)) tag = 'ASK';
    else if (/^JOB |^OPEN |^SHORTCUT/.test(msg)) tag = 'JOB';
    else if (/^(ear )?WAKE/.test(msg)) tag = 'WAKE';
    else if (/^wake check/.test(msg)) tag = 'NOWAKE';
    else if (/^CASCADE/.test(msg)) tag = 'TALK';
    else if (/^ear:|^room:/.test(msg)) tag = 'EAR';
    else if (/^HOMEPOD/.test(msg)) tag = 'POD';
    const t = Date.parse(m[1]);
    out.push({ time: Number.isFinite(t) ? new Date(t).toLocaleTimeString('en-GB', { timeZone: TZ, hour12: false }) : '', tag, msg: msg.slice(0, 220) });
  }
  return out;
}

// ---------- ความจำ ----------
export async function memoryNotes(file) {
  const lines = (await readText(file)).split('\n').filter((l) => l.trim());
  return lines.map((l, i) => {
    const m = l.match(/^- (\d{4}-\d{2}-\d{2}) (.*)$/);
    return { id: i, line: l, date: m?.[1] ?? null, text: m ? m[2] : l.replace(/^- /, '') };
  }).reverse();
}
export async function forgetNote(file, line) {
  const lines = (await readText(file)).split('\n');
  const i = lines.lastIndexOf(line);
  if (i < 0) return false;
  lines.splice(i, 1);
  await writeFile(file, lines.join('\n'));
  return true;
}

// ---------- config.json: เขียนเฉพาะคีย์ที่หน้าต่างแก้ได้ ----------
export function applySettings(cfg, b) {
  if (['ask', 'relaxed', 'full'].includes(b.trust)) cfg.trust = b.trust;
  if (['live', 'cascade'].includes(b.engine)) cfg.engine = b.engine;
  if (typeof b.voice === 'string' && /^[A-Za-z]{2,20}$/.test(b.voice)) {
    cfg.speechConfig = { voiceConfig: { prebuiltVoiceConfig: { voiceName: b.voice } } };
    if (cfg.cascade) cfg.cascade.voice = b.voice;
  }
  if (Number.isFinite(b.idleMs) && b.idleMs >= 5000 && b.idleMs <= 120000) cfg.idleMs = Math.round(b.idleMs);
  if (Number.isFinite(b.maxSessionSec) && b.maxSessionSec >= 60 && b.maxSessionSec <= 3600) cfg.maxSessionSec = Math.round(b.maxSessionSec);
  if (b.tool && typeof b.on === 'boolean' && b.tool !== 'run_on_mac') {
    const off = new Set(cfg.toolsOff ?? []);
    if (b.on) off.delete(b.tool); else off.add(b.tool);
    cfg.toolsOff = [...off];
  }
  if (typeof b.shortcut === 'string' && typeof b.on === 'boolean') {
    // shortcutsAll = ทุกชื่อที่เคยอนุญาต (ไว้โชว์ชิปที่ปิดอยู่) · shortcutsAllowed = ที่เปิดอยู่ (server เช็คตัวนี้)
    const all = cfg.shortcutsAll ?? [...(cfg.shortcutsAllowed ?? [])];
    if (!all.includes(b.shortcut)) return false;
    const on = new Set(cfg.shortcutsAllowed ?? []);
    if (b.on) on.add(b.shortcut); else on.delete(b.shortcut);
    cfg.shortcutsAll = all;
    cfg.shortcutsAllowed = all.filter((n) => on.has(n));
  }
  return true;
}

/// config ที่ส่งให้แอป/เว็บ/cascade: ตัด function ที่ผู้ใช้ปิดไว้ (toolsOff) ออกจาก tools
export function effectiveConfig(cfg) {
  const off = new Set(cfg.toolsOff ?? []);
  if (!off.size) return cfg;
  return { ...cfg, tools: (cfg.tools ?? []).map((t) => t.functionDeclarations ? { ...t, functionDeclarations: t.functionDeclarations.filter((f) => !off.has(f.name)) } : t),
           serverTools: (cfg.serverTools ?? []).filter((n) => !off.has(n)) };
}
