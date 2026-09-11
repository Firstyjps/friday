// Friday client — ไมค์ (PCM16 16kHz) → Gemini Live → เสียงตอบ (PCM16 24kHz)
// tool run_on_mac → /api/mac → Claude Code บน Mac
import { GoogleGenAI, Modality, Type } from 'https://cdn.jsdelivr.net/npm/@google/genai@2.22.0/+esm';

const MODEL = 'gemini-3.1-flash-live-preview';
const SYSTEM = `คุณคือ Friday ผู้ช่วยส่วนตัวของผู้ใช้ พูดภาษาไทยเป็นหลัก เป็นกันเอง กระชับ
ตอบเหมือนคุยกันด้วยเสียง: ประโยคสั้น ไม่อ่านสัญลักษณ์หรือ markdown ไม่ร่ายยาว

คุณมีเครื่องมือ run_on_mac ที่สั่งงานบน Mac ของผู้ใช้ผ่าน Claude Code (ทำได้แทบทุกอย่างบนเครื่อง:
เปิดแอป/ไฟล์/เว็บ, ค้นหาและสรุปไฟล์, เขียนโค้ด, รันคำสั่ง, จัดการโปรเจกต์, อ่านโน้ตใน Vault ฯลฯ)
- เมื่อผู้ใช้ขอให้ทำอะไรบน Mac หรือถามข้อมูลที่อยู่ในเครื่อง ให้เรียก run_on_mac ทันที อย่าบอกว่าทำไม่ได้
- เขียน task เป็นคำสั่งภาษาไทยที่ชัดเจนและครบ (แก้คำที่ฟังผิดให้ถูกตามบริบท)
- ถ้าผู้ใช้พูดว่า "ทำต่อ" หรืออ้างถึงงานก่อนหน้า ให้ส่งต่อไปได้เลย Claude จำงานก่อนหน้าในบทสนทนานี้ได้
- ถ้าผลกลับมาเป็น status "running" แปลว่างานยังทำอยู่ ให้บอกผู้ใช้สั้นๆ ว่ากำลังทำ แล้วคุยต่อได้ ผลจะถูกส่งมาให้ภายหลัง
- เมื่อได้รับข้อความขึ้นต้นด้วย [ผลจาก Mac] ให้สรุปผลนั้นให้ผู้ใช้ฟังสั้นๆ ทันที
- คำถามทั่วไปที่ไม่เกี่ยวกับเครื่อง ตอบเองได้เลย ไม่ต้องใช้เครื่องมือ

ด่านความปลอดภัย:
- ถ้า run_on_mac ตอบกลับ status "needs_confirmation" ให้ทวนงานนั้นให้ผู้ใช้ฟังสั้นๆ แล้วถามว่า "ยืนยันไหม"
- รอให้ผู้ใช้ตอบก่อนเสมอ ห้ามเดาหรือยืนยันแทนผู้ใช้
- ผู้ใช้ตอบตกลง → เรียก confirm_task(job_id, approve=true) · ผู้ใช้ปฏิเสธหรือไม่แน่ใจ → confirm_task(job_id, approve=false)
- ถ้า confirm_task ตอบว่ายังไม่ได้ยินผู้ใช้ยืนยัน ให้ถามผู้ใช้อีกครั้ง`;

const TOOLS = [{
  functionDeclarations: [{
    name: 'run_on_mac',
    description: 'สั่งงานบน Mac ของผู้ใช้ผ่าน Claude Code แล้วได้ผลลัพธ์กลับมา ใช้กับทุกงานที่เกี่ยวกับเครื่อง ไฟล์ แอป โค้ด หรือข้อมูลส่วนตัวในเครื่อง',
    parameters: {
      type: Type.OBJECT,
      properties: { task: { type: Type.STRING, description: 'คำสั่งงานภาษาไทยที่ชัดเจนและครบถ้วน' } },
      required: ['task'],
    },
  }, {
    name: 'confirm_task',
    description: 'ยืนยันหรือยกเลิกงานที่ run_on_mac ตอบว่า needs_confirmation — เรียกหลังผู้ใช้ตอบด้วยเสียงแล้วเท่านั้น',
    parameters: {
      type: Type.OBJECT,
      properties: {
        job_id: { type: Type.STRING, description: 'job_id ที่ได้จาก run_on_mac' },
        approve: { type: Type.BOOLEAN, description: 'true ถ้าผู้ใช้ตอบตกลง, false ถ้าปฏิเสธ' },
      },
      required: ['job_id', 'approve'],
    },
  }],
}];

