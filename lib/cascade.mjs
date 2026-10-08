import { createHash } from 'node:crypto';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { join } from 'node:path';

// โหมด cascade: เสียงผู้ใช้ → Gemini (text model, ฟังเสียงตรง) → ข้อความ → Gemini TTS (Despina) → เสียง
// แทน Gemini Live: ได้ข้อความทั้งประโยคเร็ว (ไม่ต้องรอถอดเสียงตามจังหวะพูด) + ไม่จ่ายค่าเสียงที่ไม่ได้ใช้
// แอป Mac คุยผ่าน POST /api/turn (NDJSON stream) — event หน้าตาเดียวกับ Gemini Live → ด่านความปลอดภัย/เครื่องมือในแอปใช้ของเดิมได้หมด
// วัดผลก่อนทำ: Vault friday-status.md (8 ต.ค. ขั้น 0)

const GEMINI = 'https://generativelanguage.googleapis.com/v1beta/models';
const SESSION_TTL = 30 * 60e3;

/// ราคา USD ต่อ 1M token (หน้า pricing ของ Google, 8 ต.ค. 2026) · แก้ได้ที่ config.cascade.prices
/// TTS รุ่น 3.8 ขึ้นเป็น 2 เท่าตั้งแต่ 1 ม.ค. 2027 (lite in 1 / out 12 · flash in 1 / out 18)
export const PRICES = {
  'gemini-3.1-flash-lite': { in: 0.25, inAudio: 0.5, out: 1.5 },
  'gemini-3.5-flash-lite': { in: 0.25, inAudio: 0.5, out: 1.5 },
  'gemini-3.8-flash-lite-tts': { in: 0.5, out: 6 },
  'gemini-3.8-flash-tts': { in: 0.5, out: 9 },
  'gemini-3.1-flash-tts-preview': { in: 1, out: 20 },
  'gemini-2.5-flash-native-audio-latest': { in: 0.5, out: 12 },   // Live (ทางสำรองตอน TTS เต็มโควตา)
};
const costOf = (model, u, prices) => {
  const p = prices[model]; if (!p || !u) return 0;
  const audioIn = (u.promptTokensDetails ?? []).filter((d) => d.modality === 'AUDIO').reduce((n, d) => n + d.tokenCount, 0);
  const cached = u.cachedContentTokenCount ?? 0;
  const textIn = (u.promptTokenCount ?? 0) - audioIn - cached;
  const out = (u.candidatesTokenCount ?? u.responseTokenCount ?? 0) + (u.thoughtsTokenCount ?? 0);   // Live ใช้ responseTokenCount
  return (textIn * p.in + audioIn * (p.inAudio ?? p.in) + cached * p.in * 0.1 + out * p.out) / 1e6;
};

