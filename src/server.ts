/**
 * ClaudeAppServer — core logic.
 *
 * Uses your locally installed `claude` CLI (no API key required).
 * Each turn spawns:   claude --print --output-format stream-json --include-partial-messages
 * and parses the NDJSON event stream back into JSON-RPC 2.0 notifications.
 *
 * Claude session IDs tie turns together so the CLI can --resume conversations.
 *
 * Methods:
 *   Session:   initialize
 *   Threads:   thread/start  thread/resume  thread/fork
 *   Turns:     turn/start    turn/steer     turn/interrupt
 *   Discovery: model/list    skills/list    app/list
 *
 * Orchestrator-declared tools (thread/start `dynamicTools`) are served to the
 * claude subprocess through an in-process MCP bridge (see dynamic-tools.ts);
 * invocations round-trip to the client as item/tool/call JSON-RPC requests.
 */

import { execFile, execFileSync, spawn } from "child_process";
import * as os from "os";
import * as readline from "readline";
import { v4 as uuid } from "uuid";
import { fetchUtilization, type Utilization } from "./utilization.js";

// Resolve the full path to the claude binary once at startup so that spawn()
// can find it even when ~/.local/bin is not in the inherited PATH.
function resolveClaude(): string {
  for (const cmd of ["which", "/usr/bin/which"]) {
    try {
      return execFileSync(cmd, ["claude"], { encoding: "utf-8" }).trim();
    } catch { /* try next */ }
  }
  return "claude"; // fall back; spawn will throw a clear error if not found
}

const CLAUDE_BIN = resolveClaude();

import {
  ok, rpcErr, notif,
  isRequest, isResponse,
  E, RpcException,
  type RpcMessage,
  type RpcResponse,
} from "./protocol.js";
import type {
  ConnectionState, Thread, Turn, StoredItem, PermissionMode, DynamicToolSpec,
  AccountType, RateLimitStatus,
} from "./types.js";
import { BUILTIN_SKILLS } from "./tools.js";
import { DynamicToolBridge, PendingEngineCalls, parseDynamicTools } from "./dynamic-tools.js";

// ─── Helpers ──────────────────────────────────────────────────────────────────

/**
 * The CLI's error class for an assistant event it synthesized from an API
 * error, or undefined for text the model wrote.
 */
function providerErrorClass(event: { error?: unknown; is_api_error_message?: unknown }): string | undefined {
  if (typeof event.error === "string" && event.error !== "") return event.error;
  if (event.is_api_error_message === true) return "unknown";
  return undefined;
}

/** Provider messages are one-line banners; cap them so a runaway body can't bloat the wire. */
function boundedMessage(text: string): string {
  return text.slice(0, 500);
}

/** Flatten a StoredItem for notification: merge {id, created_at} with item contents. */
function flatItem(si: StoredItem): Record<string, unknown> {
  return { id: si.id, created_at: si.created_at, ...si.item };
}

/**
 * Extract the exact serialized decimal for a top-level numeric key from raw
 * JSON text, before JSON.parse rounds it through a JavaScript float.
 *
 * Scans the text tracking nesting depth and string state, so occurrences of
 * the key inside string values or nested objects are never matched.
 * Returns undefined if the key is absent or its value is not a plain number.
 */
export function extractTopLevelRawNumber(json: string, key: string): string | undefined {
  let depth = 0;
  let i = 0;
  const n = json.length;
  while (i < n) {
    const ch = json[i];
    if (ch === '"') {
      const start = i + 1;
      i++;
      let escaped = false;
      while (i < n) {
        const c = json[i];
        if (escaped) escaped = false;
        else if (c === "\\") escaped = true;
        else if (c === '"') break;
        i++;
      }
      const literal = json.slice(start, i);
      i++; // past closing quote
      if (depth === 1 && literal === key) {
        while (i < n && /\s/.test(json[i])) i++;
        if (json[i] !== ":") continue; // string value, not a key
        i++;
        while (i < n && /\s/.test(json[i])) i++;
        const m = /^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/.exec(json.slice(i));
        return m?.[0] || undefined;
      }
    } else if (ch === "{" || ch === "[") { depth++; i++; }
    else if (ch === "}" || ch === "]") { depth--; i++; }
    else i++;
  }
  return undefined;
}

/** Derive the account billing fact from the CLI init event's apiKeySource. */
export function accountTypeFromApiKeySource(source: string | undefined): AccountType {
  if (source === undefined) return "unknown";
  return source === "none" ? "subscription" : "api_key";
}

/**
 * Normalize a CLI utilization value to percent-of-quota USED (0–100 scale).
 * Values in [0, 1] are read as a used fraction and scaled by 100.
 */
export function normalizeUsedPercent(value: unknown): number | undefined {
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0 || value > 100) return undefined;
  return value <= 1 ? value * 100 : value;
}

