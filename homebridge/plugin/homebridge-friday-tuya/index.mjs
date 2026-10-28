// โชว์ฉาก Tap-to-Run ของ Smart Life เป็นสวิตช์/ไฟใน Apple Home → HomePod mini สั่งด้วย Siri ได้ native (28 ต.ค.)
// ใช้ key Tuya ชุดเดียวกับ Friday (~/Desktop/FRIDAY/.env) · สถานะเป็นแค่ "คำสั่งล่าสุด" เพราะแอร์/ทีวีเป็น IR ไม่มีสถานะจริงให้อ่าน
import { fileURLToPath } from 'node:url';
import { Tuya } from '../../../lib/tuya.mjs';

const ENV = fileURLToPath(new URL('../../../.env', import.meta.url));
const PLUGIN = 'homebridge-friday-tuya', PLATFORM = 'FridayTuya';

export default (api) => api.registerPlatform(PLUGIN, PLATFORM, class {
  constructor(log, config) {
    this.log = log; this.devices = config.devices ?? []; this.cached = new Map();
    try { process.loadEnvFile(ENV); } catch (e) { log.error(`อ่าน ${ENV} ไม่ได้: ${e.message}`); }
    this.tuya = Tuya.fromEnv();
    if (!this.tuya) log.error('ไม่มี TUYA_CLIENT_ID / TUYA_SECRET / TUYA_UID');
    api.on('didFinishLaunching', () => this.sync());
  }
  configureAccessory(acc) { this.cached.set(acc.UUID, acc); }

  sync() {
    const { Service, Characteristic, uuid } = api.hap;
    const keep = new Set();
    for (const d of this.devices) {
      const id = uuid.generate(`${PLUGIN}:${d.name}`); keep.add(id);
      let acc = this.cached.get(id);
      if (!acc) { acc = new api.platformAccessory(d.name, id); api.registerPlatformAccessories(PLUGIN, PLATFORM, [acc]); }
      const type = d.type === 'light' ? Service.Lightbulb : Service.Switch;
      for (const s of acc.services.filter((s) => s.UUID === Service.Lightbulb.UUID || s.UUID === Service.Switch.UUID)) if (s.UUID !== type.UUID) acc.removeService(s);
      const svc = acc.getService(type) ?? acc.addService(type, d.name);
      let state = false;
      svc.getCharacteristic(Characteristic.On)
        .onGet(() => state)
        .onSet(async (v) => {
          const scene = v ? d.on : d.off;
          if (!scene) { setTimeout(() => svc.updateCharacteristic(Characteristic.On, state), 300); return; }   // ฉากฝั่งนี้ไม่มี → เด้งกลับ
          try { if (!(await this.tuya?.trigger(scene))) throw new Error('ไม่มีฉากชื่อนี้'); state = !!v; this.log.info(`${d.name} → ${scene}`); }
          catch (e) { this.log.error(`${d.name} → ${scene} ไม่สำเร็จ: ${e.message}`); throw new api.hap.HapStatusError(api.hap.HAPStatus.SERVICE_COMMUNICATION_FAILURE); }
        });
    }
    const stale = [...this.cached].filter(([id]) => !keep.has(id)).map(([, a]) => a);
    if (stale.length) api.unregisterPlatformAccessories(PLUGIN, PLATFORM, stale);
  }
});
