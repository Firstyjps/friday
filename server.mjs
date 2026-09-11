// Friday — local server: เสิร์ฟหน้าเว็บ + ออก ephemeral token ของ Gemini Live (API key ไม่ออกจาก Mac)
import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join } from 'node:path';

const PORT = Number(process.env.PORT || 4850);
const HOST = process.env.HOST || '127.0.0.1';
const KEY = process.env.GEMINI_API_KEY;
const PUBLIC = join(import.meta.dirname, 'public');
const TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.webmanifest': 'application/manifest+json', '.png': 'image/png' };

async function createToken() {
  if (!KEY) throw new Error('GEMINI_API_KEY ไม่ได้ตั้งใน ~/friday/.env');
  const now = Date.now();
  const res = await fetch('https://generativelanguage.googleapis.com/v1beta/auth_tokens', {
    method: 'POST',
    headers: { 'x-goog-api-key': KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      uses: 1,
      expireTime: new Date(now + 30 * 60e3).toISOString(),
      newSessionExpireTime: new Date(now + 60e3).toISOString(),
    }),
  });
  const body = await res.json();
  if (!res.ok) throw new Error(`auth_tokens ${res.status}: ${JSON.stringify(body).slice(0, 300)}`);
  return body.name;
}

const json = (res, code, obj) => { res.writeHead(code, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(obj)); };

http.createServer(async (req, res) => {
  try {
    if (req.method === 'POST' && req.url === '/api/token') return json(res, 200, { token: await createToken() });
    const path = req.url === '/' ? '/index.html' : req.url.split('?')[0];
    if (path.includes('..')) return json(res, 400, { error: 'bad path' });
    const data = await readFile(join(PUBLIC, path));
    res.writeHead(200, { 'Content-Type': TYPES[extname(path)] || 'application/octet-stream' });
    res.end(data);
  } catch (e) {
    if (e.code === 'ENOENT') return json(res, 404, { error: 'not found' });
    console.error(e);
    json(res, 500, { error: e.message });
  }
}).listen(PORT, HOST, () => console.log(`Friday → http://${HOST}:${PORT}`));