const RULES = `

[โหมดคุยด้วยเสียง]
- ข้อมูลที่ได้รับแต่ละครั้งคือเสียงพูดของผู้ใช้หนึ่งช่วง (อาจขึ้นต้นด้วยคำปลุก "Friday/ฟรายเดย์" ไม่ต้องสนใจคำนั้น)
- ถ้าเสียงฟังไม่ออก หรือไม่ได้พูดกับคุณ (เสียงทีวี เสียงคนอื่นคุยกัน) ให้ตอบสั้นมากว่าไม่ได้ยินชัด หรือเงียบด้วยการเรียก end_conversation
- ตอบสั้นเป็นค่าเริ่มต้น 1–2 ประโยค ตอบเฉพาะที่ถาม ไม่เล่าเรื่องอื่นต่อเอง ถ้าผู้ใช้อยากรู้ละเอียดค่อยขยาย
- คำอังกฤษที่คนไทยพูดทับศัพท์ ให้เขียนเป็นภาษาไทย เช่น บิตคอยน์ โปรเจกต์ แอป ไฟล์ ฟรายเดย์ (เสียงจะลื่น ไม่สะดุดสลับภาษา) · ตัวเลขเขียนเป็นตัวเลขได้
- คำตอบของคุณจะถูกอ่านออกเสียงทันที: เขียนเป็นภาษาพูด ห้ามมีสัญลักษณ์ markdown ลิสต์ อีโมจิ หรือ URL
- ข้อความที่ขึ้นต้นด้วย [ผลจาก Mac …] ไม่ใช่คำพูดผู้ใช้ เป็นข้อมูลให้สรุปให้ผู้ใช้ฟัง
- ถ้าจะบอกว่า "เดี๋ยวเช็ค/เดี๋ยวทำให้" ต้องเรียกเครื่องมือในคำตอบเดียวกันเสมอ ห้ามพูดว่าจะทำแล้วไม่เรียก
- ถ้าผลเครื่องมือบอกว่าผู้ใช้ได้ยินประโยคแทรก (เช่น ขอดูให้ก่อน/รอสักครู่/ได้เลย) ไปแล้ว ห้ามพูดประโยคนั้นซ้ำ ถ้างานยัง running ตอบว่างได้
- ข้อมูลสดจากเว็บ (ข่าว ราคา อากาศ ผลบอล ฯลฯ) ให้ค้น Google ในตัวแล้วตอบเลย (เร็วกว่ามาก) ใช้ run_on_mac เฉพาะงานที่ต้องทำบนเครื่อง Mac · ห้ามเดาข้อมูลสด · ถามแค่วันเวลา ตอบจาก [เวลาตอนนี้] ด้านล่างได้เลย
- เล่าข่าว/ผลค้นหา: สรุปแค่ 2–3 เรื่องสำคัญ เรื่องละประโยคเดียว ไม่ต้องบอกแหล่งที่มา ถ้าผู้ใช้อยากรู้เพิ่มค่อยเล่าต่อ
- พื้นที่ดิสก์ แบตเตอรี่ uptime ของเครื่อง → ใช้ system_info เท่านั้น (ห้ามใช้ run_on_mac)`;