const RATE_LIMIT_STATUSES = new Set<RateLimitStatus["status"]>([
  "allowed",
  "allowed_warning",
  "rejected",
]);

/**
 * Build the sanitized rate-limit event forwarded to the engine.
 *
 * Redaction is by construction: the output is assembled field-by-field from
 * an allowlist, so identifying data on the raw CLI event (org/account ids,
 * emails, tokens, session ids, headers) can never pass through.
 */
export function sanitizeRateLimit(
  info: RawRateLimitInfo | undefined,
  accountType: AccountType,
  sourceVersion: string,
  utilization?: Utilization,
): RateLimitStatus {
  const raw = info ?? {};
  // The CLI event carries no consumed fraction, so `utilization` — read from
  // the same `/api/oauth/usage` endpoint the TUI's `/usage` uses — supplies it.
  // A CLI-provided value still wins if one ever starts appearing.
  const usedPercent =
    normalizeUsedPercent(raw.utilization ?? raw.used_percent ?? raw.usedPercent) ?? utilization?.used_percent;
  const resetsAt = raw.resetsAt ?? raw.resets_at ?? utilization?.resets_at;
  const out: RateLimitStatus = {
    status: RATE_LIMIT_STATUSES.has(raw.status as RateLimitStatus["status"])
      ? raw.status as RateLimitStatus["status"]
      : "unknown",
    account_type: accountType,
    source_version: sourceVersion,
  };
  if (usedPercent !== undefined) out.used_percent = usedPercent;
  if (typeof resetsAt === "number" && Number.isFinite(resetsAt) && resetsAt >= 0) out.resets_at = resetsAt;
  return out;
}

// ─── Constants ────────────────────────────────────────────────────────────────

const SERVER_NAME    = "aiur-claude";
const SERVER_VERSION = "1.2.0";

const AVAILABLE_MODELS = [
  { id: "claude-opus-4-6",   name: "Claude Opus 4.6",   aliases: ["opus"] },
  { id: "claude-sonnet-4-6", name: "Claude Sonnet 4.6", aliases: ["sonnet"] },
  { id: "claude-haiku-4-5",  name: "Claude Haiku 4.5",  aliases: ["haiku"] },
];

// ─── Helpers ──────────────────────────────────────────────────────────────────

function createThread(cwd: string, permMode: PermissionMode): Thread {
  return { id: uuid(), created_at: Date.now(), turns: [], cwd, permission_mode: permMode };
}

function createTurn(threadId: string, userContent: string): Turn {
  return {
    id: uuid(),
    thread_id: threadId,
    status: "active",
    user_content: userContent,
    steer_queue: [],
    items: [],
    abortController: new AbortController(),
    created_at: Date.now(),
  };
}

function serializeTurn(turn: Turn) {
  return {
    id: turn.id, thread_id: turn.thread_id, status: turn.status,
    user_content: turn.user_content, items: turn.items,
    created_at: turn.created_at, completed_at: turn.completed_at, error: turn.error,
  };
}

// ─── ClaudeAppServer ─────────────────────────────────────────────────────────

export class ClaudeAppServer {
  private threads = new Map<string, Thread>();
  private claudePath: string;
  private debug: boolean;
  /** Pending server→client requests (dynamic tool round-trips). */
  private engineCalls = new PendingEngineCalls();
  /** claude CLI version (from `claude --version`), resolved once per server. */
  private sourceVersion?: string;

  /**
   * Reads current quota utilization. Injectable so tests never reach the
   * network: the default performs a real `/api/oauth/usage` request.
   */
  private readonly utilizationFetcher: () => Promise<Utilization | undefined>;

  constructor(
    claudePath: string,
    debug = false,
    utilizationFetcher: () => Promise<Utilization | undefined> = fetchUtilization,
  ) {
    this.claudePath = claudePath;
    this.debug = debug;
    this.utilizationFetcher = utilizationFetcher;
  }

  private log(...args: unknown[]): void {
    if (this.debug) process.stderr.write("[debug] " + args.join(" ") + "\n");
  }

  /** Resolve and cache the claude CLI version for source attribution. */
  private async resolveSourceVersion(): Promise<string> {
    if (this.sourceVersion === undefined) {
      this.sourceVersion = await new Promise<string>((resolve) => {
        execFile(this.claudePath, ["--version"], { encoding: "utf-8" }, (err, stdout) => {
          resolve(err ? "unknown" : stdout.trim() || "unknown");
        });
      });
    }
    return this.sourceVersion;
  }

  // ── Entry point ────────────────────────────────────────────────────────────

