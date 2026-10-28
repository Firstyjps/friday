import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash, createHmac } from 'node:crypto';
import { Tuya } from '../lib/tuya.mjs';

// fake Tuya cloud: ตรวจลายเซ็นทุก request ตามสูตรของ Tuya แล้วตอบตาม path
const fakeCloud = (calls) => async (url, init) => {
  const u = new URL(url), path = u.pathname + u.search, h = init.headers, body = init.body ?? '';
  const str = `${init.method}\n${createHash('sha256').update(body).digest('hex')}\n\n${path}`;
  const want = createHmac('sha256', 'sec').update('cid' + (h.access_token ?? '') + h.t + h.nonce + str).digest('hex').toUpperCase();
  assert.equal(h.sign, want, `ลายเซ็นผิด ${path}`);
  calls.push(`${init.method} ${path}`);
  const result = path.startsWith('/v1.0/token') ? { access_token: 'tok', expire_time: 7200 }
    : path.endsWith('/homes') ? [{ home_id: 7 }]
    : path.endsWith('/scenes') ? [{ name: 'เปิดแอร์ ', scene_id: 'sA' }, { name: 'ปิดแอร์', scene_id: 'sB' }]
    : true;
  if (path.startsWith('/v1.0/token')) assert.equal(h.access_token, undefined);
  else assert.equal(h.access_token, 'tok');
  return { json: async () => ({ success: true, result }) };
};

test('Tuya: ขอ token ครั้งเดียว · หาฉากตามชื่อ · สั่ง trigger ถูก path', async () => {
  const calls = [];
  const t = new Tuya({ id: 'cid', secret: 'sec', uid: 'u1', endpoint: 'https://x.test', fetch: fakeCloud(calls) });
  assert.equal((await t.trigger('เปิดแอร์')).scene_id, 'sA');
  assert.equal(await t.trigger('เปิดไฟ'), null);                 // ไม่มีฉากนี้ → null ให้ไปใช้ shortcuts แทน
  assert.deepEqual(calls, ['GET /v1.0/token?grant_type=1', 'GET /v1.0/users/u1/homes', 'GET /v1.1/homes/7/scenes', 'POST /v1.0/homes/7/scenes/sA/trigger']);
});

test('Tuya: error จาก cloud → throw · ไม่มี env → null', async () => {
  const t = new Tuya({ id: 'cid', secret: 'sec', uid: 'u1', fetch: async () => ({ json: async () => ({ success: false, code: 1010, msg: 'token invalid' }) }) });
  await assert.rejects(t.trigger('เปิดแอร์'), /1010 token invalid/);
  assert.equal(Tuya.fromEnv({}), null);
});
