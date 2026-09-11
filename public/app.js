// Friday client — ไมค์ (PCM16 16kHz) → Gemini Live → เสียงตอบ (PCM16 24kHz)
import { GoogleGenAI, Modality } from 'https://cdn.jsdelivr.net/npm/@google/genai@2.22.0/+esm';

const MODEL = 'gemini-3.1-flash-live-preview';
const SYSTEM = `คุณคือ Friday ผู้ช่วยส่วนตัวของผู้ใช้ พูดภาษาไทยเป็นหลัก เป็นกันเอง กระชับ
ตอบเหมือนคุยกันด้วยเสียง: ประโยคสั้น ไม่อ่านสัญลักษณ์หรือ markdown ไม่ร่ายยาว`;

const $ = (id) => document.getElementById(id);
const orb = $('orb'), statusEl = $('status'), logEl = $('log');

let session = null, micCtx = null, micStream = null, outCtx = null;
let playHead = 0; const playing = new Set();
let meBubble = null, friBubble = null;

const setStatus = (t) => { statusEl.textContent = t; };
function bubble(cls, text = '') {
  const el = document.createElement('div'); el.className = cls; el.textContent = text;
  logEl.append(el); logEl.scrollTop = logEl.scrollHeight; return el;
}

// ---------- audio helpers ----------
const WORKLET = `
class Mic extends AudioWorkletProcessor {
  constructor() { super(); this.buf = []; this.n = 0; }
  process([input]) {
    const ch = input[0]; if (!ch) return true;
    this.buf.push(new Float32Array(ch)); this.n += ch.length;
    if (this.n >= 1600) {                       // ~100ms @16kHz
      const out = new Int16Array(this.n); let o = 0;
      for (const b of this.buf) for (let i = 0; i < b.length; i++) {
        const s = Math.max(-1, Math.min(1, b[i])); out[o++] = s < 0 ? s * 0x8000 : s * 0x7fff;
      }
      this.port.postMessage(out.buffer, [out.buffer]); this.buf = []; this.n = 0;
    }
    return true;
  }
}
registerProcessor('mic', Mic);`;

const toB64 = (buf) => { let s = ''; const b = new Uint8Array(buf); for (let i = 0; i < b.length; i++) s += String.fromCharCode(b[i]); return btoa(s); };
const fromB64 = (str) => { const s = atob(str); const b = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) b[i] = s.charCodeAt(i); return b.buffer; };

function playPcm(b64) {
  const pcm = new Int16Array(fromB64(b64));
  const buf = outCtx.createBuffer(1, pcm.length, 24000);
  const ch = buf.getChannelData(0);
  for (let i = 0; i < pcm.length; i++) ch[i] = pcm[i] / 0x8000;
  const src = outCtx.createBufferSource(); src.buffer = buf; src.connect(outCtx.destination);
  playHead = Math.max(playHead, outCtx.currentTime + 0.03);
  src.start(playHead); playHead += buf.duration;
  playing.add(src); orb.classList.add('speaking');
  src.onended = () => { playing.delete(src); if (!playing.size) orb.classList.remove('speaking'); };
}
function stopPlayback() { for (const s of playing) try { s.stop(); } catch {} playing.clear(); playHead = 0; orb.classList.remove('speaking'); }

// ---------- session ----------
function onMessage(msg) {
  const sc = msg.serverContent;
  if (sc?.interrupted) stopPlayback();
  for (const p of sc?.modelTurn?.parts ?? []) if (p.inlineData?.data) playPcm(p.inlineData.data);
  if (sc?.inputTranscription?.text) { meBubble ??= bubble('me'); meBubble.textContent += sc.inputTranscription.text; friBubble = null; }
  if (sc?.outputTranscription?.text) { friBubble ??= bubble('fri'); friBubble.textContent += sc.outputTranscription.text; meBubble = null; }
  if (sc?.turnComplete) { meBubble = null; friBubble = null; }
}

async function start() {
  setStatus('กำลังเชื่อมต่อ…');
  const r = await fetch('/api/token', { method: 'POST' });
  const { token, error } = await r.json();
  if (!r.ok) throw new Error(error);

  outCtx = new AudioContext({ sampleRate: 24000 });
  micCtx = new AudioContext({ sampleRate: 16000 });
  micStream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true, channelCount: 1 } });

  const ai = new GoogleGenAI({ apiKey: token, httpOptions: { apiVersion: 'v1alpha' } });
  session = await ai.live.connect({
    model: MODEL,
    config: {
      responseModalities: [Modality.AUDIO],
      systemInstruction: SYSTEM,
      inputAudioTranscription: {},
      outputAudioTranscription: {},
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

orb.onclick = async () => {
  if (session) return stop();
  try { await start(); } catch (e) { bubble('sys', '⚠️ ' + e.message); stop(); }
};
