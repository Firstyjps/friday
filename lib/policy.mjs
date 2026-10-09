// นโยบายอนุญาตเครื่องมือของ Claude อัตโนมัติ (ลดการถามยืนยัน) — ตัดสินก่อนจะไปถามผู้ใช้
// หลัก: อ่าน/ค้น/ดึงข้อมูล/เขียนไฟล์ในโฟลเดอร์ปกติ = ผ่าน · ย้อนกลับไม่ได้ / ออกนอกเครื่อง / แตะระบบ / โฟลเดอร์หวง = ถาม
import { homedir } from 'node:os';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { join, dirname, resolve, basename } from 'node:path';
import { existsSync, readdirSync, statSync } from 'node:fs';

const HOME = homedir();

// คำสั่งที่ปลอดภัยเมื่อรันตรงๆ (ตรวจ flag อันตรายเพิ่มด้านล่าง)
const SAFE_CMDS = new Set(['ls', 'cat', 'head', 'tail', 'wc', 'grep', 'rg', 'awk', 'cut', 'sort', 'uniq', 'tr', 'echo', 'printf', 'date', 'cal', 'df', 'du', 'ps', 'top', 'uptime',
  'whoami', 'id', 'open', 'mdfind', 'mdls', 'file', 'stat', 'which', 'env', 'printenv', 'jq', 'sw_vers', 'system_profiler', 'pmset', 'uname', 'hostname', 'ifconfig', 'netstat', 'lsof',
  'ping', 'dig', 'nslookup', 'host', 'say', 'afplay', 'screencapture', 'pbpaste', 'pbcopy', 'shortcuts', 'osascript', 'curl', 'wget', 'find', 'tree', 'diff', 'cmp', 'basename', 'dirname',
  'realpath', 'pwd', 'true', 'test', 'xargs', 'tee', 'mkdir', 'touch', 'cp', 'ditto', 'zip', 'unzip', 'tar', 'gzip', 'gunzip', 'sips', 'qlmanage', 'textutil', 'plutil', 'sqlite3',
  'python3', 'python', 'node', 'swift', 'ruby', 'perl', 'bc', 'expr', 'seq', 'yes', 'sleep', 'caffeinate', 'defaults', 'networksetup', 'brew', 'npm', 'pip', 'pip3', 'git', 'claude']);
// คำสั่งเหล่านี้ถามเสมอ (ย้อนกลับไม่ได้/แตะระบบ/ออกนอกเครื่อง)
const ASK_CMDS = new Set(['rm', 'rmdir', 'mv', 'chmod', 'chown', 'ln', 'kill', 'pkill', 'killall', 'launchctl', 'ssh', 'scp', 'rsync', 'sftp', 'ftp', 'nc', 'telnet', 'sudo', 'su',
  'shutdown', 'reboot', 'halt', 'diskutil', 'dd', 'mkfs', 'crontab', 'at', 'systemsetup', 'scutil', 'dscl', 'security', 'csrutil', 'spctl', 'tccutil', 'xattr', 'codesign', 'installer',
  'softwareupdate', 'vercel', 'gh', 'docker', 'kubectl', 'terraform', 'aws', 'gcloud', 'az', 'mail', 'sendmail', 'osascript']);