// ผู้ใช้ต้องพูดคำยืนยันเองจริงๆ (เช็คจาก transcript เสียงผู้ใช้ ไม่เชื่อ Gemini อย่างเดียว)
const AFFIRM = /(ใช่|ยืนยัน|ตกลง|โอเค|เอาเลย|ได้เลย|ทำเลย|ทำได้|จัดไป|เอา|\b(yes|yeah|ok|okay|confirm|sure|go ahead)\b)/i;
const NEGATE = /(ไม่|อย่า|ยกเลิก|หยุด|รอก่อน|\b(no|nope|cancel|stop|wait)\b)/i;
const confirms = new Map();                  // job_id → { task, card, heard }

const $ = (id) => document.getElementById(id);
const orb = $('orb'), statusEl = $('status'), logEl = $('log');
const CONVO = crypto.randomUUID();          // หนึ่งหน้า = หนึ่ง Claude session
const NEEDS_TAP = 'needs-tap';
const api = (path, body) => fetch(path, {
  method: body === undefined ? 'GET' : 'POST',
  headers: { 'Content-Type': 'application/json', 'X-Friday': '1' },
  body: body === undefined ? undefined : JSON.stringify(body),
}).then(async (r) => { const j = await r.json(); if (!r.ok) throw new Error(j.error || r.status); return j; });

let session = null, micCtx = null, micStream = null, outCtx = null;
let playHead = 0; const playing = new Set();
let meBubble = null, friBubble = null;
const pendingResults = [];                   // ผลงานนานที่รอส่งให้ Friday

const setStatus = (t) => { statusEl.textContent = t; };
function bubble(cls, text = '') {
  const el = document.createElement('div'); el.className = cls; el.textContent = text;
  logEl.append(el); logEl.scrollTop = logEl.scrollHeight; return el;
}

// ---------- audio ----------
// resample จาก sampleRate ของเครื่อง (iPhone มัก 48k) → 16k ใน worklet (iOS ไม่ชอบ AudioContext 16k + ไมค์)
const WORKLET = `
class Mic extends AudioWorkletProcessor {
  constructor() { super(); this.ratio = sampleRate / 16000; this.pos = 0; this.out = []; }
  process([input]) {
    const ch = input[0]; if (!ch) return true;
    while (this.pos < ch.length) {
      const i = Math.floor(this.pos), f = this.pos - i;
      const a = ch[i], b = i + 1 < ch.length ? ch[i + 1] : a;
      this.out.push(a + (b - a) * f); this.pos += this.ratio;
    }
    this.pos -= ch.length;
    if (this.out.length >= 1600) {              // ~100ms @16kHz
      const pcm = new Int16Array(this.out.length);
      for (let k = 0; k < pcm.length; k++) { const s = Math.max(-1, Math.min(1, this.out[k])); pcm[k] = s < 0 ? s * 0x8000 : s * 0x7fff; }
      this.port.postMessage(pcm.buffer, [pcm.buffer]); this.out = [];
    }
    return true;
  }
}
registerProcessor('mic', Mic);`;

const toB64 = (buf) => { let s = ''; const b = new Uint8Array(buf); for (let i = 0; i < b.length; i++) s += String.fromCharCode(b[i]); return btoa(s); };
const fromB64 = (str) => { const s = atob(str); const b = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) b[i] = s.charCodeAt(i); return b.buffer; };

function playPcm(b64) {
  const pcm = new Int16Array(fromB64(b64));
  const buf = outCtx.createBuffer(1, pcm.length, 24000);   // เบราว์เซอร์ resample ให้เอง
  const ch = buf.getChannelData(0);
  for (let i = 0; i < pcm.length; i++) ch[i] = pcm[i] / 0x8000;
  const src = outCtx.createBufferSource(); src.buffer = buf; src.connect(outCtx.destination);
  playHead = Math.max(playHead, outCtx.currentTime + 0.03);
  src.start(playHead); playHead += buf.duration;
  playing.add(src); orb.classList.add('speaking');
  src.onended = () => { playing.delete(src); if (!playing.size) orb.classList.remove('speaking'); };
}
function stopPlayback() { for (const s of playing) try { s.stop(); } catch {} playing.clear(); playHead = 0; orb.classList.remove('speaking'); }

