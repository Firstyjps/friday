// นโยบายอนุญาตเครื่องมือของ Claude อัตโนมัติ (ลดการถามยืนยัน) — ตัดสินก่อนจะไปถามผู้ใช้
// หลัก: อ่าน/ค้น/ดึงข้อมูล/เขียนไฟล์ในโฟลเดอร์ปกติ = ผ่าน · ย้อนกลับไม่ได้ / ออกนอกเครื่อง / แตะระบบ / โฟลเดอร์หวง = ถาม
import { homedir } from 'node:os';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { join, dirname, resolve } from 'node:path';

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
function underHome(path) { return resolve(expand(path)).startsWith(HOME + '/'); }

/** แยก shell command เป็นส่วนย่อยตาม ; && || | แล้วให้ทุกส่วนผ่าน */
function segments(cmd) {
  return String(cmd).replace(/\\\n/g, ' ').split(/\s*(?:&&|\|\||;|\|)\s*/).map((s) => s.trim()).filter(Boolean);
}
function firstWord(seg) {
  // ข้าม env assignment เช่น FOO=1 cmd
  const parts = seg.replace(/^(\w+=\S+\s+)+/, '').split(/\s+/);
  return (parts[0] || '').replace(/^.*\//, '');
}

export function bashDecision(cmd, opts = {}) {
  const protectedList = opts.protectedPaths ?? PROTECTED_DEFAULT;
  if (/\$\(|`|\beval\b|\bexec\b|\bsource\b|^\s*\./.test(cmd)) return { allow: false, why: 'subshell/eval' };
  for (const seg of segments(cmd)) {
    const w = firstWord(seg);
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
  const key = ruleKey(tool, input);
  if (key && rules.includes(key)) return { allow: true, why: `เคยยืนยันตลอด (${key})` };
  if (trust === 'ask') return { allow: false, why: 'โหมดถามทุกครั้ง' };
  const opts = { protectedPaths };
  if (trust === 'full') {                 // ให้สิทธิ์เต็ม: ถามเฉพาะที่กู้คืนไม่ได้จริงๆ / ออกไป VPS / โฟลเดอร์หวง
    if (tool === 'Bash') {
      for (const seg of segments(input.command || '')) { const w = firstWord(seg); if (FULL_ASK.has(w)) return { allow: false, why: `คำสั่ง ${w}` }; }
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
