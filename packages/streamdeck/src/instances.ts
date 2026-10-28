import { readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";

export interface InstanceTarget {
  name: string;
  baseUrl: string;
  auth: { token?: string; username?: string; password?: string } | { token_file: string } | { token_env: string };
}

const invalid = (): never => { throw new Error("Invalid remote-instances.yaml registry"); };

// Match remote.sh's deliberately small YAML subset; no aliases, tags or escapes.
export const parseInstances = (text: string): InstanceTarget[] => {
  const entries: InstanceTarget[] = [];
  const names = new Set<string>();
  let version = false;
  let instances = false;
  let fields: Record<string, string> | null = null;
  let name = "";
  const finish = (): void => {
    if (fields === null) return;
    if (!fields.url || Boolean(fields.token_file) === Boolean(fields.token_env)) invalid();
    entries.push({ name, baseUrl: fields.url, auth: fields.token_file ? { token_file: fields.token_file } : { token_env: fields.token_env! } });
    fields = null;
  };
  for (const raw of text.split(/\r?\n/)) {
    if (raw.includes("\t")) invalid();
    if (/^\s*(#.*)?$/.test(raw)) continue;
    if (/^version:/.test(raw)) {
      finish();
      if (version || scalar(raw.slice(8)) !== "1") invalid();
      version = true;
    } else if (/^instances:\s*(#.*)?$/.test(raw)) {
      finish();
      if (instances) invalid();
      instances = true;
    } else if (/^ {2}[A-Za-z0-9._-]+:\s*(#.*)?$/.test(raw)) {
      finish();
      name = raw.trim().split(":")[0]!;
      if (!instances || ["all", "local", ".", ".."].includes(name) || names.has(name)) invalid();
      names.add(name);
      fields = {};
    } else {
      const match = /^ {4}(url|token_file|token_env):\s*(.*)$/.exec(raw);
      if (!match || fields === null || fields[match[1]!] !== undefined) invalid();
      fields![match![1]!] = scalar(match![2]!);
    }
  }
  finish();
  if (!version || !instances) invalid();
  return entries;
};

const scalar = (raw: string): string => {
  let value = raw.trim();
  if (/^["']/.test(value)) {
    const quote = value[0]!;
    if (!value.endsWith(quote) || value.length < 2) invalid();
    value = value.slice(1, -1);
    if (value.includes(quote) || value.includes("\\")) invalid();
  } else value = value.replace(/\s+#.*$/, "").trim();
  if (!value || value === "~" || value === "null" || /^[[{&*!|>]/.test(value)) invalid();
  return value;
};

export const validateInstanceUrl = (raw: string): string => {
  let url: URL;
  try { url = new URL(raw); } catch { throw new Error("Instance URL must be HTTPS or loopback HTTP"); }
  const host = url.hostname.toLowerCase();
  const loopback = host === "localhost" || host === "[::1]" || /^127\.\d+\.\d+\.\d+$/.test(host);
  if (url.username || url.password || url.search || url.hash || url.pathname !== "/" ||
    (url.protocol !== "https:" && !(url.protocol === "http:" && loopback))) {
    throw new Error("Instance URL must be HTTPS or loopback HTTP");
  }
  return url.origin;
};

export const resolveInstance = (target: InstanceTarget, home = homedir(), env = process.env): InstanceTarget & { auth: { token?: string; username?: string; password?: string } } => {
  // The environment daemon predates the registry and accepts HTTP/path prefixes.
  let baseUrl: string;
  if (target.name === "local") {
    try {
      const url = new URL(target.baseUrl);
      if (url.protocol !== "http:" && url.protocol !== "https:") throw new Error();
      baseUrl = target.baseUrl;
    } catch { throw new Error("Invalid AIUR_PHOENIX_URL"); }
  } else baseUrl = validateInstanceUrl(target.baseUrl);
  const auth = target.auth;
  if (!("token_file" in auth) && !("token_env" in auth)) return { ...target, baseUrl, auth };
  let token: string;
  if ("token_env" in auth) {
    if (!/^AIUR_TOKEN_[A-Za-z0-9_]+$/.test(auth.token_env)) throw new Error("token_env must name an AIUR_TOKEN_* variable");
    token = env[auth.token_env] ?? "";
  } else {
    const file = auth.token_file.startsWith("~/") ? path.join(home, auth.token_file.slice(2)) : auth.token_file;
    if (!path.isAbsolute(file)) throw new Error("token_file must be absolute or start with ~/");
    try {
      const stat = statSync(file);
      if (!stat.isFile() || (stat.mode & 0o7777) !== 0o600) throw new Error();
      token = readFileSync(file, "utf8").replace(/\n+$/, "");
    } catch { throw new Error("token_file must be readable with mode 0600"); }
  }
  if (!/^[A-Za-z0-9._~+/=-]+$/.test(token)) throw new Error("Instance token is empty or not bearer-safe");
  return { ...target, baseUrl, auth: { token } };
};

export const loadInstances = (local: InstanceTarget, home = homedir()): { targets: InstanceTarget[]; error?: string } => {
  try { return { targets: [local, ...parseInstances(readFileSync(path.join(home, ".aiur/remote-instances.yaml"), "utf8"))] }; }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return { targets: [local] };
    return { targets: [local], error: "Invalid or unreadable remote-instances.yaml" };
  }
};