// ---------- tool: run_on_mac ----------
// แปลงสถานะงานจาก server → การ์ดบนจอ + ข้อความตอบ Gemini
function jobToResponse(job, card) {
  if (job.status === 'running') {
    card.textContent = `⏳ Mac กำลังทำ: ${job.task}`;
    pollJob(job.id, card);
    return { status: 'running', note: 'งานยังไม่เสร็จ ผลจะส่งตามมาภายหลัง' };
  }
  if (job.status === 'needs_confirmation') {
    showConfirm(job, card);
    return { status: 'needs_confirmation', job_id: job.id, task: job.task, note: 'งานนี้เสี่ยง ทวนงานให้ผู้ใช้ฟังแล้วถามว่ายืนยันไหม รอผู้ใช้ตอบก่อนเรียก confirm_task' };
  }
  card.replaceChildren(`${{ done: '✅', cancelled: '🚫' }[job.status] ?? '⚠️'} ${job.task}`);
  return { status: job.status, result: job.result };
}

async function runOnMac(fc) {
  const task = fc.args?.task || '';
  const card = bubble('sys', `🖥️ สั่ง Mac: ${task}`);
  let resp;
  try { resp = jobToResponse(await api('/api/mac', { task, convo: CONVO }), card); }
  catch (e) { card.textContent = `⚠️ ส่งงานไม่ได้: ${e.message}`; resp = { status: 'error', result: e.message }; }
  session?.sendToolResponse({ functionResponses: [{ id: fc.id, name: fc.name, response: resp }] });
}

function showConfirm(job, card) {
  card.className = 'sys confirm';
  card.replaceChildren(`⚠️ ต้องยืนยัน: ${job.task}`);
  const row = document.createElement('div'); row.className = 'btns';
  const yes = document.createElement('button'); yes.textContent = '✅ ยืนยัน';
  const no = document.createElement('button'); no.textContent = '❌ ยกเลิก';
  yes.onclick = () => decide(job.id, true, 'ปุ่ม');
  no.onclick = () => decide(job.id, false, 'ปุ่ม');
  row.append(yes, no); card.append(row);
  confirms.set(job.id, { task: job.task, card, heard: '' });
}

// ยืนยัน/ยกเลิกจริงที่ server — เรียกจากปุ่มบนจอหรือจาก confirm_task (หลังผ่านการเช็คเสียง)
async function decide(id, approve, via) {
  const c = confirms.get(id); if (!c) return null;
  confirms.delete(id);
  c.card.className = 'sys';
  c.card.replaceChildren(`${approve ? '▶️ ยืนยันแล้ว' : '🚫 ยกเลิก'} (${via}): ${c.task}`);
  const job = await api(`/api/mac/${id}/confirm`, { approve });
  if (via === 'ปุ่ม') {                        // Gemini ไม่รู้ว่ากดปุ่ม → แจ้งให้รู้
    if (job.status === 'running') pollJob(job.id, c.card);
    else { pendingResults.push(`[ผลจาก Mac] งาน "${job.task}" ${approve ? `ผู้ใช้กดยืนยันแล้ว ผล: ${job.result}` : 'ผู้ใช้กดยกเลิกแล้ว'}`); flushResults(); }
  }
  return job;
}

async function confirmTask(fc) {
  const { job_id: id, approve } = fc.args ?? {};
  const c = confirms.get(id);
  let resp;
  if (!c) resp = { status: 'error', result: 'ไม่พบงานที่รอยืนยัน (อาจยืนยัน/ยกเลิกไปแล้ว หรือหมดเวลา)' };
  else if (approve && !(AFFIRM.test(c.heard) && !NEGATE.test(c.heard))) {
    resp = { status: 'not_confirmed', result: 'ยังไม่ได้ยินผู้ใช้พูดยืนยันชัดเจน ให้ถามผู้ใช้อีกครั้ง' };
  } else {
    try {
      const job = await decide(id, !!approve, 'เสียง');
      resp = approve ? jobToResponse(job, c.card) : { status: 'cancelled', result: 'ยกเลิกงานแล้ว' };
    } catch (e) { resp = { status: 'error', result: e.message }; }
  }
  session?.sendToolResponse({ functionResponses: [{ id: fc.id, name: fc.name, response: resp }] });
}

