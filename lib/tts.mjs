// เสียง Friday ผ่าน ElevenLabs (คีย์อยู่ใน .env ฝั่ง server เท่านั้น) · config.json → "tts": { provider, voiceId, model }
// ภาษาไทยใช้ได้แค่ eleven_v3 (flash_v2_5 ไม่รองรับ th) · แผน Starter ขึ้นไปถึงใช้เสียงจาก Voice Library ได้
const KEY = () => process.env.ELEVENLABS_API_KEY;

// ชื่อ tool ที่ Gemini บางทีพูด/พิมพ์ออกมาในข้อความ → ไม่ต้องอ่าน
const clean = (t) => String(t || '').replace(/\b[a-z]+_[a-z_]+\b/g, '').replace(/[*#`_]/g, '').replace(/\s+/g, ' ').trim().slice(0, 1200);

/** คืน PCM16 mono ตาม format (pcm_24000 สำหรับแอป Mac) */
export async function synth(text, tts, { format = 'pcm_24000', log = () => {} } = {}) {
  const t = clean(text);
  if (!t) return null;
  if (!KEY()) throw new Error('ELEVENLABS_API_KEY ไม่ได้ตั้งใน .env');
  const t0 = Date.now();
  const r = await fetch(`https://api.elevenlabs.io/v1/text-to-speech/${tts.voiceId}?output_format=${format}`, {
    method: 'POST', signal: AbortSignal.timeout(20000),
    headers: { 'xi-api-key': KEY(), 'Content-Type': 'application/json' },
    body: JSON.stringify({ text: t, model_id: tts.model || 'eleven_v3', ...(tts.voiceSettings ? { voice_settings: tts.voiceSettings } : {}) }),
  });
  if (!r.ok) throw new Error(`ElevenLabs ${r.status}: ${(await r.text()).slice(0, 200)}`);
  const buf = Buffer.from(await r.arrayBuffer());
  log(`TTS ${t.length} ตัวอักษร → ${(buf.length / 48000).toFixed(1)}s เสียง ใน ${Date.now() - t0}ms`);
  return buf;
}

export const ttsEnabled = (cfg) => cfg?.tts?.provider === 'elevenlabs' && !!cfg.tts.voiceId && !!KEY();
