// Claude Agent SDK: 1 process ต่อ convo ค้างไว้ (ไม่ cold start ทุกงาน) + ด่านยืนยันระดับ tool call (canUseTool)
// แทน `claude -p` ที่ต้อง spawn ใหม่ทุกครั้งและกันได้แค่ระดับชื่อคำสั่ง
import { query } from '@anthropic-ai/claude-agent-sdk';
import { READ_ONLY_TOOLS, HARD_DENY } from './rules.mjs';

export class AgentSession {
  /**
   * @param {object} o
   * @param {string} o.cwd
   * @param {string} o.claudePath        ตัว claude ที่ติดตั้งไว้ (ใช้ login เดิมของผู้ใช้)
   * @param {string} o.systemAppend      กติกาต่อท้าย system prompt
   * @param {(tool: string, input: object, signal: AbortSignal) => Promise<boolean>} o.onPermission  true = อนุญาต
   * @param {(line: string) => void} [o.log]
   */
  constructor({ cwd, claudePath, systemAppend, onPermission, log = () => {} }) {
    this.cwd = cwd; this.claudePath = claudePath; this.systemAppend = systemAppend;
    this.onPermission = onPermission; this.log = log;
    this.pending = []; this.waiters = []; this.closed = false; this.turn = null;
    this.sessionId = null; this.lastUsedAt = Date.now(); this.startedAt = Date.now();
  }

  async *#input() {
    while (!this.closed) {
      if (this.pending.length) yield this.pending.shift();
      else await new Promise((r) => this.waiters.push(r));
    }
  }
  #wake() { this.waiters.splice(0).forEach((r) => r()); }

  start() {
    this.q = query({
      prompt: this.#input(),
      options: {
        cwd: this.cwd,
        pathToClaudeCodeExecutable: this.claudePath,
        permissionMode: 'default',
        allowedTools: READ_ONLY_TOOLS,          // อ่าน/ค้น/เปิดแอปผ่านเลย
        disallowedTools: HARD_DENY,             // ห้ามเสมอ
        canUseTool: async (tool, input, { signal }) => {   // ที่เหลือ (เขียน/ลบ/รันคำสั่ง) → ถามผู้ใช้ด้วยเสียง
          const ok = await this.onPermission(tool, input, signal).catch(() => false);
          return ok ? { behavior: 'allow', updatedInput: input } : { behavior: 'deny', message: 'ผู้ใช้ไม่อนุญาต (หรือไม่ได้ยืนยันในเวลา) — หยุดแล้วสรุปสิ่งที่ทำได้/ไม่ได้' };
        },
        mcpServers: {}, strictMcpConfig: true,  // ไม่มี MCP (ไม่มี paybox/ms365)
        settingSources: [],                     // ไม่โหลด settings/CLAUDE.md ของผู้ใช้ (มี defaultMode bypassPermissions)
        systemPrompt: { type: 'preset', preset: 'claude_code', append: this.systemAppend },
        maxTurns: 400,
        env: { ...process.env, ENABLE_CLAUDEAI_MCP_SERVERS: 'false' },
      },
    });
    this.#loop();
    return this;
  }

  async #loop() {
    try {
      for await (const m of this.q) {
        if (m.type === 'system' && m.subtype === 'init') this.sessionId = m.session_id;
        if (m.type === 'result') {
          this.sessionId = m.session_id ?? this.sessionId;
          const r = this.turn; this.turn = null;
          r?.resolve({ ok: !m.is_error, text: String(m.result ?? '').trim(), denied: (m.permission_denials ?? []).map((d) => d.tool_name), costUsd: m.total_cost_usd });
        }
      }
    } catch (e) {
      this.log(`agent: loop error ${e.message}`);
      this.turn?.resolve({ ok: false, text: `Claude session พัง: ${e.message}` }); this.turn = null;
    } finally {
      this.closed = true; this.#wake();
      this.turn?.resolve({ ok: false, text: 'Claude session ปิดไปแล้ว' }); this.turn = null;
    }
  }

  /** ส่ง 1 งาน รอผลของ turn นั้น (ผู้เรียกต้องเรียงคิวเอง — ครั้งละงาน) */
  ask(text) {
    if (this.closed) return Promise.resolve({ ok: false, text: 'Claude session ปิดไปแล้ว', dead: true });
    this.lastUsedAt = Date.now();
    return new Promise((resolve) => {
      this.turn = { resolve };
      this.pending.push({ type: 'user', message: { role: 'user', content: text }, parent_tool_use_id: null });
      this.#wake();
    });
  }

  get busy() { return !!this.turn; }

  /** ผู้ใช้ยกเลิกกลางคัน */
  async interrupt() { try { await this.q?.interrupt(); } catch {} }

  close() {
    if (this.closed) return;
    this.closed = true; this.#wake();     // generator จบ → SDK ปิด process อย่างสุภาพ
  }
}
