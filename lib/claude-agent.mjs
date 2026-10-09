// Claude Agent SDK: 1 process ต่อ convo ค้างไว้ (ไม่ cold start ทุกงาน) + ด่านยืนยันระดับ tool call (canUseTool)
// แทน `claude -p` ที่ต้อง spawn ใหม่ทุกครั้งและกันได้แค่ระดับชื่อคำสั่ง
import { query } from '@anthropic-ai/claude-agent-sdk';
import { HARD_DENY, SECRET_DENY, agentEnv } from './rules.mjs';

export class AgentSession {
  /**
   * @param {object} o
   * @param {string} o.cwd
   * @param {string} o.claudePath        ตัว claude ที่ติดตั้งไว้ (ใช้ login เดิมของผู้ใช้)
   * @param {string} o.systemAppend      กติกาต่อท้าย system prompt
   * @param {(tool: string, input: object, signal: AbortSignal) => Promise<boolean>} o.onPermission  true = อนุญาต
   * @param {(line: string) => void} [o.log]
   * @param {(tool: string, input: object) => Promise<boolean>} [o.guard]  true = ต้องผ่าน onPermission แม้ SDK จะอนุญาตเอง (ไฟล์ลับ/คำสั่งห้าม)
   * @param {string} [o.resumeId]      ทำต่อจาก Claude session เดิมของบทสนทนานี้ (หลังปิดเพราะว่างนาน/server รีสตาร์ท)
   */
  constructor({ cwd, claudePath, systemAppend, onPermission, guard, resumeId, log = () => {} }) {
    this.cwd = cwd; this.claudePath = claudePath; this.systemAppend = systemAppend;
    this.onPermission = onPermission; this.guard = guard; this.resumeId = resumeId; this.log = log;
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
        // ไม่มี allowedTools: ชื่อใน allowedTools ทำให้ SDK ข้าม canUseTool (Read ไฟล์ลับผ่านเงียบ) → ทุก tool ผ่าน policy.decide ใน server
        disallowedTools: [...HARD_DENY, ...SECRET_DENY],   // ห้ามเสมอ (ชั้นสำรองของ secretCheck)
        canUseTool: async (tool, input, { signal }) => {   // policy ตัดสิน: อ่าน/ค้นผ่าน · ไฟล์ลับ/เสี่ยง → ถามผู้ใช้ด้วยเสียง
          const ok = await this.onPermission(tool, input, signal).catch(() => false);
          return ok ? { behavior: 'allow', updatedInput: input } : { behavior: 'deny', message: 'ผู้ใช้ไม่อนุญาต (หรือไม่ได้ยืนยันในเวลา) — หยุดแล้วสรุปสิ่งที่ทำได้/ไม่ได้' };
        },
        // canUseTool ไม่ถูกเรียกกับ Read/Glob/Grep ใต้ cwd (=HOME) → secretCheck ไม่ทำงาน (รีวิว 9 ต.ค.) · ดักทุก tool ก่อนรันที่นี่
        hooks: { PreToolUse: [{ timeout: 600, hooks: [async (h, _id, { signal }) => {
          if (!this.guard || !(await this.guard(h.tool_name, h.tool_input ?? {}).catch(() => true))) return {};
          const ok = await this.onPermission(h.tool_name, h.tool_input ?? {}, signal).catch(() => false);
          this.log(`agent: PreToolUse ${h.tool_name} → ${ok ? 'อนุญาต' : 'ปฏิเสธ'}`);
          return { hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: ok ? 'allow' : 'deny',
            permissionDecisionReason: ok ? 'ผู้ใช้อนุญาต' : 'ไฟล์ลับหรือคำสั่งต้องห้าม — ผู้ใช้ไม่อนุญาต หยุดแล้วสรุปสิ่งที่ทำได้/ไม่ได้' } };
        }] }] },
        mcpServers: {}, strictMcpConfig: true,  // ไม่มี MCP (ไม่มี paybox/ms365)
        settingSources: [],                     // ไม่โหลด settings/CLAUDE.md ของผู้ใช้ (มี defaultMode bypassPermissions)
        systemPrompt: { type: 'preset', preset: 'claude_code', append: this.systemAppend },
        maxTurns: 400,
        ...(this.resumeId ? { resume: this.resumeId } : {}),
        env: agentEnv(),
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
      // ยังไม่เคยได้ session id = เริ่มไม่ขึ้น (เช่น resume session เก่าไม่ได้) → dead ให้ผู้เรียกเริ่มใหม่
      this.turn?.resolve({ ok: false, text: `Claude session พัง: ${e.message}`, dead: !this.sessionId }); this.turn = null;
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