/// ช่วงแรกสั้น (ได้ยินเร็ว) · ที่เหลือรวมเป็นก้อนใหญ่ (TTS preview มี rate limit — ยิงน้อยครั้งดีกว่า)
const FIRST_MIN = 10, REST_MAX = 280;
const cut = (s, min) => {
  if (s.length < min) return -1;
  let best = -1;
  for (let i = min / 2; i < s.length; i++) if (/[\s.!?…,]/.test(s[i])) { best = i + 1; if (i >= min) break; }
  return best;
};
const clean = (t) => String(t || '').replace(/[*#`_>|•]/g, '').replace(/https?:\/\/\S+/g, '').replace(/\s+/g, ' ').trim();

export class Cascade {
  /** deps: { key, log, wav16k(pcm)→Buffer, scribe(wavBuf)→Promise<string|null> } */
  constructor(deps) {
    this.d = deps; this.sessions = new Map(); this.fillers = new Map();
    // รุ่น TTS ที่ติดโควตา (รายวัน) จำข้ามการรีสตาร์ท → ไม่ยิงไปโดน 429 ซ้ำ + เลือกเสียงแทรกรุ่นถูกตั้งแต่แรก
    this.blockFile = deps.cacheDir && join(deps.cacheDir, '..', 'tts-blocked.json');
    this.ttsBlocked = new Map();
    this.ready = this.blockFile ? readFile(this.blockFile, 'utf8').then((t) => { this.ttsBlocked = new Map(Object.entries(JSON.parse(t)).filter(([, v]) => v > Date.now())); }).catch(() => {}) : Promise.resolve();
  }

  open(id, { system, cfg }) {
    this.gc();
    this.sessions.set(id, { contents: [], system: system + RULES, cfg, at: Date.now(), calls: new Map(), busy: false });
    if (cfg.cascade?.filler !== false) this.warm(cfg);   // ทำเสียงเก็บไว้ก่อน → ตอนใช้ออกทันที
  }
  close(id) { this.sessions.delete(id); }
  /// ทำเสียงประโยคแทรกทีละประโยค (ยิงพร้อมกันตอนรุ่นหลักติดโควตา = 429 รัวๆ เปลืองโควตาที่เหลือ)
  async warm(cfg) {
    if (this.warming) return; this.warming = true; await this.ready;
    try { for (const t of FILLERS) await this.filler(cfg, t).catch(() => {}); } finally { this.warming = false; }
  }
  gc() { for (const [k, s] of this.sessions) if (Date.now() - s.at > SESSION_TTL) this.sessions.delete(k); }

  /**
   * หนึ่งรอบ: input = { audio: Buffer(PCM16 16k) } | { text } | { toolResponses: [{id, name, response}] }
   * emit(obj) ส่ง event ทีละบรรทัด: user / text / audio(b64) / tool / done{pending}
   */
  async turn(id, input, emit) {
    const s = this.sessions.get(id);
    if (!s) { emit({ t: 'error', error: 'no session' }); return; }
    s.at = Date.now();
    const c = s.cfg.cascade ?? {};
    const t0 = Date.now();
    const mark = (what) => this.d.log(`CASCADE ${id.slice(0, 6)} ${what} +${Date.now() - t0}ms`);
    // ตัวนับค่าใช้จ่ายรอบนี้ (บันทึกตอนจบรอบ → data/usage.jsonl)
    const prices = { ...PRICES, ...(c.prices ?? {}) };
    const meter = { usd: 0, llmTok: 0, ttsTok: 0, sttSec: input.audio ? input.audio.length / 32000 : 0 };
    const addUsage = (model, u) => { if (!u) return; meter.usd += costOf(model, u, prices);
      if (/tts/.test(model)) meter.ttsTok += u.totalTokenCount ?? 0; else meter.llmTok += u.totalTokenCount ?? 0; };
    const record = () => this.d.record?.({ app: 'cascade', usd: +meter.usd.toFixed(6), llmTok: meter.llmTok, ttsTok: meter.ttsTok, sttSec: +meter.sttSec.toFixed(1), kind: input.audio ? 'voice' : input.text ? 'text' : 'tool' });

    // ---- ข้อมูลเข้า ----
    let userText = null;              // promise ถอดเสียง (Scribe) — ต้องได้ก่อนส่ง tool ให้แอป (แอปเช็คว่าผู้ใช้พูดสั่ง/ยืนยันจริง)
    let userIdx = -1;
    if (input.audio) {
      const wav = this.d.wav16k(input.audio);
      userIdx = s.contents.length;
      s.contents.push({ role: 'user', parts: [{ inlineData: { mimeType: 'audio/wav', data: wav.toString('base64') } }] });
      userText = this.d.scribe(wav).then((t) => {
        const text = clean(t);
        if (text) {
          emit({ t: 'user', text }); mark(`ถอดเสียง "${text.slice(0, 40)}"`);
          s.contents[userIdx] = { role: 'user', parts: [{ text }] };     // รอบถัดไปไม่ต้องส่งเสียงซ้ำ (ประหยัด + เร็ว)
        }
        return text;
      }).catch((e) => { this.d.log(`CASCADE scribe error ${e.message}`); return ''; });
    } else if (input.text) {
      s.contents.push({ role: 'user', parts: [{ text: String(input.text).slice(0, 8000) }] });
    } else if (input.toolResponses?.length) {
      const said = s.saidFiller; s.saidFiller = null;
      // ทุกงานยัง running และผู้ใช้ได้ยิน "กำลังเช็คให้/สักครู่" ไปแล้ว → ไม่ต้องถามโมเดล (มันชอบพูดซ้ำ) ผลจริงจะตามมาเป็น [ผลจาก Mac]
      if (said && input.toolResponses.every((r) => r.response?.status === 'running')) {
        s.contents.push({ role: 'user', parts: input.toolResponses.map((r) => ({ functionResponse: { name: s.calls.get(r.id) ?? r.name, response: r.response } })) });
        s.contents.push({ role: 'model', parts: [{ text: said }] });
        for (const r of input.toolResponses) s.calls.delete(r.id);
        mark('งานยังทำอยู่ → เงียบรอผล'); emit({ t: 'done', pending: 0 }); return;
      }
      s.contents.push({ role: 'user', parts: input.toolResponses.map((r) => ({
        functionResponse: { name: s.calls.get(r.id) ?? r.name,
          response: said ? { ...(r.response ?? {}), spoken_to_user: `ผู้ใช้ได้ยิน "${said}" ไปแล้ว ไม่ต้องพูดซ้ำ` } : (r.response ?? {}) } })) });
      for (const r of input.toolResponses) s.calls.delete(r.id);
    } else { emit({ t: 'done', pending: 0 }); return; }

    // ---- เสียงออก: คิวเรียงลำดับ ทำเสียงขนานกันได้ ----
    let chain = Promise.resolve();
    let spoke = false;
    const speak = (text, ready) => {
      const t = clean(text);
      if (!t && !ready) return;
      spoke = true;
      // เริ่มทำเสียงทันที (ขนานกับช่วงก่อนหน้า) แต่ส่งออกตามลำดับ · ช่วงที่ถึงคิวแล้วส่งทีละก้อนตามที่ได้ (ไม่ต้องรอครบ)
      const q = { chunks: [], done: false, wake: null };
      const push = (b) => { q.chunks.push(b); q.wake?.(); };
      const fin = () => { q.done = true; q.wake?.(); };
      if (ready) ready.then((arr) => arr.forEach(push)).catch((e) => this.d.log(`CASCADE filler error ${e.message}`)).finally(fin);
      else this.tts(t, s.cfg, push, addUsage).catch((e) => this.d.log(`CASCADE tts error ${e.message}`)).finally(fin);
      chain = chain.then(async () => {
        let i = 0;
        while (true) {
          while (i < q.chunks.length) { if (!firstAudio) { firstAudio = true; mark('เสียงแรก'); } emit({ t: 'audio', b64: q.chunks[i++].toString('base64') }); }
          if (q.done) break;
          await new Promise((r) => { q.wake = r; });
          q.wake = null;
        }
      });
    };
    let firstAudio = false;

    // ---- Gemini ----
    let buf = '', first = true, gotFirst = false;
    const parts = [];
    const calls = [];
    // คำตอบช้า (กำลังค้น Google) → พูด "กำลังเช็คให้ค่ะ" ระหว่างรอ ไม่ให้เงียบ (คำตอบปกติข้อความแรกมาใน ~1–1.3 วิ)
    const slow = !input.toolResponses && c.filler !== false ? setTimeout(() => {
      const t = !gotFirst && !spoke && !calls.length ? pickFiller(s, 'lookup') : null;
      if (t) { speak(null, this.filler(s.cfg, t)); s.saidFiller = t; mark('ช้า → พูดแทรก'); }
    }, c.slowFillerMs ?? 3000) : null;
    try {
      await this.stream(s, c, addUsage, (p) => {
        if (p.thought) { parts.push(p); return; }
        if (p.text) {
          if (!gotFirst) { gotFirst = true; mark('ข้อความแรก'); }
          emit({ t: 'text', text: p.text });
          buf += p.text;
          const last = parts.at(-1);
          if (last && typeof last.text === 'string' && !last.functionCall && !last.thought) last.text += p.text; else parts.push({ ...p });
          // ทำเสียงทั้งคำตอบครั้งเดียว: แบ่งช่วง = แต่ละช่วงโทนต่างกัน + สะดุดตรงรอยต่อ (user บอก 9 ต.ค.) · แบ่งเฉพาะคำตอบยาวมาก
          if (first && c.splitFirst) { const k = cut(buf, FIRST_MIN); if (k > 0) { speak(buf.slice(0, k)); buf = buf.slice(k); first = false; } }
          else if (buf.length > REST_MAX) { const k = cut(buf, REST_MAX - 60); if (k > 0) { speak(buf.slice(0, k)); buf = buf.slice(k); } }
        }
        if (p.functionCall) { parts.push(p); calls.push(p.functionCall); }
        else if (!p.text) parts.push(p);           // ส่วนของการค้น Google (server-side) เก็บไว้ในประวัติตามที่ API ส่งมา
      });
    } catch (e) {
      clearTimeout(slow);
      this.d.log(`CASCADE gemini error ${e.message}`);
      if (userIdx >= 0 && !(await userText)) s.contents.splice(userIdx, 1);
      speak('ขอโทษค่ะ ตอนนี้ระบบมีปัญหา ลองพูดใหม่อีกทีนะคะ');
      await chain; record(); emit({ t: 'done', pending: 0 }); return;
    }
    clearTimeout(slow);
    if (buf.trim()) speak(buf);
    if (parts.length) s.contents.push({ role: 'model', parts });
    if (s.contents.length > 40) s.contents.splice(0, s.contents.length - 40);
    while (s.contents.length && (s.contents[0].role !== 'user' || s.contents[0].parts.some((p) => p.functionResponse))) s.contents.shift();

    // ---- เครื่องมือ: ส่งให้แอปทำ (แอปมีด่านความปลอดภัยเดิม) ----
    if (calls.length) {
      // พูดประโยคสั้นตามสถานการณ์ทันที (ทำเสียงเก็บไว้แล้ว) — โมเดลไม่ยอมพูดก่อนเรียกเครื่องมือเอง (ลอง 8 ต.ค.)
      const kind = !spoke && c.filler !== false ? fillerKind(calls) : null;
      const phrase = pickFiller(s, kind, { force: calls.some((fc) => fc.name === 'run_on_mac') });
      if (phrase) { speak(null, this.filler(s.cfg, phrase)); s.saidFiller = phrase; }
      // ประโยคแทรกจากโมเดลเอง (ถ้ามี) ไม่ต้องทับ — spoke=true แล้วจะไม่พูดซ้ำ
      if (userText) await Promise.race([userText, new Promise((r) => setTimeout(r, 4000))]);
      for (const fc of calls) {
        const cid = `c${Math.random().toString(36).slice(2, 10)}`;
        s.calls.set(cid, fc.name);
        emit({ t: 'tool', id: cid, name: fc.name, args: fc.args ?? {} });
      }
      mark(`tool ${calls.map((x) => x.name).join(',')}`);
    } else if (userText) await Promise.race([userText, new Promise((r) => setTimeout(r, 4000))]);
    await chain;
    mark(calls.length ? 'รอผลเครื่องมือ' : 'จบ');
    record();
    emit({ t: 'done', pending: calls.length });
  }

  // ---------- Gemini text (streaming) ----------
  // Gemini บางครั้งค้างไม่ตอบเลย (9 ต.ค. หลัง get_usage รอ 30 วิแล้ว timeout ผู้ใช้ไม่ได้คำตอบ)
  // → ยังไม่ได้อะไรกลับมาใน 12 วิ = ยกเลิกแล้วลองใหม่ 1 ครั้ง (ได้ข้อความบางส่วนไปแล้วจะไม่ลองซ้ำ)
  async stream(s, c, onUsage, onPart) {
    for (let attempt = 0; ; attempt++) {
      let got = false;
      try { return await this.streamOnce(s, c, onUsage, (p) => { got = true; onPart(p); }, c.firstByteMs ?? 12000); }
      catch (e) {
        if (got || attempt >= 1) throw e;
        this.d.log(`CASCADE gemini ลองใหม่ (${String(e.message).slice(0, 80)})`);
      }
    }
  }

  async streamOnce(s, c, onUsage, onPart, firstByteMs) {
    const model = c.model || 'gemini-3.1-flash-lite';   // 3.5-flash-lite ชอบพูดว่าจะเช็คแต่ไม่เรียกเครื่องมือ (1/4 vs 4/4, 8 ต.ค.)
    const stall = new AbortController();
    const timer = setTimeout(() => stall.abort(new Error(`ไม่ตอบใน ${firstByteMs}ms`)), firstByteMs);   // 3.5-flash-lite ชอบพูดว่าจะเช็คแต่ไม่เรียกเครื่องมือ (1/4 vs 4/4, 8 ต.ค.)
    const gc = c.thinkingLevel ? { thinkingConfig: { thinkingLevel: c.thinkingLevel } } : c.thinkingBudget != null ? { thinkingConfig: { thinkingBudget: c.thinkingBudget } } : {};
    const r = await fetch(`${GEMINI}/${model}:streamGenerateContent?alt=sse`, {
      method: 'POST', signal: AbortSignal.any([stall.signal, AbortSignal.timeout(30000)]),
      headers: { 'x-goog-api-key': this.d.key, 'Content-Type': 'application/json' },
      body: JSON.stringify({ systemInstruction: { parts: [{ text: `${s.system}\n\n[เวลาตอนนี้] ${new Date().toLocaleString('th-TH', { timeZone: 'Asia/Bangkok', dateStyle: 'full', timeStyle: 'short' })}` }] }, contents: s.contents,
        // googleSearch ในตัว: ข่าว/ราคา/อากาศ ตอบเองใน ~2–3 วิ (เดิมส่ง Claude 7–10 วิ) · ฟรี 5,000 ครั้ง/เดือน แล้ว $14/1k (8 ต.ค.)
        tools: [...(c.googleSearch !== false ? [{ googleSearch: {} }] : []), ...(s.cfg.tools ?? []).filter((t) => t.functionDeclarations)],
        ...(c.googleSearch !== false ? { toolConfig: { includeServerSideToolInvocations: true } } : {}), generationConfig: gc }),
    });
    try {
      if (!r.ok) throw new Error(`${model} ${r.status}: ${(await r.text()).slice(0, 200)}`);
      let usage = null;
      await sse(r, (j) => {
        if (j.usageMetadata) usage = j.usageMetadata;
        const parts = j.candidates?.[0]?.content?.parts ?? [];
        if (parts.length) clearTimeout(timer);
        for (const p of parts) onPart(p);
      });
      onUsage(model, usage);
    } finally { clearTimeout(timer); }
  }

  // ---------- Gemini TTS → PCM16 24k (ทีละก้อนตามที่มา) ----------
  /// Tier 1 จำกัด TTS 10 ครั้ง/นาที/โมเดล (วัด 8 ต.ค.) → วนหลายโมเดลที่มีเสียงเดียวกัน เลือกตัวที่ใช้น้อยสุดในนาทีล่าสุด เจอ 429 ข้ามไปตัวถัดไป
  ttsModels(c) { return c.ttsModels ?? [c.ttsModel || 'gemini-3.8-flash-lite-tts', 'gemini-3.8-flash-tts', 'gemini-3.1-flash-tts-preview']; }
  async tts(text, cfg, onChunk, onUsage = () => {}) {
    const c = cfg.cascade ?? {};
    const voice = c.voice || cfg.speechConfig?.voiceConfig?.prebuiltVoiceConfig?.voiceName || 'Despina';
    // ใช้รุ่นเดียวตามลำดับเสมอ (สลับรุ่น = โทนเปลี่ยน) · โดน 429 → พักรุ่นนั้นตามเวลาที่ Google บอก (โควตารายวัน 100 ครั้ง/รุ่น ใน Tier 1)
    const order = [...new Set(this.ttsModels(c))];
    let lastErr = '';
    for (const model of order) {
      if ((this.ttsBlocked?.get(model) ?? 0) > Date.now()) continue;
      const r = await fetch(`${GEMINI}/${model}:streamGenerateContent?alt=sse`, {
        method: 'POST', signal: AbortSignal.timeout(25000),
        headers: { 'x-goog-api-key': this.d.key, 'Content-Type': 'application/json' },
        // ห้ามใส่คำกำกับน้ำเสียงในข้อความ — รุ่น 3.8 อ่านออกเสียงไปด้วย (วัด 8 ต.ค.)
        body: JSON.stringify({ contents: [{ parts: [{ text }] }],
          generationConfig: { responseModalities: ['AUDIO'], speechConfig: { voiceConfig: { prebuiltVoiceConfig: { voiceName: voice } } } } }),
      });
      if (r.ok) {
        let n = 0, usage = null;
        await sse(r, (j) => { if (j.usageMetadata) usage = j.usageMetadata; for (const p of j.candidates?.[0]?.content?.parts ?? []) if (p.inlineData?.data) { n++; onChunk(Buffer.from(p.inlineData.data, 'base64')); } });
        onUsage(model, usage);
        if (n) return model;
        lastErr = `${model}: ไม่ได้เสียง`;
      } else {
        lastErr = `${model} ${r.status}: ${(await r.text()).replace(/\s+/g, ' ').slice(0, 600)}`;
        if (r.status === 429) {
          const m = lastErr.match(/retry in (?:(\d+)h)?(?:(\d+)m)?([\d.]+)s/);
          const wait = m ? ((+m[1] || 0) * 3600 + (+m[2] || 0) * 60 + (+m[3] || 0)) * 1000 : 20e3;
          this.ttsBlocked.set(model, Date.now() + Math.min(wait, 24 * 3600e3));
          if (this.blockFile) writeFile(this.blockFile, JSON.stringify(Object.fromEntries(this.ttsBlocked))).catch(() => {});
          this.d.log(`CASCADE tts 429 ${model} → พัก ${Math.round(wait / 60000)} นาที ใช้รุ่นถัดไป${/per_day/.test(lastErr) ? ' (โควตารายวันเต็ม)' : ''}`);
        }
      }
    }
    // ทุกรุ่น TTS เต็มโควตา/พัง → ให้ Gemini Live อ่านแทน (เสียงเดียวกัน ไม่มีโควตารายวันแบบ TTS · ช้ากว่า ~1 วิ)
    if (c.liveFallback !== false) {
      this.d.log(`CASCADE tts → Gemini Live (${lastErr.slice(0, 80)})`);
      return this.ttsLive(text, cfg, onChunk, onUsage, voice);
    }
    throw new Error(lastErr || 'ทุกโมเดลติดโควตา');
  }

  /** อ่านข้อความด้วย Gemini Live (WebSocket ครั้งเดียวจบ) → PCM16 24k */
  ttsLive(text, cfg, onChunk, onUsage, voice) {
    const model = cfg.cascade?.liveModel || 'gemini-2.5-flash-native-audio-latest';
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(`wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=${this.d.key}`);
      let n = 0, usage = null, done = false;
      const finish = (err) => { if (done) return; done = true; clearTimeout(t); try { ws.close(); } catch {} onUsage(model, usage);
        if (err && !n) reject(err); else resolve(model); };
      const t = setTimeout(() => finish(new Error('live tts timeout')), 25000);
      ws.onopen = () => ws.send(JSON.stringify({ setup: { model: `models/${model}`,
        generationConfig: { responseModalities: ['AUDIO'], speechConfig: { voiceConfig: { prebuiltVoiceConfig: { voiceName: voice } } } },
        systemInstruction: { parts: [{ text: 'คุณเป็นผู้หญิงไทย น้ำเสียงนุ่ม สบายๆ เมื่อได้รับข้อความ ให้อ่านออกเสียงตามตัวอักษรทุกคำ ห้ามเพิ่ม ห้ามตัด ห้ามตอบโต้ ห้ามทักทาย' }] } } }));
      ws.onmessage = async (e) => {
        const m = JSON.parse(typeof e.data === 'string' ? e.data : await e.data.text());
        if (m.setupComplete) ws.send(JSON.stringify({ realtimeInput: { text: `อ่านออกเสียง: ${text}` } }));
        if (m.usageMetadata) usage = m.usageMetadata;
        for (const p of m.serverContent?.modelTurn?.parts ?? []) if (p.inlineData?.data) { n++; onChunk(Buffer.from(p.inlineData.data, 'base64')); }
        if (m.serverContent?.turnComplete) finish();
      };
      ws.onerror = () => finish(new Error('live tts error'));
      ws.onclose = (e) => finish(e.code === 1000 ? null : new Error(`live tts closed ${e.code} ${e.reason}`));
    });
  }

  /** คำสั้นๆ ตอนเริ่มใช้เครื่องมือ — ทำเสียงครั้งเดียวต่อเสียง/ข้อความ แล้วเก็บไว้ */
  filler(cfg, text) {
    // แยกตามรุ่นที่ใช้อยู่ → ประโยคแทรกโทนเดียวกับคำตอบ (รุ่นหลักเต็มโควตา → ทำใหม่ด้วยรุ่นสำรอง)
    // เก็บลงดิสก์ (data/filler-cache) → รีสตาร์ท server ไม่ต้องทำเสียงใหม่ ไม่เปลืองโควตา TTS รายวัน (100 ครั้ง/รุ่น)
    const model = this.ttsModels(cfg.cascade ?? {}).find((m) => !((this.ttsBlocked?.get(m) ?? 0) > Date.now()));
    const k = `${cfg.cascade?.voice || cfg.speechConfig?.voiceConfig?.prebuiltVoiceConfig?.voiceName}|${model}|${text}`;
    if (!this.fillers.has(k)) {
      const file = this.d.cacheDir && join(this.d.cacheDir, `${createHash('sha1').update(k).digest('hex').slice(0, 16)}.pcm`);
      this.fillers.set(k, (async () => {
        if (file) { const b = await readFile(file).catch(() => null); if (b?.length) return [b]; }
        const out = [];
        const used = await this.tts(text, cfg, (b) => out.push(b));
        // บันทึกตามรุ่นที่ทำเสียงจริง (รุ่นหลักติดโควตา → ได้รุ่นสำรอง ครั้งหน้าก็จะเลือกรุ่นสำรองตรงกัน)
        if (this.d.cacheDir) {
          const real = join(this.d.cacheDir, `${createHash('sha1').update(k.replace(`|${model}|`, `|${used}|`)).digest('hex').slice(0, 16)}.pcm`);
          await mkdir(this.d.cacheDir, { recursive: true }).then(() => writeFile(real, Buffer.concat(out))).catch(() => {});
        }
        return out;
      })().catch((e) => { this.fillers.delete(k); throw e; }));
    }
    return this.fillers.get(k);
  }
}

