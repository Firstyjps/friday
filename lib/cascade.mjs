// โหมด cascade: เสียงผู้ใช้ → Gemini (text model, ฟังเสียงตรง) → ข้อความ → Gemini TTS (Despina) → เสียง
// แทน Gemini Live: ได้ข้อความทั้งประโยคเร็ว (ไม่ต้องรอถอดเสียงตามจังหวะพูด) + ไม่จ่ายค่าเสียงที่ไม่ได้ใช้
// แอป Mac คุยผ่าน POST /api/turn (NDJSON stream) — event หน้าตาเดียวกับ Gemini Live → ด่านความปลอดภัย/เครื่องมือในแอปใช้ของเดิมได้หมด
// วัดผลก่อนทำ: Vault friday-status.md (8 ต.ค. ขั้น 0)

const GEMINI = 'https://generativelanguage.googleapis.com/v1beta/models';
const SESSION_TTL = 30 * 60e3;

const RULES = `

[โหมดคุยด้วยเสียง]
- ข้อมูลที่ได้รับแต่ละครั้งคือเสียงพูดของผู้ใช้หนึ่งช่วง (อาจขึ้นต้นด้วยคำปลุก "Friday/ฟรายเดย์" ไม่ต้องสนใจคำนั้น)
- ถ้าเสียงฟังไม่ออก หรือไม่ได้พูดกับคุณ (เสียงทีวี เสียงคนอื่นคุยกัน) ให้ตอบสั้นมากว่าไม่ได้ยินชัด หรือเงียบด้วยการเรียก end_conversation
- คำตอบของคุณจะถูกอ่านออกเสียงทันที: เขียนเป็นภาษาพูด ห้ามมีสัญลักษณ์ markdown ลิสต์ อีโมจิ หรือ URL
- ข้อความที่ขึ้นต้นด้วย [ผลจาก Mac …] ไม่ใช่คำพูดผู้ใช้ เป็นข้อมูลให้สรุปให้ผู้ใช้ฟัง
- ถ้าจะบอกว่า "เดี๋ยวเช็ค/เดี๋ยวทำให้" ต้องเรียกเครื่องมือในคำตอบเดียวกันเสมอ ห้ามพูดว่าจะทำแล้วไม่เรียก
- ห้ามเดาข้อมูลสด (ราคา อากาศ ข่าว) ต้องใช้เครื่องมือ · วันเวลาปัจจุบันดูจาก [เวลาตอนนี้] ด้านล่าง ไม่ต้องเรียก system_info`;

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
  constructor(deps) { this.d = deps; this.sessions = new Map(); this.fillers = new Map(); }

  open(id, { system, cfg }) {
    this.gc();
    this.sessions.set(id, { contents: [], system: system + RULES, cfg, at: Date.now(), calls: new Map(), busy: false });
  }
  close(id) { this.sessions.delete(id); }
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
      s.contents.push({ role: 'user', parts: input.toolResponses.map((r) => ({
        functionResponse: { name: s.calls.get(r.id) ?? r.name, response: r.response ?? {} } })) });
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
      else this.tts(t, s.cfg, push).catch((e) => this.d.log(`CASCADE tts error ${e.message}`)).finally(fin);
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
    try {
      await this.stream(s, c, (p) => {
        if (p.thought) { parts.push(p); return; }
        if (p.text) {
          if (!gotFirst) { gotFirst = true; mark('ข้อความแรก'); }
          emit({ t: 'text', text: p.text });
          buf += p.text;
          const last = parts.at(-1);
          if (last && typeof last.text === 'string' && !last.functionCall && !last.thought) last.text += p.text; else parts.push({ ...p });
          if (first) { const k = cut(buf, FIRST_MIN); if (k > 0) { speak(buf.slice(0, k)); buf = buf.slice(k); first = false; } }
          else if (buf.length > REST_MAX) { const k = cut(buf, REST_MAX - 60); if (k > 0) { speak(buf.slice(0, k)); buf = buf.slice(k); } }
        }
        if (p.functionCall) { parts.push(p); calls.push(p.functionCall); }
      });
    } catch (e) {
      this.d.log(`CASCADE gemini error ${e.message}`);
      if (userIdx >= 0 && !(await userText)) s.contents.splice(userIdx, 1);
      speak('ขอโทษค่ะ ตอนนี้ระบบมีปัญหา ลองพูดใหม่อีกทีนะคะ');
      await chain; emit({ t: 'done', pending: 0 }); return;
    }
    if (buf.trim()) speak(buf);
    if (parts.length) s.contents.push({ role: 'model', parts });
    if (s.contents.length > 40) s.contents.splice(0, s.contents.length - 40);
    while (s.contents.length && (s.contents[0].role !== 'user' || s.contents[0].parts.some((p) => p.functionResponse))) s.contents.shift();

    // ---- เครื่องมือ: ส่งให้แอปทำ (แอปมีด่านความปลอดภัยเดิม) ----
    if (calls.length) {
      const quiet = calls.every((fc) => ['end_conversation', 'stop_listening', 'confirm_task', 'remember'].includes(fc.name));
      if (!spoke && !quiet && c.filler !== false) speak(null, this.filler(s.cfg));   // กำลังทำงาน → พูดคำสั้นๆ ไม่ให้เงียบ
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
    emit({ t: 'done', pending: calls.length });
  }

  // ---------- Gemini text (streaming) ----------
  async stream(s, c, onPart) {
    const model = c.model || 'gemini-3.5-flash-lite';
    const gc = c.thinkingLevel ? { thinkingConfig: { thinkingLevel: c.thinkingLevel } } : c.thinkingBudget != null ? { thinkingConfig: { thinkingBudget: c.thinkingBudget } } : {};
    const r = await fetch(`${GEMINI}/${model}:streamGenerateContent?alt=sse`, {
      method: 'POST', signal: AbortSignal.timeout(30000),
      headers: { 'x-goog-api-key': this.d.key, 'Content-Type': 'application/json' },
      body: JSON.stringify({ systemInstruction: { parts: [{ text: `${s.system}\n\n[เวลาตอนนี้] ${new Date().toLocaleString('th-TH', { timeZone: 'Asia/Bangkok', dateStyle: 'full', timeStyle: 'short' })}` }] }, contents: s.contents,
        tools: (s.cfg.tools ?? []).filter((t) => t.functionDeclarations), generationConfig: gc }),
    });
    if (!r.ok) throw new Error(`${model} ${r.status}: ${(await r.text()).slice(0, 200)}`);
    await sse(r, (j) => { for (const p of j.candidates?.[0]?.content?.parts ?? []) onPart(p); });
  }

  // ---------- Gemini TTS → PCM16 24k (ทีละก้อนตามที่มา) ----------
  /// Tier 1 จำกัด TTS 10 ครั้ง/นาที/โมเดล (วัด 8 ต.ค.) → วนหลายโมเดลที่มีเสียงเดียวกัน เลือกตัวที่ใช้น้อยสุดในนาทีล่าสุด เจอ 429 ข้ามไปตัวถัดไป
  ttsModels(c) { return c.ttsModels ?? [c.ttsModel || 'gemini-3.8-flash-lite-tts', 'gemini-3.8-flash-tts', 'gemini-3.1-flash-tts-preview']; }
  async tts(text, cfg, onChunk) {
    const c = cfg.cascade ?? {};
    const voice = c.voice || cfg.speechConfig?.voiceConfig?.prebuiltVoiceConfig?.voiceName || 'Despina';
    this.ttsLog ??= new Map();
    const now = Date.now();
    const used = (m) => (this.ttsLog.get(m) ?? []).filter((t) => now - t < 60e3).length;
    const order = [...new Set(this.ttsModels(c))].sort((a, b) => used(a) - used(b));
    let lastErr = '';
    for (const model of order) {
      if ((this.ttsBlocked?.get(model) ?? 0) > Date.now()) continue;
      this.ttsLog.set(model, [...(this.ttsLog.get(model) ?? []).filter((t) => now - t < 60e3), now]);
      const r = await fetch(`${GEMINI}/${model}:streamGenerateContent?alt=sse`, {
        method: 'POST', signal: AbortSignal.timeout(25000),
        headers: { 'x-goog-api-key': this.d.key, 'Content-Type': 'application/json' },
        // ห้ามใส่คำกำกับน้ำเสียงในข้อความ — รุ่น 3.8 อ่านออกเสียงไปด้วย (วัด 8 ต.ค.)
        body: JSON.stringify({ contents: [{ parts: [{ text }] }],
          generationConfig: { responseModalities: ['AUDIO'], speechConfig: { voiceConfig: { prebuiltVoiceConfig: { voiceName: voice } } } } }),
      });
      if (r.ok) {
        let n = 0;
        await sse(r, (j) => { for (const p of j.candidates?.[0]?.content?.parts ?? []) if (p.inlineData?.data) { n++; onChunk(Buffer.from(p.inlineData.data, 'base64')); } });
        if (n) return;
        lastErr = `${model}: ไม่ได้เสียง`;
      } else {
        lastErr = `${model} ${r.status}: ${(await r.text()).replace(/\s+/g, ' ').slice(0, 160)}`;
        if (r.status === 429) { (this.ttsBlocked ??= new Map()).set(model, Date.now() + 20e3); this.d.log(`CASCADE tts 429 ${model} → ตัวถัดไป`); }
      }
    }
    throw new Error(lastErr || 'ทุกโมเดลติดโควตา');
  }

  /** คำสั้นๆ ตอนเริ่มใช้เครื่องมือ — ทำเสียงครั้งเดียวต่อเสียง/ข้อความ แล้วเก็บไว้ */
  filler(cfg) {
    const text = cfg.cascade?.fillerText || 'แป๊บนึงนะคะ';
    const k = `${cfg.cascade?.voice || cfg.speechConfig?.voiceConfig?.prebuiltVoiceConfig?.voiceName}|${text}`;
    if (!this.fillers.has(k)) {
      const out = [];
      this.fillers.set(k, this.tts(text, cfg, (b) => out.push(b)).then(() => out).catch((e) => { this.fillers.delete(k); throw e; }));
    }
    return this.fillers.get(k);
  }
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
