import { test, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { Cascade, PROMISED } from '../lib/cascade.mjs';

// ทดสอบทางสำรองของ TTS โดยไม่เรียก API จริง: แทน fetch/WebSocket ด้วยตัวปลอม
const realFetch = globalThis.fetch, realWS = globalThis.WebSocket;
afterEach(() => { globalThis.fetch = realFetch; globalThis.WebSocket = realWS; });

const MODELS = ['m-a', 'm-b'];
const cfg = (extra = {}) => ({ cascade: { ttsModels: MODELS, ...extra } });
const make = () => { const logs = []; return { c: new Cascade({ key: 'test', log: (l) => logs.push(l) }), logs }; };
const audioSSE = () => new Response(`data: ${JSON.stringify({ candidates: [{ content: { parts: [{ inlineData: { data: Buffer.from('pcm').toString('base64') } }] } }] })}\n\n`);
const modelOf = (url) => String(url).match(/models\/([^:]+):/)[1];
const hang = (signal) => new Promise((_, rej) => signal.addEventListener('abort', () => rej(signal.reason)));

test('tts: รุ่นแรก fetch พัง (เน็ต/timeout) → ไปรุ่นถัดไป ไม่ทิ้งประโยค', async () => {
  globalThis.fetch = async (url) => { if (modelOf(url) === 'm-a') throw new Error('fetch failed'); return audioSSE(); };
  const { c } = make(), got = [];
  assert.equal(await c.tts('สวัสดี', cfg(), (b) => got.push(b)), 'm-b');
  assert.equal(got.length, 1);
});

test('tts: ไม่ได้ byte แรกตามเวลา → ยกเลิกแล้วไปรุ่นถัดไป', async () => {
  globalThis.fetch = async (url, o) => (modelOf(url) === 'm-a' ? hang(o.signal) : audioSSE());
  const { c } = make();
  assert.equal(await c.tts('สวัสดี', cfg({ ttsFirstByteMs: 50 }), () => {}), 'm-b');
});

test('tts: 429 โควตารายวันพักไม่เกิน 1 ชม. แม้ Google บอกให้รอ 20 ชม.', async () => {
  globalThis.fetch = async (url) => (modelOf(url) === 'm-a'
    ? new Response('Quota exceeded for metric generate_requests_per_model_per_day. Please retry in 20h0m0s.', { status: 429 })
    : audioSSE());
  const { c } = make();
  const t0 = Date.now();
  assert.equal(await c.tts('สวัสดี', cfg(), () => {}), 'm-b');
  const until = c.ttsBlocked.get('m-a');
  assert.ok(until > t0 && until <= Date.now() + 60 * 60e3, `พักนานเกิน: ${(until - t0) / 60000} นาที`);
});

test('tts: ทุกรุ่นพัง → Live ไม่ได้เสียงเลย ต้อง reject (ไม่ใช่เงียบแล้วนับว่าสำเร็จ)', async () => {
  globalThis.fetch = async () => { throw new Error('down'); };
  globalThis.WebSocket = class {
    constructor() { setTimeout(() => this.onopen?.(), 0); }
    send(m) {
      const o = JSON.parse(m);
      setTimeout(() => this.onmessage?.({ data: JSON.stringify(o.setup ? { setupComplete: {} } : { serverContent: { turnComplete: true } }) }), 0);
    }
    close() {}
  };
  const { c } = make();
  await assert.rejects(c.tts('สวัสดี', cfg(), () => {}), /ไม่ได้เสียง/);
});

test('filler: ทำเสียงไม่ได้ → ไม่จำผลว่างไว้ (ครั้งหน้าลองใหม่)', async () => {
  let calls = 0;
  globalThis.fetch = async () => { calls++; throw new Error('down'); };
  globalThis.WebSocket = undefined;
  const { c } = make(), config = cfg({ liveFallback: false });
  await assert.rejects(c.filler(config, 'ได้ค่ะ'));
  await assert.rejects(c.filler(config, 'ได้ค่ะ'));
  assert.equal(calls, 4);            // 2 รุ่น × 2 ครั้ง — ครั้งที่สองไม่ได้ใช้ผลค้าง
});

// ---------- คลิปแรกหลังคำปลุก (input.wake) ----------
const geminiOrTts = async (url) => (/flash-lite:stream/.test(String(url))
  ? new Response(`data: ${JSON.stringify({ candidates: [{ content: { parts: [{ text: 'ได้ค่ะ' }] } }], usageMetadata: {} })}\n\n`)
  : audioSSE());
const wakeTurn = async (heard, wake = 'word') => {
  globalThis.fetch = geminiOrTts;
  const c = new Cascade({ key: 'test', log: () => {}, wav16k: (p) => p, scribe: async () => { if (heard instanceof Error) throw heard; return heard; } });
  c.open('s1', { system: '', cfg: { cascade: { filler: false, googleSearch: false, ttsModels: ['m-a'] }, tools: [] } });
  const ev = [];
  await c.turn('s1', { audio: Buffer.alloc(32000), wake }, (o) => ev.push(o));
  return ev;
};

test('ตื่นผิด: Scribe ไม่ได้ยินคำปลุก → ส่งแค่ done{falseWake} ไม่มีข้อความผู้ใช้/คำตอบหลุดไปแอป', async () => {
  // ได้ประโยคอื่นที่ไม่มีคำปลุก (เดิมบับเบิลนี้หลุดไปค้างในแอป)
  assert.deepEqual(await wakeTurn('อืม โอเคนะ'), [{ t: 'done', pending: 0, falseWake: true }]);
  // คลิปถัดจากที่ได้ยินแค่คำปลุก แล้วยังไม่มีคำพูด = ตื่นผิด
  assert.deepEqual(await wakeTurn('', 'speech'), [{ t: 'done', pending: 0, falseWake: true }]);
});

test('ได้ยินแค่คำปลุก (Scribe ถอด "Friday" คำเดียวได้ว่าง) → ไม่ตอบ แต่ไม่ปิด รอคำสั่งต่อ', async () => {
  assert.deepEqual(await wakeTurn(''), [{ t: 'done', pending: 0, wakeRetry: true }]);
  const ev = await wakeTurn('เปิด Chrome ให้หน่อย', 'speech');     // คำสั่งที่พูดตามมา (ไม่มีคำปลุก) ต้องตอบ
  assert.equal(ev[0].t, 'user'); assert.ok(ev.some((o) => o.t === 'text'));
});

test('ปลุกจริง: ข้อความผู้ใช้ออกก่อนคำตอบ แล้วตามด้วยเสียงและ done', async () => {
  const ev = await wakeTurn('ฟรายเดย์ วันนี้วันอะไร');
  assert.equal(ev[0].t, 'user');
  assert.ok(ev.some((o) => o.t === 'text') && ev.some((o) => o.t === 'audio'));
  assert.deepEqual(ev.at(-1), { t: 'done', pending: 0 });
});

test('Scribe ล่ม/ไม่มี key บนคลิปปลุก → ปล่อยคำตอบ (ไม่นับเป็นตื่นผิด)', async () => {
  for (const heard of [new Error('scribe 503'), null]) {
    const ev = await wakeTurn(heard);
    assert.ok(ev.some((o) => o.t === 'text') && ev.some((o) => o.t === 'audio'), String(heard));
    assert.deepEqual(ev.at(-1), { t: 'done', pending: 0 });
  }
});

test('Gemini: ได้แค่ส่วนค้น Google แล้วค้าง → ลองใหม่ (ไม่ใช่รอ 30 วิแล้วขอโทษ) และไม่เก็บส่วนค้นซ้ำ', async () => {
  let n = 0;
  globalThis.fetch = async (url, o) => {
    if (!/flash-lite:stream/.test(String(url))) return audioSSE();
    if (n++ === 0) {                 // ครั้งแรก: ส่งส่วนค้น 1 ก้อนแล้วเงียบ
      const body = new ReadableStream({ start(ctl) {
        ctl.enqueue(new TextEncoder().encode(`data: ${JSON.stringify({ candidates: [{ content: { parts: [{ toolCall: { search: 1 } }] } }] })}\n\n`));
        o.signal.addEventListener('abort', () => ctl.error(o.signal.reason));
      } });
      return new Response(body);
    }
    return new Response(`data: ${JSON.stringify({ candidates: [{ content: { parts: [{ toolCall: { search: 2 } }, { text: 'ราคาทองวันนี้...' }] } }], usageMetadata: {} })}\n\n`);
  };
  const c = new Cascade({ key: 'test', log: () => {}, wav16k: (p) => p, scribe: async () => 'x' });
  c.open('s2', { system: '', cfg: { cascade: { filler: false, firstByteMs: 80, ttsModels: ['m-a'] }, tools: [] } });
  const ev = [], t0 = Date.now();
  await c.turn('s2', { text: 'ราคาทองวันนี้' }, (o) => ev.push(o));
  assert.equal(n, 2);
  assert.ok(Date.now() - t0 < 3000, 'ต้องลองใหม่เร็ว ไม่รอเพดาน');
  assert.ok(ev.some((o) => o.t === 'text'));
  const model = c.sessions.get('s2').contents.at(-1);
  assert.equal(model.parts.filter((p) => p.toolCall).length, 1, 'ส่วนค้นของรอบที่ค้างต้องไม่ค้างในประวัติ');
});

test('PROMISED: จับคำสัญญาว่าจะไปทำ ไม่จับ "ทำให้" แบบเป็นเหตุ/ขอโทษ', () => {
  for (const t of ['เดี๋ยวดูให้นะคะ', 'ขอเช็คให้ก่อนนะคะ', 'รอสักครู่นะคะ', 'เดี๋ยวจัดการให้ค่ะ', 'เดี๋ยวลองดูนะคะ', 'กำลังค้นหาให้ค่ะ', 'ได้ค่ะ เดี๋ยวทำให้นะคะ']) assert.ok(PROMISED.test(t), t);
  for (const t of ['ขอโทษที่ทำให้รอนะคะ', 'แบบนี้จะทำให้ดีขึ้นค่ะ', 'ฝนจะทำให้อากาศเย็นลง', 'วันนี้อากาศดีค่ะ']) assert.ok(!PROMISED.test(t), t);
});

test('louder: เสียงเบาดังขึ้น ~6 dB · เสียงดังไม่เกินเพดาน (ไม่แตก)', async () => {
  const { louder } = await import('../lib/cascade.mjs');
  const pcm = (amp) => { const b = Buffer.alloc(4800); for (let i = 0; i < 2400; i++) b.writeInt16LE(Math.round(amp * Math.sin(i / 5)), i * 2); return b; };
  const peak = (b) => { let m = 0; for (let i = 0; i < b.length; i += 2) m = Math.max(m, Math.abs(b.readInt16LE(i))); return m; };
  const st = () => ({ gain: 10 ** (6 / 20), env: 0 });
  assert.ok(Math.abs(peak(louder(pcm(5000), st())) / 5000 - 2) < 0.05);          // +6 dB ≈ ×2
  assert.ok(peak(louder(pcm(30000), st())) <= Math.ceil(0.89 * 32767));          // ยอดสูงถูกจำกัด ไม่ clip
  assert.equal(louder(pcm(5000), { gain: 1, env: 0 }).equals(pcm(5000)), true);  // gainDb 0 = ไม่แตะ
});
