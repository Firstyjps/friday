// HomePod: (C) พูดออกลำโพง HomePod ผ่าน AirPlay · (B) "หวัดดี Siri เลขาส่วนตัว" → ตอบเป็นข้อความให้ Siri อ่าน
import { spawn } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir, homedir } from 'node:os';
import { join } from 'node:path';
import { writeFile } from 'node:fs/promises';
import { synth, ttsEnabled } from './tts.mjs';

const ATV = join(homedir(), 'Library/Python/3.13/bin/atvremote');   // pyatv (pip --user)

const run = (cmd, args, ms) => new Promise((resolve) => {
  const p = spawn(cmd, args); let err = '';
  const t = setTimeout(() => { p.kill(); resolve({ ok: false, err: `หมดเวลา ${ms / 1000} วิ` }); }, ms);
  p.stderr.on('data', (d) => { err += d; });
  p.on('close', (code) => { clearTimeout(t); resolve({ ok: code === 0, err: err.trim().slice(0, 300) }); });
  p.on('error', (e) => { clearTimeout(t); resolve({ ok: false, err: e.message }); });
});

function wavHeader(n, rate = 24000) {
  const h = Buffer.alloc(44);
  h.write('RIFF', 0); h.writeUInt32LE(36 + n, 4); h.write('WAVE', 8); h.write('fmt ', 12);
  h.writeUInt32LE(16, 16); h.writeUInt16LE(1, 20); h.writeUInt16LE(1, 22); h.writeUInt32LE(rate, 24); h.writeUInt32LE(rate * 2, 28);
  h.writeUInt16LE(2, 32); h.writeUInt16LE(16, 34); h.write('data', 36); h.writeUInt32LE(n, 40);
  return h;
}

// ---------- (C) พูดออก HomePod ----------
// คิวทีละประโยค (AirPlay ส่งได้ทีละสตรีม) · say -v Kanya → wav → atvremote stream_file (RAOP, HomePod ไม่ต้อง pair)
let queue = Promise.resolve();
export function speak(text, { id, voice = 'Kanya' } = {}, log = () => {}, cfg = null) {
  const t = String(text || '').replace(/\s+/g, ' ').trim().slice(0, 600);
  if (!t || !id) return Promise.resolve({ ok: false, result: !id ? 'ยังไม่ได้ตั้ง homepod.id ใน config.json' : 'ไม่มีข้อความ' });
  const job = queue.then(async () => {
    const dir = await mkdtemp(join(tmpdir(), 'friday-hp-'));
    try {
      const wav = join(dir, 'say.wav');
      // เสียง ElevenLabs (เหมือนแอป Mac) ถ้าเปิดไว้ · พังเมื่อไหร่ถอยไปใช้ say
      let made = false;
      if (ttsEnabled(cfg)) {
        try { const pcm = await synth(t, cfg.tts, { log }); if (pcm) { await writeFile(wav, Buffer.concat([wavHeader(pcm.length), pcm])); made = true; } }
        catch (e) { log(`HOMEPOD tts ใช้ไม่ได้ → say | ${e.message}`); }
      }
      if (!made) {
        const s = await run('/usr/bin/say', ['-v', voice, '-o', wav, '--data-format=LEI16@24000', t], 30000);
        if (!s.ok) return { ok: false, result: `สร้างเสียงไม่ได้: ${s.err}` };
      }
      const r = await run(ATV, ['--id', id, '--protocol', 'raop', `stream_file=${wav}`], 90000);
      log(`HOMEPOD speak ${r.ok ? 'ok' : `ผิดพลาด ${r.err}`} | ${t.slice(0, 120)}`);
      return r.ok ? { ok: true, result: 'พูดออก HomePod แล้ว' } : { ok: false, result: `ส่งเสียงไป HomePod ไม่ได้: ${r.err}` };
    } finally { rm(dir, { recursive: true, force: true }); }
  });
  queue = job.catch(() => {});
  return job;
}

// ---------- (B) ถาม-ตอบแบบข้อความ (Gemini text + tools ชุดเดียวกับ Friday) ----------
const HOMEPOD_RULES = `
[โหมด HomePod] ตอนนี้ผู้ใช้คุยผ่าน Siri บน HomePod: ข้อความที่ได้คือเสียงที่ Siri ถอดมาแล้ว และคำตอบของคุณจะถูก Siri อ่านออกเสียง
- ตอบสั้นมาก 1-2 ประโยค ห้ามมีสัญลักษณ์ ลิสต์ หรือ markdown
- ไม่มีการคุยต่อเนื่องแบบสด ผู้ใช้ต้องพูด "หวัดดี Siri เลขาส่วนตัว" ใหม่ทุกครั้ง
- ถ้า run_on_mac ตอบ needs_confirmation ให้ทวนงานสั้นๆ แล้วบอกว่า "ถ้าจะให้ทำ พูดว่า เลขาส่วนตัว ยืนยัน"
- ถ้า run_on_mac ตอบ running ให้บอกว่ากำลังทำ เสร็จแล้วจะบอกผลทางลำโพง`;
const HOMEPOD_TOOLS = ['run_on_mac', 'remember', 'vault_lookup', 'get_usage', 'run_shortcut', 'open_app', 'open_url', 'system_info', 'announce_homepod'];

export async function askText(text, { key, model, cfg, context, callTool, log = () => {} }) {
  const ctx = await context();
  const system = `${cfg.system}\n${HOMEPOD_RULES}\n\nความจำ:\n${ctx.memory || '-'}\n\nShortcuts ที่สั่งได้: ${ctx.shortcuts}`;
  const decls = (cfg.tools ?? []).flatMap((t) => t.functionDeclarations ?? []).filter((d) => HOMEPOD_TOOLS.includes(d.name));
  const contents = [{ role: 'user', parts: [{ text }] }];
  for (let turn = 0; turn < 5; turn++) {
    const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, {
      method: 'POST', signal: AbortSignal.timeout(20000),
      headers: { 'x-goog-api-key': key, 'Content-Type': 'application/json' },
      body: JSON.stringify({ systemInstruction: { parts: [{ text: system }] }, contents, tools: [{ functionDeclarations: decls }],
        generationConfig: { thinkingConfig: { thinkingBudget: 0 } } }),   // HomePod ต้องตอบเร็ว
    });
    const j = await r.json();
    if (!r.ok) throw new Error(`Gemini ${r.status}: ${JSON.stringify(j).slice(0, 200)}`);
    const parts = j.candidates?.[0]?.content?.parts ?? [];
    const calls = parts.filter((p) => p.functionCall);
    if (!calls.length) return parts.map((p) => p.text ?? '').join('').trim() || 'ขอโทษค่ะ ไม่ได้คำตอบ';
    contents.push({ role: 'model', parts });
    const responses = [];
    for (const { functionCall: fc } of calls) {
      log(`HOMEPOD tool ${fc.name} ${JSON.stringify(fc.args ?? {}).slice(0, 150)}`);
      responses.push({ functionResponse: { name: fc.name, response: await callTool(fc.name, fc.args ?? {}) } });
    }
    contents.push({ role: 'user', parts: responses });
  }
  return 'ขอโทษค่ะ งานนี้ซับซ้อนเกินไปสำหรับ HomePod ลองสั่งผ่าน Friday บน Mac นะคะ';
}