  async handleMessage(msg: RpcMessage, conn: ConnectionState): Promise<RpcResponse | null> {
    if (isResponse(msg)) {
      // Client answered a server-initiated request (e.g. item/tool/call).
      if (!this.engineCalls.handleResponse(msg)) {
        this.log(`unmatched response id: ${String(msg.id)}`);
      }
      return null;
    }
    if (!isRequest(msg)) return null;       // client notifications are ignored
    const { id, method, params } = msg;
    try {
      if (!conn.initialized && method !== "initialize") {
        throw new RpcException(E.NotInitialized, "Not initialized. Send initialize first.");
      }
      const result = await this.dispatch(method, params, conn);
      return ok(id, result);
    } catch (e) {
      if (e instanceof RpcException) return rpcErr(id, e.code, e.message, e.data);
      return rpcErr(id, E.InternalError, String(e));
    }
  }

  // ── Dispatcher ─────────────────────────────────────────────────────────────

  private async dispatch(method: string, params: unknown, conn: ConnectionState): Promise<unknown> {
    switch (method) {
      case "initialize":       return this.initialize(params, conn);
      case "thread/start":     return this.threadStart(params, conn);
      case "thread/resume":    return this.threadResume(params, conn);
      case "thread/fork":      return this.threadFork(params);
      case "turn/start":       return this.turnStart(params, conn);
      case "turn/steer":       return this.turnSteer(params);
      case "turn/interrupt":   return this.turnInterrupt(params);
      case "approval/respond": return this.approvalRespond(params);
      case "model/list":       return { models: AVAILABLE_MODELS };
      case "skills/list":      return { skills: BUILTIN_SKILLS };
      case "app/list":         return { apps: [] };
      default:
        throw new RpcException(E.MethodNotFound, `Unknown method: ${method}`);
    }
  }

  // ── initialize ─────────────────────────────────────────────────────────────

  private initialize(params: unknown, conn: ConnectionState): unknown {
    const p = (params ?? {}) as {
      client?: { name?: string; version?: string };
      clientInfo?: { name?: string; version?: string };
      cwd?: string;
    };
    const client = p.clientInfo ?? p.client;
    conn.initialized = true;
    conn.client_info = { name: client?.name ?? "unknown", version: client?.version ?? "0.0.0" };
    setImmediate(() => conn.send(notif("initialized", { server: SERVER_NAME })));
    return {
      server: { name: SERVER_NAME, version: SERVER_VERSION },
      capabilities: {
        threads:  ["start", "resume", "fork"],
        turns:    ["start", "steer", "interrupt"],
        models:   AVAILABLE_MODELS.map(m => m.id),
        skills:   BUILTIN_SKILLS.map(s => s.name),
        dynamicTools: true,
      },
    };
  }

  // ── thread/start ───────────────────────────────────────────────────────────

  private threadStart(params: unknown, conn: ConnectionState): unknown {
    const p = (params ?? {}) as {
      cwd?: string;
      permission_mode?: PermissionMode; permissionMode?: PermissionMode;
      dynamicTools?: unknown; dynamic_tools?: unknown;
    };
    let cwd = p.cwd ?? process.cwd();
    // Expand ~ to the user's home directory (Node spawn doesn't do this)
    if (cwd === "~") cwd = os.homedir();
    else if (cwd.startsWith("~/")) cwd = os.homedir() + cwd.slice(1);
    // Accept both snake_case and camelCase for Codex protocol compatibility
    const permMode = p.permissionMode ?? p.permission_mode ?? "default";
    const dynamicTools = parseDynamicTools(p.dynamicTools ?? p.dynamic_tools);
    const thread = createThread(cwd, permMode);
    if (dynamicTools.length > 0) {
      thread.dynamicTools = dynamicTools;
      thread.toolBridge = this.createBridge(dynamicTools, conn);
    }
    this.threads.set(thread.id, thread);
    // Report standing as soon as the thread exists. The CLI only emits
    // `rate_limit_event` partway through a turn, which left a caller unable to
    // learn where the account stands without first spending quota — exactly
    // backwards for something used to decide whether to spend it. The usage
    // endpoint needs no turn, so answer immediately and let the in-turn event
    // refresh it later.
    void this.emitUtilizationSnapshot(thread, conn);
    // Return nested format for Codex protocol compatibility
    return { thread: { id: thread.id, created_at: thread.created_at } };
  }

  /**
   * Fetch utilization and publish it as a `rate_limit/update`, with no turn.
   *
   * Failure is silent by design: no credentials, an expired token, an offline
   * machine, or an API-key account all land here, and none of them should
   * disturb a thread that is otherwise fine.
   */
  /** Forward an in-turn rate-limit event, enriched with current utilization. */
  private async emitRateLimitUpdate(
    info: RawRateLimitInfo | undefined,
    thread: Thread,
    turn: Turn,
    conn: ConnectionState,
  ): Promise<void> {
    try {
      const utilization = await this.utilizationFetcher();
      conn.send(notif("rate_limit/update", {
        turn_id:    turn.id,
        thread_id:  thread.id,
        rate_limit: sanitizeRateLimit(info, thread.accountType ?? "unknown", this.sourceVersion ?? "unknown", utilization),
      }));
    } catch {
      // A quota reading must never break a turn.
    }
  }

