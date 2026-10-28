// Tuya Cloud (OpenAPI) — สั่งฉาก Tap-to-Run ของ Smart Life ตรงจาก server ไม่ต้องพึ่งแอปบน Mac
// Shortcut เปิดแอร์/ไฟ เป็น SiriKit ของแอป Smart Life (com.tuya.smartlife) ซึ่ง `shortcuts run` บน Mac รันไม่ได้ถ้าไม่ได้ลงแอป (28 ต.ค.)
// .env: TUYA_CLIENT_ID, TUYA_SECRET, TUYA_UID (UID ของบัญชี Smart Life ที่ผูกกับ cloud project), TUYA_ENDPOINT (default สิงคโปร์; บัญชีไทยอยู่ Western America = https://openapi.tuyaus.com)
import { createHash, createHmac, randomUUID } from 'node:crypto';

const sha256 = (s) => createHash('sha256').update(s).digest('hex');
const hmac = (key, s) => createHmac('sha256', key).update(s).digest('hex').toUpperCase();

export class Tuya {
  /** opts: { id, secret, uid, endpoint, fetch, now } — fetch/now ไว้เทสต์ */
  constructor({ id, secret, uid, endpoint = 'https://openapi-sg.iotbing.com', fetch: f = fetch, now = Date.now } = {}) {
    Object.assign(this, { id, secret, uid, endpoint: endpoint.replace(/\/$/, ''), f, now });
    this.token = null; this.tokenUntil = 0; this.scenes = null; this.scenesAt = 0;
  }
  static fromEnv(env = process.env, extra = {}) {
    return env.TUYA_CLIENT_ID && env.TUYA_SECRET && env.TUYA_UID
      ? new Tuya({ id: env.TUYA_CLIENT_ID, secret: env.TUYA_SECRET, uid: env.TUYA_UID, endpoint: env.TUYA_ENDPOINT || undefined, ...extra }) : null;
  }

  // ลายเซ็นแบบใหม่ของ Tuya: HMAC-SHA256(client_id [+ access_token] + t + nonce + METHOD\nsha256(body)\n\npath)
  sign(method, path, body, token) {
    const t = String(this.now()), nonce = randomUUID();
    const str = `${method}\n${sha256(body)}\n\n${path}`;
    return { client_id: this.id, t, nonce, sign_method: 'HMAC-SHA256', sign: hmac(this.secret, this.id + (token ?? '') + t + nonce + str), ...(token ? { access_token: token } : {}) };
  }
  async raw(method, path, body, token) {
    const b = body ? JSON.stringify(body) : '';
    const r = await this.f(this.endpoint + path, { method, body: b || undefined, signal: AbortSignal.timeout(10000),
      headers: { ...this.sign(method, path, b, token), 'Content-Type': 'application/json' } });
    const j = await r.json();
    if (!j.success) throw new Error(`tuya ${path.split('?')[0]}: ${j.code} ${j.msg}`);
    return j.result;
  }
  async auth() {
    if (this.token && this.now() < this.tokenUntil) return this.token;
    const r = await this.raw('GET', '/v1.0/token?grant_type=1');
    this.token = r.access_token; this.tokenUntil = this.now() + (r.expire_time - 60) * 1000;
    return this.token;
  }
  async call(method, path, body) { return this.raw(method, path, body, await this.auth()); }

  // ฉากทุกบ้านของบัญชี (cache 10 นาที) → [{ name, scene_id, home_id }]
  async listScenes() {
    if (this.scenes && this.now() - this.scenesAt < 600_000) return this.scenes;
    const homes = await this.call('GET', `/v1.0/users/${this.uid}/homes`);
    const out = [];
    // ใช้ v1.0 — v1.1 ตอบ 1106 permission deny กับบ้านที่เราเป็นแค่สมาชิก (28 ต.ค.) · บ้านไหนพังก็ข้าม ไม่ให้ล่มทั้งชุด
    for (const h of homes) {
      let list; try { list = await this.call('GET', `/v1.0/homes/${h.home_id}/scenes`); } catch { continue; }
      for (const s of list) out.push({ name: String(s.name).trim(), scene_id: s.scene_id, home_id: h.home_id });
    }
    this.scenesAt = this.now(); return (this.scenes = out);
  }
  async findScene(name) { return (await this.listScenes()).find((s) => s.name === String(name).trim()) ?? null; }
  async trigger(name) {
    const s = await this.findScene(name);
    if (!s) return null;                                 // ไม่มีฉากชื่อนี้ใน Smart Life
    await this.call('POST', `/v1.0/homes/${s.home_id}/scenes/${s.scene_id}/trigger`);
    return s;
  }
}
