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
- คำถามทั่วไปที่ไม่เกี่ยวกับเครื่อง ตอบเองได้เลย ไม่ต้องใช้เครื่องมือ`;

const TOOLS = [{
  functionDeclarations: [{
    name: 'run_on_mac',
    description: 'สั่งงานบน Mac ของผู้ใช้ผ่าน Claude Code แล้วได้ผลลัพธ์กลับมา ใช้กับทุกงานที่เกี่ยวกับเครื่อง ไฟล์ แอป โค้ด หรือข้อมูลส่วนตัวในเครื่อง',
    parameters: {
      type: Type.OBJECT,
      properties: { task: { type: Type.STRING, description: 'คำสั่งงานภาษาไทยที่ชัดเจนและครบถ้วน' } },
      required: ['task'],
    },
  }],
}];

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
async function runOnMac(fc) {
  const task = fc.args?.task || '';
  const card = bubble('sys', `🖥️ สั่ง Mac: ${task}`);
  let resp;
  try {
    const job = await api('/api/mac', { task, convo: CONVO });
    if (job.status === 'running') {
      card.textContent = `⏳ Mac กำลังทำ: ${task}`;
      pollJob(job.id, card);
      resp = { status: 'running', note: 'งานยังไม่เสร็จ ผลจะส่งตามมาภายหลัง' };
    } else {
      card.textContent = `${job.status === 'done' ? '✅' : '⚠️'} ${task}`;
      resp = { status: job.status, result: job.result };
    }
  } catch (e) {
    card.textContent = `⚠️ ส่งงานไม่ได้: ${e.message}`;
    resp = { status: 'error', result: e.message };
  }
  session?.sendToolResponse({ functionResponses: [{ id: fc.id, name: fc.name, response: resp }] });
}

async function pollJob(id, card) {
  while (true) {
    await new Promise((r) => setTimeout(r, 3000));
    let job; try { job = await api(`/api/mac/${id}`); } catch { continue; }
    if (job.status === 'running') continue;
    card.textContent = `${job.status === 'done' ? '✅' : '⚠️'} ${job.task}`;
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
  if (msg.toolCall) for (const fc of msg.toolCall.functionCalls ?? []) if (fc.name === 'run_on_mac') runOnMac(fc);
  const sc = msg.serverContent;
  if (sc?.interrupted) stopPlayback();
  for (const p of sc?.modelTurn?.parts ?? []) if (p.inlineData?.data) playPcm(p.inlineData.data);
  if (sc?.inputTranscription?.text) { meBubble ??= bubble('me'); meBubble.textContent += sc.inputTranscription.text; friBubble = null; }
  if (sc?.outputTranscription?.text) { friBubble ??= bubble('fri'); friBubble.textContent += sc.outputTranscription.text; meBubble = null; }
  if (sc?.turnComplete) { meBubble = null; friBubble = null; setTimeout(flushResults, 800); }
}

async function start() {
  setStatus('กำลังเชื่อมต่อ…');
  outCtx = new AudioContext();
  micCtx = new AudioContext();
  // iOS: resume() ค้างตลอดถ้ายังไม่มีการแตะจอ → ตัดที่ 1.5s แล้วให้ผู้ใช้แตะวงกลมแทน
  const resumed = await Promise.race([
    Promise.all([outCtx.resume(), micCtx.resume()]).then(() => true),
    new Promise((r) => setTimeout(() => r(false), 1500)),
  ]);
  if (!resumed) throw new Error(NEEDS_TAP);
  micStream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true, channelCount: 1 } });
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
      onmessage: onMessage,
      onerror: (e) => { bubble('sys', 'error: ' + (e.message || e)); },
      onclose: (e) => { bubble('sys', 'ปิดการเชื่อมต่อ' + (e.reason ? ': ' + e.reason : '')); stop(); },
    },
  });

  await micCtx.audioWorklet.addModule(URL.createObjectURL(new Blob([WORKLET], { type: 'text/javascript' })));
  const node = new AudioWorkletNode(micCtx, 'mic');
  node.port.onmessage = (e) => session?.sendRealtimeInput({ audio: { data: toB64(e.data), mimeType: 'audio/pcm;rate=16000' } });
  micCtx.createMediaStreamSource(micStream).connect(node);
}

function stop() {
  const s = session; session = null; try { s?.close(); } catch {}
  micStream?.getTracks().forEach((t) => t.stop()); micStream = null;
  micCtx?.close(); micCtx = null; stopPlayback(); outCtx?.close(); outCtx = null;
  orb.classList.remove('live'); setStatus('แตะวงกลมเพื่อเริ่มคุย');
}

let starting = false;
orb.onclick = async () => {
  if (starting) return;
  if (session) return stop();
  starting = true;
  try { await start(); }
  catch (e) {
    stop();
    if (e.message === NEEDS_TAP) setStatus('👆 แตะวงกลมเพื่อเริ่มคุย');
    else bubble('sys', '⚠️ ' + e.message);
  }
  finally { starting = false; }
};

// เปิดจาก Shortcut "Friday" (?auto=1): ลองเริ่มเอง — iOS บล็อกเสียงถ้ายังไม่แตะจอ ก็จะกลับมารอให้แตะ
if (new URLSearchParams(location.search).has('auto')) orb.click();