  private async emitUtilizationSnapshot(thread: Thread, conn: ConnectionState): Promise<void> {
    try {
      const utilization = await this.utilizationFetcher();
      if (!utilization) return;

      conn.send(notif("rate_limit/update", {
        thread_id: thread.id,
        rate_limit: sanitizeRateLimit(
          { status: "allowed" },
          thread.accountType ?? "unknown",
          await this.resolveSourceVersion(),
          utilization,
        ),
      }));
    } catch {
      // Never let a quota reading break a thread.
    }
  }

  // ── thread/resume ──────────────────────────────────────────────────────────

  private threadResume(params: unknown, conn: ConnectionState): unknown {
    const { threadId: sessionId, cwd, permissionMode, dynamicTools } = this.resumeThreadParams(params);
    if (!sessionId) throw new RpcException(E.InvalidParams, "thread_id or threadId is required");
    const existing = this.threads.get(sessionId);
    if (existing) {
      existing.toolBridge?.close();
      existing.dynamicTools = dynamicTools.length > 0 ? dynamicTools : undefined;
      existing.toolBridge = dynamicTools.length > 0 ? this.createBridge(dynamicTools, conn) : undefined;
      return this.serializeResumedThread(existing);
    }

    // The thread map is process-local. Rebuild the wrapper from the durable
    // CLI session id so a new app-server process (and CLAUDE_CONFIG_DIR) can
    // resume the transcript with `claude --resume <id>` on the next turn.
    const thread = createThread(cwd, permissionMode);
    thread.id = sessionId;
    thread.cliSessionId = sessionId;
    if (dynamicTools.length > 0) {
      thread.dynamicTools = dynamicTools;
      thread.toolBridge = this.createBridge(dynamicTools, conn);
    }
    this.threads.set(thread.id, thread);
    return this.serializeResumedThread(thread);
  }

  private resumeThreadParams(params: unknown): {
    threadId: string; cwd: string; permissionMode: PermissionMode; dynamicTools: DynamicToolSpec[];
  } {
    const p = params as {
      thread_id?: string; threadId?: string; cwd?: string;
      permission_mode?: PermissionMode; permissionMode?: PermissionMode;
      dynamicTools?: unknown; dynamic_tools?: unknown;
    };
    const threadId = p.threadId ?? p.thread_id ?? "";
    if (!threadId) throw new RpcException(E.InvalidParams, "thread_id or threadId is required");
    let cwd = p.cwd ?? process.cwd();
    if (cwd === "~") cwd = os.homedir();
    else if (cwd.startsWith("~/")) cwd = os.homedir() + cwd.slice(1);
    const permissionMode = p.permissionMode ?? p.permission_mode ?? "default";
    const dynamicTools = parseDynamicTools(p.dynamicTools ?? p.dynamic_tools);
    return { threadId, cwd, permissionMode, dynamicTools };
  }

  private serializeResumedThread(thread: Thread) {
    return { thread: {
      id:              thread.id,
      created_at:      thread.created_at,
      cwd:             thread.cwd,
      permission_mode: thread.permission_mode,
      cli_session_id:  thread.cliSessionId,
      turns:           thread.turns.map(serializeTurn),
    } };
  }

  // ── thread/fork ────────────────────────────────────────────────────────────

  private threadFork(params: unknown): unknown {
    const p = params as { thread_id?: string; threadId?: string };
    const src = this.getThread(p.threadId ?? p.thread_id ?? "");

    if (!src.cliSessionId) {
      throw new RpcException(E.InvalidParams ?? -32602,
        "Cannot fork a thread that has no turns yet.");
    }

    // Create new thread that will fork the source session on its first turn
    const forked = createThread(src.cwd, src.permission_mode);
    forked.forkFrom = { cliSessionId: src.cliSessionId };
    if (src.dynamicTools && src.dynamicTools.length > 0) {
      forked.dynamicTools = src.dynamicTools;
      forked.toolBridge = this.createBridge(src.dynamicTools);
    }
    this.threads.set(forked.id, forked);

    return { thread: { id: forked.id, forked_from: src.id, created_at: forked.created_at } };
  }

  // ── turn/start ─────────────────────────────────────────────────────────────