/// ประโยคแทรก: สุ่มจากหลายแบบ (ซ้ำคำเดิมทุกครั้ง = น่ารำคาญ, user 9 ต.ค.) · ห้ามใช้ "แป๊บนึง" (user ไม่ชอบ)
const POOL = {
  lookup: ['ขอดูให้ก่อนนะคะ', 'เดี๋ยวดูให้ค่ะ', 'รอสักครู่นะคะ', 'กำลังเช็คให้ค่ะ'],
  task: ['ได้ค่ะ กำลังทำให้นะคะ', 'รอสักครู่นะคะ', 'ได้เลยค่ะ เดี๋ยวจัดการให้'],
  quick: ['ได้เลยค่ะ', 'ได้ค่ะ'],
};
export const FILLERS = [...new Set(Object.values(POOL).flat())];
const LOOKUP = /เช็ค|เช็ก|ดู|หา|ค้น|สรุป|ราคา|อากาศ|ข่าว|ไหม|อะไร|เท่าไ|กี่|ยังไง|อ่าน/;
const FILLER_COOLDOWN = 60e3;
/// เลือกประเภทตามเครื่องมือ · null = ไม่ต้องพูด (เครื่องมือเร็ว: vault_lookup/system_info/remember/get_usage หรือจบการคุย)
export function fillerKind(calls) {
  const names = calls.map((fc) => fc.name);
  if (names.some((n) => ['end_conversation', 'stop_listening', 'confirm_task'].includes(n))) return null;
  if (names.some((n) => ['run_shortcut', 'open_app', 'open_url'].includes(n))) return 'quick';
  const mac = calls.find((fc) => fc.name === 'run_on_mac');
  if (mac) return LOOKUP.test(String(mac.args?.task ?? '')) ? 'lookup' : 'task';
  return null;
}
/// สุ่มไม่ซ้ำกับครั้งก่อนในรอบคุยเดียวกัน · คำแทรกแบบรอ (lookup) ไม่พูดถี่กว่า 1 นาที ยกเว้นงานบน Mac ที่รอนานจริง
function pickFiller(s, kind, { force = false } = {}) {
  if (!kind) return null;
  if (kind !== 'quick' && !force && Date.now() - (s.fillerAt ?? 0) < FILLER_COOLDOWN) return null;
  const pool = POOL[kind].filter((t) => t !== s.lastFiller);
  const t = pool[Math.floor(Math.random() * pool.length)];
  s.lastFiller = t; if (kind !== 'quick') s.fillerAt = Date.now();
  return t;
}

async function sse(r, onJson) {
  let buf = '';
  for await (const chunk of r.body) {
    buf += Buffer.from(chunk).toString().replace(/\r/g, '');
    let i;
    while ((i = buf.indexOf('\n\n')) >= 0) {
      const line = buf.slice(0, i).split('\n').find((l) => l.startsWith('data: '));
      buf = buf.slice(i + 2);
      if (line) onJson(JSON.parse(line.slice(6)));
    }
  }
}