let activeJobs = 0;                          // งานที่ยังรอผล (โหมดห้องจะไม่ปิด session ระหว่างนี้)
async function pollJob(id, card) {
  activeJobs++;
  try { await pollUntilDone(id, card); } finally { activeJobs--; }
}
async function pollUntilDone(id, card) {
  while (true) {
    await new Promise((r) => setTimeout(r, 3000));
    let job; try { job = await api(`/api/mac/${id}`); } catch { continue; }
    if (job.status === 'running') continue;
    card.replaceChildren(`${job.status === 'done' ? '✅' : '⚠️'} ${job.task}`);
    pendingResults.push(`[ผลจาก Mac] งาน "${job.task}" ${job.status === 'done' ? 'เสร็จแล้ว' : 'ผิดพลาด'}: ${job.result}`);
    flushResults();
    return;
  }
}

// ส่งผลงานนานให้ Friday ตอนที่ไม่ได้พูดทับผู้ใช้/ตัวเอง
function flushResults() {
  if (!session || !pendingResults.length || playing.size) return;
  session.sendRealtimeInput({ text: pendingResults.shift() });
}

// ---------- session ----------
function onMessage(msg) {
  for (const fc of msg.toolCall?.functionCalls ?? []) {
    if (fc.name === 'run_on_mac') runOnMac(fc);
    else if (fc.name === 'confirm_task') confirmTask(fc);
  }
  const sc = msg.serverContent;
  if (sc?.interrupted) stopPlayback();
  for (const p of sc?.modelTurn?.parts ?? []) if (p.inlineData?.data) playPcm(p.inlineData.data);
  if (sc?.inputTranscription?.text) {
    meBubble ??= bubble('me'); meBubble.textContent += sc.inputTranscription.text; friBubble = null;
    for (const c of confirms.values()) c.heard += sc.inputTranscription.text;   // เก็บเสียงผู้ใช้หลังถามยืนยัน
  }
  if (sc?.outputTranscription?.text) { friBubble ??= bubble('fri'); friBubble.textContent += sc.outputTranscription.text; meBubble = null; }
  if (sc?.turnComplete) { meBubble = null; friBubble = null; setTimeout(flushResults, 800); }
}


// ---------- audio pipeline (ไมค์ + ลำโพง) — แยกจาก Gemini session เพื่อให้โหมดห้องฟังคำปลุกได้ตลอด ----------
const ROOM = new URLSearchParams(location.search).has('room');
let micNode = null, lastActivity = 0;
const idleMs = 20000;                          // โหมดห้อง: เงียบเกินนี้ → ปิด session กลับไปรอคำปลุก

async function openAudio() {
  // เปิดไมค์ก่อน: iOS/WebKit ยอมให้เล่นเสียงโดยไม่ต้องแตะจอ ถ้าหน้าเว็บกำลังใช้ไมค์อยู่
  micStream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true, channelCount: 1 } });
  // ลำโพงเล่นที่ 24kHz ตรงกับเสียงจาก Gemini — ถ้าให้เบราว์เซอร์ resample ทีละก้อนเล็กๆ จะมีเสียงคลิกถี่ๆ (หึ่ง/ตู้ด) ตรงรอยต่อ
  try { outCtx = new AudioContext({ sampleRate: 24000 }); } catch { outCtx = new AudioContext(); }
  micCtx = new AudioContext();                 // ไมค์ใช้ rate ของเครื่อง แล้ว resample → 16k ใน worklet
  // ถ้ายัง resume ไม่ได้ (เบราว์เซอร์บล็อก) → ตัดที่ 1.5s แล้วให้ผู้ใช้แตะวงกลมแทน
  const resumed = await Promise.race([
    Promise.all([outCtx.resume(), micCtx.resume()]).then(() => true),
    new Promise((r) => setTimeout(() => r(false), 1500)),
  ]);
  if (!resumed) throw new Error(NEEDS_TAP);
  await micCtx.audioWorklet.addModule(URL.createObjectURL(new Blob([WORKLET], { type: 'text/javascript' })));
  micNode = new AudioWorkletNode(micCtx, 'mic');
  micNode.port.onmessage = (e) => onMicChunk(e.data);
  micCtx.createMediaStreamSource(micStream).connect(micNode);
}