  private async turnStart(params: unknown, conn: ConnectionState): Promise<unknown> {
    const p = params as {
      thread_id?: string; threadId?: string;
      content?: string; input?: Array<{ type: string; text: string }>;
      model?: string; title?: string;
    };
    // Accept both snake_case and camelCase for Codex protocol compatibility
    const threadId = p.threadId ?? p.thread_id;
    if (!threadId) throw new RpcException(E.InvalidParams, "thread_id or threadId is required");
    const thread = this.getThread(threadId);

    if (thread.active_turn_id) {
      throw new RpcException(E.TurnBusy, "Thread already has an active turn. Interrupt it first.");
    }

    // Accept both plain string `content` and Codex-style `input` array
    let userContent = p.content;
    if (!userContent && Array.isArray(p.input)) {
      userContent = p.input
        .filter(i => i.type === "text")
        .map(i => i.text)
        .join("\n");
    }
    if (!userContent) throw new RpcException(E.InvalidParams, "content or input is required");

    const turn = createTurn(thread.id, userContent);

    // Prepend any queued steer content from the last completed turn
    if (turn.steer_queue.length > 0) {
      turn.user_content = turn.steer_queue.join("\n\n") + "\n\n" + turn.user_content;
      turn.steer_queue = [];
    }

    thread.turns.push(turn);
    thread.active_turn_id = turn.id;

    setImmediate(() => {
      conn.send(notif("turn/started", { turn_id: turn.id, thread_id: thread.id }));
      this.runClaudeTurn(thread, turn, conn, p.model).catch((err: unknown) => {
        turn.status = "error";
        turn.error = String(err);
        turn.completed_at = Date.now();
        thread.active_turn_id = undefined;
        conn.send(notif("turn/failed", {
          turn_id: turn.id,
          error: String(err),
          // Provenance: only the CLI's own API-error events set this, never
          // assistant prose that happens to repeat a refusal.
          ...(turn.provider_error ? { provider_error: turn.provider_error } : {}),
        }));
      });
    });

    // Return nested format for Codex protocol compatibility
    return { turn: { id: turn.id } };
  }

  // ── turn/steer ─────────────────────────────────────────────────────────────

  private turnSteer(params: unknown): unknown {
    const p = params as { thread_id?: string; threadId?: string; content: string };
    const thread = this.getThread(p.threadId ?? p.thread_id ?? "");

    // Queue for the next turn (active turn's queue, or thread-level queue)
    if (thread.active_turn_id) {
      const turn = thread.turns.find(t => t.id === thread.active_turn_id)!;
      turn.steer_queue.push(p.content);
      return { turn_id: turn.id, note: "queued: will be prepended to the next user message" };
    }

    throw new RpcException(E.NoActiveTurn, "No active turn to steer.");
  }

  // ── turn/interrupt ─────────────────────────────────────────────────────────

  private turnInterrupt(params: unknown): unknown {
    const p = params as { thread_id?: string; threadId?: string };
    const thread = this.getThread(p.threadId ?? p.thread_id ?? "");

    if (!thread.active_turn_id) {
      throw new RpcException(E.NoActiveTurn, "No active turn to interrupt.");
    }

    const turn = thread.turns.find(t => t.id === thread.active_turn_id)!;
    turn.abortController.abort();

    // SIGTERM the claude subprocess if it's running
    if (turn.process) {
      turn.process.kill("SIGTERM");
    }

    turn.status = "interrupted";
    turn.completed_at = Date.now();
    thread.active_turn_id = undefined;

    return { turn_id: turn.id, status: "interrupted" };
  }

  // ── approval/respond ───────────────────────────────────────────────────────

