import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { isWakeEcho, matchWake, replyIntent } from '../lib/rules.mjs';

const cfg = JSON.parse(readFileSync(new URL('../public/config.json', import.meta.url), 'utf8'));

test('wake echo: คำปลุกซ้ำล้วน = whisper หลอน ไม่ปลุก (9 ต.ค.)', () => {
  for (const t of ['ฟรายเดย์ ฟรายเดย์ ฟรายเดย์', 'Friday, Friday, Friday.', 'ฟรายเดย์ Friday ฟรายเดย์', ' ฟรายเดย์  ฟรายเดย์ ฟรายเดย์… ']) {
    assert.equal(isWakeEcho(t), true, `ควรเป็นเสียงหลอน: ${t}`);
  }
});

test('wake echo: เรียกจริงต้องยังปลุกได้', () => {
  for (const t of ['ฟรายเดย์', 'Friday', 'Friday เปิด Chrome', 'ฟรายเดย์ ช่วยเช็คราคาทองหน่อย', 'เฮ้ย ไฟร์เดย์', 'ฟรายเดย์ ฟรายเดย์', 'Friday, Friday']) {
    assert.equal(isWakeEcho(t), false, `ไม่ใช่เสียงหลอน: ${t}`);
    assert.equal(matchWake(t).wake, true, `ควรปลุก: ${t}`);
  }
});

test('คำตอบยืนยัน: ปฏิเสธชนะเสมอ', () => {
  for (const t of ['ห้ามทำเลย', 'ไม่ยืนยัน', 'ไม่เอาเลย', 'ยกเลิก', 'อย่าทำ', 'เลิกทำ', "don't do it", 'no', 'ไม่ต้องทำ']) {
    assert.equal(replyIntent(t, cfg), 'no', `ควรเป็นปฏิเสธ: ${t}`);
  }
});

test('คำตอบยืนยัน: ยืนยันสั้นๆ ผ่าน', () => {
  for (const t of ['ใช่', 'ยืนยัน', 'ทำเลย', 'โอเค', 'ได้เลย', 'yes', 'ยืนยันตลอด']) {
    assert.equal(replyIntent(t, cfg), 'yes', `ควรเป็นยืนยัน: ${t}`);
  }
});

test('คำตอบยืนยัน: คำถาม/ประโยคยาว/อย่างไร ไม่ใช่คำตอบ', () => {
  for (const t of ['ใช่ไหม', 'โอเคไหม', 'ทำเลยได้ไหม', 'ยืนยันหรือเปล่า', 'ok?', 'อากาศเป็นอย่างไร',
    'วันนี้อากาศดีไหมแล้วก็ช่วยเช็คราคาทองคำวันนี้ให้หน่อยได้ไหมโอเคไหม']) {
    assert.equal(replyIntent(t, cfg), null, `ไม่ควรนับเป็นคำตอบ: ${t}`);
  }
});

test('wake: คำสะกดเพี้ยนที่เจอจริง (9 ต.ค. "พลายดีจ๊ะ") ต้องปลุก', () => {
  for (const t of ['พลายดีจ๊ะ', 'พลายเดย์', 'ฟลายเดย์ เปิดเพลง', 'ไพรเดย์']) assert.equal(matchWake(t).wake, true, t);
});

test('wakeDecision: คำปลุกล้วนต้องผ่านรอบสอง (ไม่มีคำใบ้) · มีคำสั่งต่อท้ายปลุกเลย', async () => {
  const { wakeDecision } = await import('../lib/rules.mjs');
  assert.equal(wakeDecision('ฟรายเดย์ เปิดเพลงหน่อย').wake, true);          // เสียงหลอนไม่มีคำต่อท้าย
  assert.equal(wakeDecision('ฟรายเดย์').wake, null);                        // ต้องฟังรอบสอง
  assert.equal(wakeDecision('ฟรายเดย์', 'ฟรายดิ').wake, true);              // เสียงคนจริง (วัด 9 ต.ค.)
  assert.equal(wakeDecision('ฟรายเดย์', 'พลายดีจ๊ะ').wake, true);           // user จริง 9 ต.ค.
  assert.equal(wakeDecision('ฟรายเดย์', 'กลับมากันเถอะ').wake, false);      // เสียงซ่า (วัด 9 ต.ค.)
  assert.equal(wakeDecision('ฟรายเดย์', 'สว sunflower').wake, false);       // เสียงหึ่ง
  assert.equal(wakeDecision('[เสียงดนตรี] ฟรายเดย์', '[เสียงดนตรี]').wake, false);
  assert.equal(wakeDecision('ฟรายเดย์ ฟรายเดย์ ฟรายเดย์').wake, false);     // ซ้ำ 3 = หลอน
  assert.equal(wakeDecision('วันนี้อากาศดี').wake, false);
});