function closeAudio() {
  micStream?.getTracks().forEach((t) => t.stop()); micStream = null; micNode = null;
  micCtx?.close(); micCtx = null; stopPlayback(); outCtx?.close(); outCtx = null;
}

// ไมค์ทุก ~100ms: มี session → ส่ง Gemini · กำลังต่อ → เก็บคิว · โหมดห้องไม่มี session → ตรวจคำปลุก
let connecting = false; const connectQueue = [];
function onMicChunk(buf) {
  if (session && !connecting) return sendAudio(buf);
  if (connecting) return connectQueue.push(buf);
  if (ROOM) wakeListen(buf);
}
const sendAudio = (buf) => session?.sendRealtimeInput({ audio: { data: toB64(buf), mimeType: 'audio/pcm;rate=16000' } });

// ---------- Gemini session ----------
async function openSession(prebuffer = []) {
  connecting = true; connectQueue.push(...prebuffer);
  setStatus('กำลังเชื่อมต่อ…');
  try {
    const { token } = await api('/api/token', {});
    const ai = new GoogleGenAI({ apiKey: token, httpOptions: { apiVersion: 'v1alpha' } });
    session = await ai.live.connect({
      model: MODEL,
      config: {
        responseModalities: [Modality.AUDIO],
        systemInstruction: SYSTEM,
        tools: TOOLS,
        inputAudioTranscription: {},
        outputAudioTranscription: {},
        contextWindowCompression: { slidingWindow: {} },
      },
      callbacks: {
        onopen: () => { setStatus('ฟังอยู่… พูดได้เลย'); orb.classList.add('live'); },
        onmessage: (m) => { lastActivity = Date.now(); onMessage(m); },
        onerror: (e) => { bubble('sys', 'error: ' + (e.message || e)); },
        onclose: (e) => { if (session) { bubble('sys', 'ปิดการเชื่อมต่อ' + (e.reason ? ': ' + e.reason : '')); endSession(); } },
      },
    });
  } finally { connecting = false; }
  lastActivity = Date.now();
  while (connectQueue.length) sendAudio(connectQueue.shift());   // เสียงที่พูดตอนปลุก/ระหว่างต่อ → ส่งให้ Gemini ฟังด้วย
}

function endSession() {
  const s = session; session = null; try { s?.close(); } catch {}
  stopPlayback(); orb.classList.remove('live'); meBubble = friBubble = null;
  setStatus(ROOM ? '💤 รอคำปลุก "Friday"' : 'แตะวงกลมเพื่อเริ่มคุย');
}

// โหมดห้อง: ไม่มีใครพูด/Friday ไม่ได้พูด/ไม่มีงานค้าง นานเกิน idleMs → กลับไปรอคำปลุก
setInterval(() => {
  if (!ROOM || !session || connecting) return;
  const busy = playing.size || confirms.size || pendingResults.length || activeJobs;
  if (busy) { lastActivity = Date.now(); return; }
  if (Date.now() - lastActivity > idleMs) { bubble('sys', '💤 พักก่อน — เรียก "Friday" เมื่อต้องการ'); endSession(); }
}, 2000);

// ---------- คำปลุก: VAD แบบง่าย (พลังงานเสียง) → ตัดช่วงพูด → whisper ในเครื่องเช็คคำว่า Friday ----------
let noiseFloor = 300, voiced = 0, silent = 0, seg = [], checking = false;
const preroll = [];
function rms(buf) { const a = new Int16Array(buf); let s = 0; for (let i = 0; i < a.length; i++) s += a[i] * a[i]; return Math.sqrt(s / a.length); }

let lastLevel = 0, peakLevel = 0, chunkCount = 0;
if (ROOM) setInterval(() => {
  const track = micStream?.getAudioTracks()[0];
  api('/api/ping', { session: !!session, track: track?.readyState ?? 'none', label: track?.label?.slice(0, 40), ctx: micCtx?.state, chunks: chunkCount, noise: Math.round(noiseFloor), peak: Math.round(peakLevel), checking }).catch(() => {});
  chunkCount = 0; peakLevel = 0;
}, 15000);