  private approvalRespond(params: unknown): unknown {
    const p = params as {
      thread_id?: string; threadId?: string;
      approved: boolean;
      permission_mode?: PermissionMode; permissionMode?: PermissionMode;
    };
    const thread = this.getThread(p.threadId ?? p.thread_id ?? "");

    if (p.approved) {
      // Upgrade the thread's permission mode for all subsequent turns.
      // Caller can specify exactly which mode; default to "acceptEdits" which
      // auto-approves file writes/edits but still guards arbitrary shell commands.
      thread.permission_mode = p.permissionMode ?? p.permission_mode ?? "acceptEdits";
    }

    return {
      thread_id:       thread.id,
      approved:        p.approved,
      permission_mode: thread.permission_mode,
      note: p.approved
        ? `Permission mode updated to "${thread.permission_mode}". Retry your turn/start.`
        : "Approval denied. Permission mode unchanged.",
    };
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Claude subprocess runner
  // ─────────────────────────────────────────────────────────────────────────

  private async runClaudeTurn(
    thread: Thread,
    turn: Turn,
    conn: ConnectionState,
    model?: string,
  ): Promise<void> {
    // Serve orchestrator-declared tools to this turn's claude subprocess and
    // route their invocations back over the connection that started the turn.
    if (thread.toolBridge) {
      thread.toolBridge.bindConnection(conn);
      await thread.toolBridge.start();
    }

    await this.resolveSourceVersion();

    const args = this.buildClaudeArgs(thread, model);
    this.log(`spawn: ${this.claudePath} ${args.join(" ")}`);
    this.log(`cwd: ${thread.cwd}`);

    const proc = spawn(this.claudePath, args, {
      cwd:   thread.cwd,
      stdio: ["pipe", "pipe", "pipe"],
      env:   { ...process.env, CLAUDECODE: undefined } as NodeJS.ProcessEnv,
    });
    turn.process = proc;

    // Register exit/error promise BEFORE reading stdout so we never miss
    // early events (e.g. spawn failures where 'error' fires immediately).
    let spawnError: Error | undefined;
    const exitPromise = new Promise<number | null>((resolve) => {
      proc.on("exit", (code) => { this.log(`exit code: ${code}`); resolve(code); });
      proc.on("error", (err: Error) => {
        this.log(`proc error: ${err}`);
        spawnError = err;
        resolve(null);
      });
    });

    // Write user content to stdin, then close it
    const stdinContent = turn.user_content;
    this.log(`stdin: ${JSON.stringify(stdinContent)}`);
    try {
      proc.stdin.write(stdinContent, "utf-8");
      proc.stdin.end();
    } catch {
      // stdin may be unusable if spawn failed; ignore
    }

    // Capture stderr for error reporting
    let stderrBuf = "";
    proc.stderr?.on("data", (d: Buffer) => {
      const text = d.toString();
      stderrBuf += text;
      this.log(`stderr: ${text.trimEnd()}`);
    });

    // Abort → kill the subprocess
    turn.abortController.signal.addEventListener("abort", () => {
      proc.kill("SIGTERM");
    }, { once: true });

    // Parse stdout as NDJSON events
    const rl = readline.createInterface({ input: proc.stdout, terminal: false });

    // Track partial message text to compute deltas
    const partialText = new Map<string, string>();   // messageId → accumulated text
    const partialThink = new Map<string, string>();  // messageId → accumulated thinking

    for await (const line of rl) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      this.log(`stdout: ${trimmed}`);

      let event: ClaudeStreamEvent;
      try { event = JSON.parse(trimmed) as ClaudeStreamEvent; } catch { continue; }

      this.processClaudeEvent(event, thread, turn, conn, partialText, partialThink, trimmed);
    }

    // Wait for process to exit (listeners already registered above)
    const exitCode = await exitPromise;

    // Treat 0 and 130 (SIGINT) as OK; spawn errors and non-zero exits are failures
    const aborted = turn.abortController.signal.aborted;
    if (!aborted && spawnError) {
      throw new Error(
        `Failed to spawn claude: ${spawnError.message}` +
        (stderrBuf ? `\nstderr: ${stderrBuf.slice(0, 500)}` : "")
      );
    }
    if (!aborted && exitCode !== null && exitCode !== 0 && exitCode !== 130) {
      throw new Error(
        `claude exited with code ${exitCode}` +
        (stderrBuf ? `\nstderr: ${stderrBuf.slice(0, 500)}` : "")
      );
    }

    turn.status       = aborted ? "interrupted" : "completed";
    turn.completed_at = Date.now();
    thread.active_turn_id = undefined;

    // Build usage with computed total_tokens for the orchestrator
    const usagePayload = turn.usage ? {
      ...turn.usage,
      total_tokens: (turn.usage.input_tokens ?? 0)
                  + (turn.usage.output_tokens ?? 0)
                  + (turn.usage.cache_read_input_tokens ?? 0)
                  + (turn.usage.cache_creation_input_tokens ?? 0),
    } : undefined;

    conn.send(notif("turn/completed", {
      turn_id:      turn.id,
      thread_id:    thread.id,
      status:       turn.status,
      items_count:  turn.items.length,
      completed_at: turn.completed_at,
      ...(usagePayload  ? { usage: usagePayload }     : {}),
      ...(turn.cost_usd != null ? { cost_usd: turn.cost_usd } : {}),
      // Exact decimal + source version so the engine can do precise accounting;
      // cost_usd above stays float-converted for backward compatibility.
      ...(turn.cost_usd_raw != null ? { cost_usd_raw: turn.cost_usd_raw } : {}),
      ...(turn.cost_usd != null ? { cost_source_version: this.sourceVersion ?? "unknown" } : {}),
    }));
  }

  // ── Build claude args ──────────────────────────────────────────────────────

  private buildClaudeArgs(thread: Thread, model?: string): string[] {
    const args = [
      "--print",
      "--output-format", "stream-json",
      "--verbose",
      "--include-partial-messages",
      "--permission-mode", thread.permission_mode,
    ];

    if (model) args.push("--model", model);

    // Expose dynamic tools via the in-process MCP bridge. Allowlist each
    // mcp__aiur__<name> so calls run headless under every permission mode.
    if (thread.toolBridge?.socketPath) {
      args.push("--mcp-config", thread.toolBridge.mcpConfig());
      args.push("--allowedTools", thread.toolBridge.allowedTools());
    }

    if (thread.forkFrom && !thread.cliSessionId) {
      // First turn of a forked thread: resume source and fork
      args.push("--resume", thread.forkFrom.cliSessionId, "--fork-session");
    } else if (!thread.cliSessionId) {
      // First turn of a brand-new thread: create session with our thread id
      args.push("--session-id", thread.id);
    } else {
      // Subsequent turns: resume the existing session
      args.push("--resume", thread.cliSessionId);
    }

    return args;
  }

