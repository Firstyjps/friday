// ทดสอบ Tuya Cloud: node --env-file=.env scripts/tuya.mjs            → รายชื่อฉาก
//                   node --env-file=.env scripts/tuya.mjs "เปิดแอร์" → สั่งฉากนั้นจริง
import { Tuya } from '../lib/tuya.mjs';
const t = Tuya.fromEnv();
if (!t) { console.error('ยังไม่มี TUYA_CLIENT_ID / TUYA_SECRET / TUYA_UID ใน .env'); process.exit(1); }
const name = process.argv[2];
if (!name) for (const s of await t.listScenes()) console.log(`${s.name}\t${s.scene_id}`);
else console.log((await t.trigger(name)) ? `สั่ง "${name}" แล้ว` : `ไม่มีฉากชื่อ "${name}"`);