// โหมด full ยังถามเฉพาะพวกนี้
const FULL_ASK = new Set(['sudo', 'su', 'ssh', 'scp', 'rsync', 'sftp', 'dd', 'mkfs', 'diskutil', 'shutdown', 'reboot', 'halt', 'csrutil', 'tccutil']);
// flag/รูปแบบที่ทำให้คำสั่ง "ปลอดภัย" กลายเป็นเสี่ยง
const DANGER_IN_SAFE = [
  [/^(curl|wget)\b/, /(\s-(d|F|T|X\s*(POST|PUT|DELETE|PATCH))\b|--(data|data-\w+|form|upload-file|request\s+(POST|PUT|DELETE|PATCH)|method))/i],
  [/^find\b/, /\s-(delete|exec|execdir|ok|okdir)\b/],
  [/^git\b/, /\bgit\s+(push|reset|clean|checkout\s+--|rebase|filter-branch|gc\s+--prune|remote\s+(add|remove|set-url)|config\s+--global|stash\s+(drop|clear))\b/],
  [/^(brew|npm|pip3?|pipx|gem|cargo)\b/, /\b(install|uninstall|remove|upgrade|update|publish|link|unlink|cleanup|autoremove)\b/],
  [/^defaults\b/, /\bdefaults\s+(write|delete|import)\b/],
  [/^networksetup\b/, /\s-set/i],
  [/^pmset\b/, /\bpmset\s+(?!-g)/],
  [/^(python3?|node|ruby|perl|swift)\b/, /\b(os\.remove|os\.unlink|shutil\.rmtree|rmSync|unlinkSync|rimraf|subprocess|child_process|requests\.(post|put|delete)|fetch\(|urlopen|socket|smtplib|-e\s|-c\s)/],
  [/^claude\b/, /./],                       // ห้ามให้ Claude ของ Friday สั่ง Claude อีกตัว
  [/^(zip|tar|ditto|cp|sqlite3)\b/, /\s(\/|~\/\.)/],   // แตะ root หรือ dotfiles
];
// โฟลเดอร์/ไฟล์ที่ห้ามเขียนโดยไม่ถาม
const PROTECTED_DEFAULT = ['~/.ssh', '~/.aws', '~/.gnupg', '~/.config', '~/.claude', '~/Library', '~/.hermes', '~/.*', '/etc', '/usr', '/bin', '/sbin', '/System', '/Library', '/private/etc',
  '~/Desktop/FRIDAY/.env', '*funding-executor*', '*katana*', '*executor*', '*bot*'];

const expand = (p) => p.replace(/^~/, HOME);
function globToRe(g) { return new RegExp('^' + expand(g).replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*') + '(/|$)'); }
function isProtected(path, protectedList) {
  const abs = resolve(expand(path));
  return protectedList.some((g) => globToRe(g).test(abs));
}
// ไฟล์ลับ (คีย์/รหัส/token) — ห้ามอ่านหรือแตะโดยไม่ถาม ทุกระดับ trust และแม้งานนั้นยืนยันไปแล้ว (กันอ่านคีย์แล้วส่งออกผ่าน WebFetch/curl)
const SECRET_DIRS = ['~/.ssh', '~/.aws', '~/.gnupg', '~/.config/gcloud', '~/.kube', '~/.docker', '~/.hermes', '~/.claude', '~/.agy-profiles', '~/Library/Keychains', '~/Library/Cookies',
  '~/Library/Application Support/Google/Chrome', '~/Library/Application Support/BraveSoftware', '~/Library/Application Support/Arc'];
const SECRET_NAME = /(^|\/)(\.env(\..*)?|\.netrc|\.npmrc|\.pypirc|\.git-credentials|id_(rsa|ed25519|ecdsa|dsa)[^/]*|.*\.(pem|key|p12|pfx|keystore|kdbx)|.*(secret|credential|password|passwd|private[-_]?key|mnemonic|seed[-_]?phrase|wallet)[^/]*|auth\.json|tokens?\.json|cookies(\.sqlite)?)$/i;
const SECRET_ENV = /\$\{?(HOME)\}?/g;

// ชื่อไฟล์/โฟลเดอร์ลับตัวอย่าง — ใช้เทียบกับ glob ที่ shell จะขยาย (`.e?v`, `~/.s*h/*` เคยหลบด่านได้)
const SECRET_SAMPLES = ['.env', '.env.local', '.netrc', '.npmrc', '.pypirc', '.git-credentials', 'id_rsa', 'id_ed25519', 'server.pem', 'server.key', 'auth.json', 'token.json',
  'tokens.json', 'cookies.sqlite', 'Cookies', 'Login Data', 'credentials', 'secrets.json', 'wallet.dat'];
const GLOB = /[*?[\]{}]/;
const globPathRe = (g) => new RegExp('^' + g.replace(/[.+^$()|\\]/g, '\\$&').replace(/\*\*/g, '\u0000').replace(/\*/g, '[^/]*').replace(/\?/g, '[^/]').replace(/\u0000/g, '.*')
  .replace(/\{([^}]*)\}/g, (_, a) => `(${a.split(',').join('|')})`) + '$');
/** glob ที่ shell จะขยายแล้วไปโดนไฟล์/โฟลเดอร์ลับไหม */
function globHitsSecret(abs) {
  const name = basename(abs), dirRe = globPathRe(abs);
  if (GLOB.test(name) && SECRET_SAMPLES.some((n) => globPathRe(name).test(n))) return true;
  return SECRET_DIRS.map(expand).some((d) => [d, `${d}/x`, `${d}/x/y`].some((x) => dirRe.test(x)));
}

/** path นี้เป็นไฟล์ลับ หรืออยู่ในโฟลเดอร์หวงไหม (ใช้ทั้งอ่านและเขียน) · path สัมพัทธ์คิดจาก base (Claude ของ Friday ทำงานที่ HOME) */
export function isSecretPath(path, protectedList = [], base = HOME) {
  if (!path) return false;
  const raw = String(path).replace(SECRET_ENV, HOME);
  if (SECRET_NAME.test(raw)) return true;
  if (GLOB.test(raw) && globHitsSecret(resolve(base, expand(raw)))) return true;
  const p = raw.replace(/[*?[\]{}].*$/, '').replace(/\/+$/, '') || '/';   // glob → ตัดเหลือส่วนที่เป็น path
  const abs = resolve(base, expand(p));
  // protectedPaths ที่เป็นโฟลเดอร์ระบบ (/etc, /Library…) หวงแค่การเขียน — การอ่านปล่อย
  return SECRET_DIRS.some((g) => globToRe(g).test(abs)) || isProtected(abs, protectedList.filter((g) => !g.startsWith('/')));
}

/** แยกคำแบบ shell: ต่อ quote ที่ติดกัน (`.e"n"v` = `.env`), `\ ` = เว้นวรรคในชื่อ, ตัดที่ ; & | < > ( ) = */
export function shellWords(cmd) {
  const words = []; let cur = '', q = null, has = false;
  const s = String(cmd);
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (q) { if (ch === q) q = null; else if (ch === '\\' && q === '"' && i + 1 < s.length) cur += s[++i]; else cur += ch; continue; }
    if (ch === "'" || ch === '"') { q = ch; has = true; continue; }
    if (ch === '\\' && i + 1 < s.length) { cur += s[++i]; has = true; continue; }
    if (/[\s;&|<>()=`]/.test(ch)) { if (has) words.push(cur); cur = ''; has = false; continue; }
    cur += ch; has = true;
  }
  if (has) words.push(cur);
  return words;
}

/** โฟลเดอร์นี้มีของลับอยู่ข้างใน (สำหรับคำสั่งที่อ่านทั้งโฟลเดอร์ เช่น grep -r) — ไล่ดูแค่ 2 ชั้น */
function dirHasSecret(abs, depth = 2) {
  if (SECRET_DIRS.map(expand).some((d) => d === abs || d.startsWith(abs === '/' ? '/' : abs + '/'))) return true;
  try {
    if (!statSync(abs).isDirectory()) return false;
    const items = readdirSync(abs, { withFileTypes: true }).slice(0, 300);
    if (items.some((e) => SECRET_NAME.test(e.name))) return true;
    return depth > 1 && items.some((e) => e.isDirectory() && !['node_modules', '.git', 'Library'].includes(e.name) && dirHasSecret(join(abs, e.name), depth - 1));
  } catch { return false; }
}
// คำสั่งที่อ่านทั้งโฟลเดอร์ (รวมไฟล์ซ่อน) → ถ้าในนั้นมีไฟล์ลับถือว่าแตะไฟล์ลับ · rg ข้ามไฟล์ซ่อนเองยกเว้นสั่ง --hidden/-u
const RECURSIVE_READ = /(^|[\s;&|(])(grep\s+(-\w*[rR]\w*|--recursive|-[dD]\s*recurse)\b|rg\s+.*(--hidden|--no-ignore|\s-u+\b)|(ag|ack)\s|tar\s+-?\w*c|zip\s+-\w*r|cp\s+-\w*[rR]|rsync\s|ditto\s|find\s.*-exec\s+(cat|head|tail|grep|less|more|strings)\b|cat\s+.*\*)/

/** tool call นี้แตะไฟล์ลับไหม → { why } หรือ null */
export function secretCheck(tool, input = {}, protectedPaths) {
  const list = protectedPaths ?? [];   // ใช้เฉพาะที่ config ระบุ (PROTECTED_DEFAULT มี ~/.* กว้างเกินสำหรับการอ่าน)
  if (tool === 'Bash') {
    const cmd = String(input.command || '');
    if (/\b(security\s+(find|dump|export)|printenv|env\s*$|env\s*\||defaults\s+read\s+\S*(password|token))/i.test(cmd)) return { why: 'อ่าน keychain/ตัวแปรระบบ' };
    // path สัมพัทธ์คิดจาก HOME (ที่ Claude ทำงาน) และจากทุกที่ที่คำสั่ง cd ไป (`cd ~ && cat .ssh/config`)
    const bases = [HOME, ...[...cmd.matchAll(/\b(?:cd|pushd)\s+("[^"]+"|'[^']+'|\S+)/g)].map((m) => resolve(HOME, expand(m[1].replace(/^["']|["']$/g, '').replace(SECRET_ENV, HOME))))];
    const recursive = RECURSIVE_READ.test(cmd);
    for (const w of shellWords(cmd)) {
      const t = w.replace(/^@/, '');
      if (!t || /^-/.test(t) && !t.includes('/')) continue;
      if (!(/[~/$]/.test(t) || t.startsWith('.') || SECRET_NAME.test(t) || GLOB.test(t))) continue;   // คำธรรมดา (ไม่ใช่ path) ไม่ต้องเช็ค
      if (bases.some((b) => isSecretPath(t, list, b))) return { why: `แตะไฟล์ลับ ${t}` };
      if (recursive && !/^https?:/.test(t) && bases.some((b) => dirHasSecret(resolve(b, expand(t.replace(SECRET_ENV, HOME)))))) return { why: `อ่านทั้งโฟลเดอร์ที่มีไฟล์ลับ ${t}` };
    }
    // grep -r โดยไม่ระบุโฟลเดอร์ = อ่านทั้ง HOME
    if (recursive && /\bgrep\b/.test(cmd) && !shellWords(cmd).some((w) => /[~/.$]/.test(w) && !/^-/.test(w))) return { why: 'อ่านทั้งโฟลเดอร์ที่มีไฟล์ลับ (HOME)' };
    return null;
  }
  const paths = [input.file_path, input.notebook_path, input.path, tool === 'Glob' ? input.pattern : null, input.glob].filter(Boolean);
  if (tool === 'Glob' && input.path && input.pattern) paths.push(`${input.path}/${input.pattern}`);
  const hit = paths.find((p) => isSecretPath(p, list));
  return hit ? { why: `แตะไฟล์ลับ ${hit}` } : null;
}

// เครื่องมืออ่าน/ค้น/ดูเว็บ — ผ่านเองถ้าไม่แตะไฟล์ลับ (ไม่ใส่ใน allowedTools ของ SDK แล้ว เพราะจะข้าม canUseTool ทั้งหมด)
export const READ_TOOLS = new Set(['Read', 'Glob', 'Grep', 'LS', 'WebFetch', 'WebSearch', 'TodoWrite', 'NotebookRead']);

function underHome(path) { return resolve(expand(path)).startsWith(HOME + '/'); }

/** แยก shell command เป็นส่วนย่อยตาม ; && || | ขึ้นบรรทัดใหม่ และ & (รันเบื้องหลัง) แล้วให้ทุกส่วนผ่าน
 *  (เดิมไม่แยก newline/& → คำสั่งบรรทัดที่สองหรือหลัง & หลุดการตรวจ) · ไม่แยก 2>&1, >&, &> */
export function segments(cmd) {
  return String(cmd).replace(/\\\r?\n/g, ' ').split(/\s*(?:&&|\|\||;|\||\r?\n|(?<![>&\d])&(?![&>]))\s*/).map((s) => s.trim()).filter(Boolean);
}
// คำสั่งที่ห่อคำสั่งอื่น (`env sudo …`, `nohup ssh …`, `xargs rm`) → ดูคำสั่งข้างในแทน
const WRAPPERS = new Set(['env', 'command', 'builtin', 'nohup', 'time', 'nice', 'exec', 'xargs', 'caffeinate', 'timeout', 'gtimeout', 'arch', 'then', 'do', 'else', 'if', 'while', 'until', '!', '{']);
const SHELLS = new Set(['sh', 'bash', 'zsh', 'dash', 'ksh', 'fish']);
/** ตัด ( { ! FOO=1 และ wrapper ข้างหน้าออก → เหลือส่วนที่เริ่มด้วยคำสั่งจริง */
function unwrap(seg) {
  let parts = seg.replace(/^[\s({!]+/, '').split(/\s+/).filter(Boolean);
  for (;;) {
    while (parts.length && /^\w+=/.test(parts[0])) parts.shift();
    const w = (parts[0] || '').replace(/^.*\//, '').replace(/^['"]|['"]$/g, '');
    if (!WRAPPERS.has(w)) break;
    parts.shift();
    while (parts.length && (/^-/.test(parts[0]) || /^\d+[smhd]?$/.test(parts[0]))) {      // flag ของ wrapper (nice -n 5, timeout 10, xargs -n 1 -I{})
      const f = parts.shift(); if (/^-(n|I|L|P|s|u|S|a)$/.test(f) && parts.length) parts.shift();
    }
  }
  return parts.join(' ');
}
function firstWord(seg) { return (unwrap(seg).split(/\s+/)[0] || '').replace(/^.*\//, '').replace(/^['"]|['"]$/g, ''); }
/** ทุกคำสั่งที่จะถูกรันจริง: ทุก segment + ข้างใน $(…), `…` และ sh -c "…" */
export function commandWords(cmd) {
  const s = String(cmd), inner = [];
  for (const m of s.matchAll(/\$\(([^()]*)\)|`([^`]*)`|<\(([^()]*)\)/g)) inner.push(m[1] ?? m[2] ?? m[3]);
  const out = [];
  for (const seg of segments(s)) {
    const u = unwrap(seg), w = firstWord(seg);
    if (w) out.push(w);
    if (SHELLS.has(w)) { const m = u.match(/\s-\w*c\w*\s+(["'])([\s\S]*?)\1/) ?? u.match(/\s-\w*c\w*\s+(\S+)/); if (m) inner.push(m[2] ?? m[1]); }
  }
  for (const x of inner) if (x && x !== s) out.push(...commandWords(x));
  return out;
}

// ---------- ห้ามเสมอ (แม้ยืนยันแล้ว / ทุก trust) — ตรงกับ HARD_DENY ใน rules.mjs แต่ตรวจแบบเข้าใจคำสั่ง ----------
// HARD_DENY ของ SDK เทียบ prefix ตรงตัว → `/usr/bin/sudo`, `env sudo`, `rm -rf *` ใน HOME หลุด
const HARD_CMDS = new Set(['sudo', 'shutdown', 'reboot', 'diskutil', 'dd', 'mkfs']);
const ROOTISH = new Set(['/', '/*', '~', '~/', '~/*', '$HOME', '${HOME}', '$HOME/', '$HOME/*', '${HOME}/*', HOME, `${HOME}/`, `${HOME}/*`]);
export function hardDeny(tool, input = {}) {
  if (tool !== 'Bash') return null;
  const cmd = String(input.command || '');
  for (const w of commandWords(cmd)) if (HARD_CMDS.has(w) || /^mkfs\./.test(w)) return { why: `คำสั่ง ${w} (ห้ามเสมอ)` };
  const cd = /\b(cd|pushd)\s/.test(cmd);
  for (const seg of segments(cmd)) {
    const parts = shellWords(unwrap(seg));
    if ((parts[0] || '').replace(/^.*\//, '') !== 'rm' || !parts.some((p) => /^-\w*[rR]/.test(p) || p === '--recursive')) continue;
    const targets = parts.slice(1).filter((p) => !p.startsWith('-')).map((p) => p.replace(/\/+$/, '') || '/');
    if (targets.some((t) => ROOTISH.has(t) || ROOTISH.has(t + '/') || (!cd && (t === '*' || t === '.' || t === './*')))) return { why: 'ลบทั้ง root/HOME (ห้ามเสมอ)' };
  }
  return null;
}

export function bashDecision(cmd, opts = {}) {
  const protectedList = opts.protectedPaths ?? PROTECTED_DEFAULT;
  if (/\$\(|`|\beval\b|\bexec\b|\bsource\b|^\s*\./.test(cmd)) return { allow: false, why: 'subshell/eval' };
  for (const raw of segments(cmd)) {
    const seg = unwrap(raw), w = firstWord(raw);       // `env rm …`/`xargs rm` ตรวจที่ rm ไม่ใช่ env/xargs
    if (!w) continue;
    if (ASK_CMDS.has(w) && !(w === 'osascript' && /^osascript\s+-e\s+['"]tell application ["'][^"']+["'] to (activate|open)/.test(seg))) return { allow: false, why: `คำสั่ง ${w}` };
    if (!SAFE_CMDS.has(w)) return { allow: false, why: `คำสั่ง ${w} ไม่อยู่ในรายการปลอดภัย` };
    for (const [head, bad] of DANGER_IN_SAFE) if (head.test(seg) && bad.test(seg)) return { allow: false, why: `${w} มี flag เสี่ยง` };
    // redirect เขียนไฟล์ → ต้องอยู่ในโฟลเดอร์ปกติ
    const m = seg.match(/(?:^|[^&])>{1,2}\s*("[^"]+"|'[^']+'|\S+)/);
    if (m) {
      const target = m[1].replace(/^["']|["']$/g, '');
      if (target !== '/dev/null' && !(/^\/tmp\//.test(target) || (underHome(target) && !isProtected(target, protectedList)))) return { allow: false, why: 'เขียนไฟล์นอกโฟลเดอร์ปกติ' };
    }
  }
  return { allow: true, why: 'คำสั่งอ่าน/ดึงข้อมูล/ปลอดภัย' };
}

export function fileDecision(path, opts = {}) {
  const protectedList = opts.protectedPaths ?? PROTECTED_DEFAULT;
  if (!path) return { allow: false, why: 'ไม่มี path' };
  if (/^\/tmp\//.test(path)) return { allow: true, why: '/tmp' };
  if (!underHome(path)) return { allow: false, why: 'นอก home' };
  if (isProtected(path, protectedList)) return { allow: false, why: 'โฟลเดอร์หวง' };
  return { allow: true, why: 'ไฟล์ในโฟลเดอร์ปกติ' };
}

/** ตัดสินใจรวม: rules ที่ผู้ใช้เคย "ยืนยันตลอด" มาก่อน → นโยบายในตัว */
export function decide(tool, input, { trust = 'relaxed', rules = [], protectedPaths } = {}) {
  const hard = hardDeny(tool, input);
  if (hard) return { allow: false, why: hard.why, hard: true };
  const secret = secretCheck(tool, input, protectedPaths);
  if (secret) return { allow: false, why: secret.why, secret: true };   // ก่อน rules: "ยืนยันตลอด cat" ไม่ครอบไฟล์ลับ
  // trust=ask (ผู้ใช้อยากให้ถามทุกอย่าง) → ดูเว็บก็ถาม เพราะส่งข้อมูลออกนอกเครื่องได้
  if (READ_TOOLS.has(tool) && !(trust === 'ask' && (tool === 'WebFetch' || tool === 'WebSearch'))) return { allow: true, why: 'อ่าน/ค้น' };
  const key = ruleKey(tool, input);
  if (key && rules.includes(key)) return { allow: true, why: `เคยยืนยันตลอด (${key})` };
  if (trust === 'ask') return { allow: false, why: 'โหมดถามทุกครั้ง' };
  const opts = { protectedPaths };
  if (trust === 'full') {                 // ให้สิทธิ์เต็ม: ถามเฉพาะที่กู้คืนไม่ได้จริงๆ / ออกไป VPS / โฟลเดอร์หวง
    if (tool === 'Bash') {
      // ทุกคำสั่งที่จะรันจริง รวมที่ห่อด้วย env/nohup/xargs, ข้างใน $(…) และ sh -c "…" (เดิมดูแค่คำแรก → หลบได้)
      for (const w of commandWords(input.command || '')) if (FULL_ASK.has(w)) return { allow: false, why: `คำสั่ง ${w}` };
      const m = (input.command || '').match(/\b(rm|mv|cp|chmod|chown)\s+(?:-\S+\s+)*(\S+)/);
      if (m && isProtected(m[2], protectedPaths ?? PROTECTED_DEFAULT)) return { allow: false, why: 'แตะโฟลเดอร์หวง' };
      return { allow: true, why: 'โหมดสิทธิ์เต็ม' };
    }
    if (['Write', 'Edit', 'MultiEdit', 'NotebookEdit'].includes(tool)) {
      const f = fileDecision(input.file_path || input.notebook_path || '', opts);
      return f.allow || f.why !== 'โฟลเดอร์หวง' ? { allow: true, why: 'โหมดสิทธิ์เต็ม' } : f;
    }
    return { allow: true, why: 'โหมดสิทธิ์เต็ม' };
  }
  if (tool === 'Bash') return bashDecision(input.command || '', opts);
  if (['Write', 'Edit', 'MultiEdit', 'NotebookEdit'].includes(tool)) return fileDecision(input.file_path || input.notebook_path || '', opts);
  return { allow: false, why: `เครื่องมือ ${tool}` };
}

/** key สำหรับจำ "ยืนยันตลอด": Bash → คำสั่งแรก (+ subcommand ของ git/brew/npm…) · ไฟล์ → โฟลเดอร์ */
export function ruleKey(tool, input) {
  if (tool === 'Bash') {
    const segs = segments(input.command || '');
    if (segs.length !== 1) return null;
    const parts = segs[0].replace(/^(\w+=\S+\s+)+/, '').split(/\s+/);
    const w = parts[0]?.replace(/^.*\//, ''); if (!w) return null;
    const sub = ['git', 'brew', 'npm', 'pip', 'pip3', 'docker', 'gh', 'launchctl', 'defaults', 'networksetup', 'shortcuts'].includes(w) && parts[1] && !parts[1].startsWith('-') ? ` ${parts[1]}` : '';
    if (['sudo', 'rm', 'dd', 'mkfs', 'diskutil', 'shutdown', 'reboot'].includes(w)) return null;   // ไม่ให้จำคำสั่งอันตราย
    return `Bash(${w}${sub})`;
  }
  if (['Write', 'Edit', 'MultiEdit', 'NotebookEdit'].includes(tool)) {
    const p = input.file_path || input.notebook_path; if (!p) return null;
    return `${tool}(${dirname(resolve(expand(p)))})`;
  }
  return null;
}

// ---------- rules ที่จำไว้ (data/permissions.json) ----------
export class RuleStore {
  constructor(file) { this.file = file; this.rules = []; }
  async load() { try { this.rules = JSON.parse(await readFile(this.file, 'utf8')).rules ?? []; } catch { this.rules = []; } return this; }
  async add(key) { if (!key || this.rules.includes(key)) return false; this.rules.push(key); await mkdir(dirname(this.file), { recursive: true }); await writeFile(this.file, JSON.stringify({ rules: this.rules }, null, 2)); return true; }
}