  // ── Process a single stream-json event ────────────────────────────────────

  private processClaudeEvent(
    event: ClaudeStreamEvent,
    thread: Thread,
    turn: Turn,
    conn: ConnectionState,
    partialText:  Map<string, string>,
    partialThink: Map<string, string>,
    rawLine?: string,
  ): void {
    switch (event.type) {

      // ── system/init ─────────────────────────────────────────────────────
      case "system": {
        if (event.subtype === "init") {
          if (event.session_id) thread.cliSessionId = event.session_id;
          thread.accountType = accountTypeFromApiKeySource(event.apiKeySource);
        }
        break;
      }

      // ── assistant message ────────────────────────────────────────────────
      case "assistant": {
        const msg    = event.message;
        const msgId  = msg.id ?? "unknown";
        const partial = !!event.is_partial;
        // The CLI marks text it synthesized from an API error (session limit,
        // unknown model, ...) with `is_api_error_message` and an `error` class.
        const apiError = providerErrorClass(event);

        for (const block of (msg.content ?? [])) {

          if (block.type === "text") {
            const prev  = partialText.get(msgId) ?? "";
            const delta = block.text.slice(prev.length);

            if (delta) {
              // Stream delta to client
              conn.send(notif("item/progress", {
                turn_id: turn.id,
                delta:   { type: "text", text: delta },
              }));
              partialText.set(msgId, block.text);
            }

            if (!partial) {
              // Final version: persist as a complete item
              const item: StoredItem = {
                id: uuid(), created_at: Date.now(),
                item: apiError
                  ? { type: "text", text: block.text, provider_error: apiError }
                  : { type: "text", text: block.text },
              };
              turn.items.push(item);
              conn.send(notif("item/created", { turn_id: turn.id, item: flatItem(item) }));
              partialText.delete(msgId);
              if (apiError) {
                turn.provider_error = {
                  ...turn.provider_error,
                  error: apiError,
                  message: boundedMessage(block.text),
                };
              }
            }

          } else if (block.type === "thinking" && !partial) {
            const prevThink  = partialThink.get(msgId) ?? "";
            const thinkDelta = block.thinking.slice(prevThink.length);
            if (thinkDelta) {
              conn.send(notif("item/progress", {
                turn_id: turn.id,
                delta:   { type: "thinking", thinking: thinkDelta },
              }));
            }
            const item: StoredItem = {
              id: uuid(), created_at: Date.now(),
              item: { type: "thinking", thinking: block.thinking },
            };
            turn.items.push(item);
            conn.send(notif("item/created", { turn_id: turn.id, item: flatItem(item) }));
            partialThink.delete(msgId);

          } else if (block.type === "tool_use" && !partial) {
            const item: StoredItem = {
              id: uuid(), created_at: Date.now(),
              item: {
                type: "tool_call",
                tool_use_id: block.id,
                name: block.name,
                input: block.input,
              },
            };
            turn.items.push(item);
            conn.send(notif("item/created", { turn_id: turn.id, item: flatItem(item) }));
          }
        }
        break;
      }

      // ── user message (tool results) ──────────────────────────────────────
      case "user": {
        for (const block of (event.message?.content ?? [])) {
          if (block.type === "tool_result") {
            const rawContent = block.content;
            const content = Array.isArray(rawContent)
              ? rawContent.map((c: { text?: string }) => c.text ?? "").join("")
              : String(rawContent ?? "");

            const item: StoredItem = {
              id: uuid(), created_at: Date.now(),
              item: {
                type:        "tool_result",
                tool_use_id: block.tool_use_id,
                content,
                is_error:    !!block.is_error,
              },
            };
            turn.items.push(item);
            conn.send(notif("item/created", { turn_id: turn.id, item: flatItem(item) }));
          }
        }
        break;
      }

      // ── stream_event (granular streaming — usage comes via message_delta) ─
      case "stream_event": {
        const inner = event.event;
        if (inner.type === "message_delta" && inner.usage) {
          // Accumulate usage — message_delta carries cumulative totals per message
          turn.usage = inner.usage;
          const total_tokens = (inner.usage.input_tokens ?? 0)
                             + (inner.usage.output_tokens ?? 0)
                             + (inner.usage.cache_read_input_tokens ?? 0)
                             + (inner.usage.cache_creation_input_tokens ?? 0);
          conn.send(notif("usage/update", {
            turn_id:   turn.id,
            thread_id: thread.id,
            usage:     { ...inner.usage, total_tokens },
          }));
        }
        break;
      }

      // ── rate_limit_event (sanitized + forwarded) ─────────────────────────
      case "rate_limit_event": {
        // The event supplies the standing; the usage endpoint supplies the
        // consumed fraction the event has never carried. Fetching is async and
        // this handler is not, so the send is deferred rather than blocking
        // stream processing behind a network call.
        void this.emitRateLimitUpdate(event.rate_limit_info ?? event.rateLimitInfo, thread, turn, conn);
        break;
      }

      // ── result (turn complete) ───────────────────────────────────────────
      case "result": {
        // session_id may be updated (e.g. after a fork)
        if (event.session_id) thread.cliSessionId = event.session_id;

        if (event.subtype === "error") {
          turn.status = "error";
          turn.error  = event.error ?? "unknown error";
        }

        // An API-error result (is_error with an HTTP status, or the CLI's
        // "api_error" terminal reason) confirms the refusal and carries its
        // status. Other is_error results (max turns, execution errors) are not
        // provider refusals and stay untagged.
        if (event.is_error === true &&
            (typeof event.api_error_status === "number" || event.terminal_reason === "api_error" || turn.provider_error)) {
          const status  = typeof event.api_error_status === "number" ? event.api_error_status : undefined;
          const message = turn.provider_error?.message ??
            (typeof event.result === "string" ? boundedMessage(event.result) : undefined);
          turn.provider_error = {
            error: turn.provider_error?.error ?? (status === 429 ? "rate_limit" : "unknown"),
            ...(status  !== undefined ? { api_error_status: status } : {}),
            ...(message !== undefined ? { message } : {}),
          };
        }

        // Capture token usage and cost (if result arrives before process is killed)
        if (event.usage)  turn.usage    = event.usage;
        const costKey =
          event.total_cost_usd != null ? "total_cost_usd" :
          event.cost_usd       != null ? "cost_usd"       : undefined;
        if (costKey) {
          turn.cost_usd = event[costKey];
          // Exact decimal as serialized by the CLI, captured before float
          // conversion; guarded so it always round-trips to the same float.
          const raw = rawLine ? extractTopLevelRawNumber(rawLine, costKey) : undefined;
          if (raw !== undefined && Number(raw) === turn.cost_usd) turn.cost_usd_raw = raw;
        }

        // Forward permission denials so the client can show approval UI
        if (event.permission_denials && event.permission_denials.length > 0) {
          conn.send(notif("turn/permission_denied", {
            turn_id:    turn.id,
            thread_id:  thread.id,
            denials:    event.permission_denials,
          }));
        }
        break;
      }
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Helpers
  // ─────────────────────────────────────────────────────────────────────────

  private getThread(id: string): Thread {
    const t = this.threads.get(id);
    if (!t) throw new RpcException(E.ThreadNotFound, `Thread not found: ${id}`);
    return t;
  }

  private createBridge(tools: DynamicToolSpec[], conn?: ConnectionState): DynamicToolBridge {
    const bridge = new DynamicToolBridge(tools, this.engineCalls, {
      log: (msg) => this.log(msg),
    });
    if (conn) bridge.bindConnection(conn);
    return bridge;
  }
}

// ─── stream-json event types (from claude --output-format stream-json) ────────

type ClaudeContentBlock =
  | { type: "text";        text: string }
  | { type: "thinking";    thinking: string }
  | { type: "tool_use";    id: string; name: string; input?: unknown }
  | { type: "tool_result"; tool_use_id: string; content?: unknown; is_error?: boolean };

interface ClaudeMessage {
  id?: string;
  role?: string;
  content?: ClaudeContentBlock[];
}

interface ClaudeUsage {
  input_tokens?: number;
  output_tokens?: number;
  cache_read_input_tokens?: number;
  cache_creation_input_tokens?: number;
}

/**
 * Rate-limit payload shapes emitted by claude CLI versions: snake_case or
 * camelCase wrapper key, fraction or percent utilization, either reset key.
 * All shapes normalize into the one RateLimitStatus schema.
 */
export interface RawRateLimitInfo {
  status?: string;
  utilization?: number;
  used_percent?: number;
  usedPercent?: number;
  resetsAt?: number;
  resets_at?: number;
}

type ClaudeStreamEvent =
  | { type: "system";       subtype: string; session_id?: string; cwd?: string; tools?: string[]; model?: string; permissionMode?: string; apiKeySource?: string }
  | { type: "assistant";    message: ClaudeMessage; is_partial?: boolean; session_id?: string; error?: string; is_api_error_message?: boolean }
  | { type: "user";         message: ClaudeMessage; session_id?: string }
  | { type: "result";       subtype: string; session_id?: string; error?: string; result?: string; cost_usd?: number; total_cost_usd?: number; is_error?: boolean; api_error_status?: number | null; terminal_reason?: string; permission_denials?: { tool_name: string; tool_use_id: string; tool_input?: unknown }[]; usage?: ClaudeUsage; duration_ms?: number; model?: string; num_turns?: number }
  | { type: "stream_event"; event: { type: string; usage?: ClaudeUsage; delta?: unknown }; session_id?: string }
  | { type: "rate_limit_event"; rate_limit_info?: RawRateLimitInfo; rateLimitInfo?: RawRateLimitInfo; session_id?: string };