function wakeListen(buf) {
  const level = rms(buf); lastLevel = level; chunkCount++; if (level > peakLevel) peakLevel = level;
  const speech = level > Math.max(noiseFloor * 3, 400);
  if (!speech && !seg.length) {                      // เงียบ: ปรับระดับเสียงพื้นหลัง + เก็บ preroll 300ms
    noiseFloor = noiseFloor * 0.95 + level * 0.05;
    preroll.push(buf); if (preroll.length > 3) preroll.shift();
    return;
  }
  if (!seg.length) seg.push(...preroll.splice(0));
  seg.push(buf);
  if (speech) { voiced++; silent = 0; } else silent++;
  if (silent >= 6 || seg.length >= 40) {             // จบช่วงพูด (เงียบ 600ms) หรือยาวเกิน 4 วิ
    const clip = seg; const enough = voiced >= 3;
    seg = []; voiced = 0; silent = 0;
    if (enough && !checking) checkWake(clip);
  }
}

async function checkWake(chunks) {
  checking = true;
  try {
    const body = new Blob(chunks.map((c) => new Uint8Array(c)));
    const r = await fetch('/api/wake', { method: 'POST', headers: { 'X-Friday': '1', 'Content-Type': 'application/octet-stream' }, body });
    const { wake, text } = await r.json();
    if (wake && !session && !connecting) {
      chime(); bubble('sys', `👂 ได้ยิน: ${text}`);
      await openSession(chunks);                      // ส่งเสียงช่วงที่ปลุกให้ Gemini ฟังด้วย ("Friday เปิด Chrome")
    }
  } catch (e) { bubble('sys', '⚠️ ' + e.message); endSession(); }
  finally { checking = false; }
}

function chime() {
  if (!outCtx) return;
  const o = outCtx.createOscillator(), g = outCtx.createGain(), t = outCtx.currentTime;
  o.frequency.setValueAtTime(880, t); o.frequency.setValueAtTime(1320, t + 0.09);
  g.gain.setValueAtTime(0.0001, t); g.gain.exponentialRampToValueAtTime(0.15, t + 0.02); g.gain.exponentialRampToValueAtTime(0.0001, t + 0.25);
  o.connect(g).connect(outCtx.destination); o.start(t); o.stop(t + 0.26);
}

// ---------- ปุ่มวงกลม ----------
let starting = false;
orb.onclick = async () => {
  if (starting) return;
  if (session) { endSession(); if (!ROOM) closeAudio(); return; }
  starting = true;
  try {
    if (!micStream) await openAudio();
    await openSession();
  } catch (e) {
    endSession(); if (!ROOM) closeAudio();
    if (e.message === NEEDS_TAP) setStatus('👆 แตะวงกลมเพื่อเริ่ม');
    else bubble('sys', '⚠️ ' + e.message);
  } finally { starting = false; }
};

// โหมดห้อง (?room=1): เปิดไมค์ค้างไว้รอคำปลุก · Shortcut iPhone (?auto=1): ลองเริ่มคุยเลย
if (ROOM) {
  openAudio().then(async () => {
    setStatus('💤 รอคำปลุก "Friday"');
    const { wake } = await api('/api/room-hello', {});          // เปิดขึ้นมาเพราะหูเบื้องหลังได้ยิน "Friday"?
    if (wake && !session) {
      chime(); bubble('sys', '👂 เรียกแล้ว');
      await openSession();
      session?.sendRealtimeInput({ text: '[ผู้ใช้เพิ่งเรียกชื่อคุณ "Friday" — ทักทายสั้นๆ แล้วถามว่าให้ช่วยอะไร]' });
    }
  }).catch((e) => setStatus(e.message === NEEDS_TAP ? '👆 แตะวงกลมหนึ่งครั้งเพื่อเปิดโหมดห้อง' : '⚠️ ' + e.message));
  // ปิดหน้าต่าง → บอก server ให้หูเบื้องหลังฟังแทนทันที
  addEventListener('pagehide', () => navigator.sendBeacon('/api/bye'));
} else if (new URLSearchParams(location.search).has('auto')) orb.click();
