// Pure decision logic for the nightly release. No I/O here, so every rule the
// release depends on (which date, which version, which packages, is main green)
// is testable without git, GitHub, or a clock.

export const KINDS = new Set(["dispatch", "docker", "git-tag"]);
const NAME_RE = /^[a-z0-9][a-z0-9_.-]*$/;
const SHA_RE = /^[0-9a-f]{40}$/;

// The calendar date in `timeZone`, as YYYYMMDD. Intl applies the zone's DST
// rules, so 07:30Z is the next local day under PDT and the same day under PST.
export function localDate(now, timeZone) {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(now);
  const get = (type) => parts.find((p) => p.type === type).value;
  return `${get("year")}${get("month")}${get("day")}`;
}

// First `version: "x"` (mix.exs) or `"version": "x"` (package.json) in a file.
export function readBaseVersion(text) {
  const match = text.match(/"?version"?\s*:\s*"([^"]+)"/);
  if (!match) throw new Error("no version field found");
  return match[1];
}

export function renderVersion(template, { base, date, sha }) {
  return template
    .replaceAll("{base}", base)
    .replaceAll("{date}", date)
    .replaceAll("{sha7}", sha.slice(0, 7));
}

export const packageTag = (name, date) => `nightly/${name}/${date}`;
export const dayTag = (date) => `nightly-${date}`;

// The newest nightly tag of `name` strictly before `date`. Tags sort by their
// YYYYMMDD suffix, so a string compare is a date compare.
export function lastPackageTag(tags, name, date) {
  const prefix = `nightly/${name}/`;
  return (
    tags
      .filter((t) => t.startsWith(prefix) && /^\d{8}$/.test(t.slice(prefix.length)))
      .filter((t) => t.slice(prefix.length) < date)
      .sort()
      .at(-1) ?? null
  );
}

// Main is green for `sha` when the newest `push` run of every required workflow
// at that sha concluded `success`. A newer red push run outranks an older green
// one. Scheduled and manual runs neither block nor decide the nightly.
// `runsByWorkflow` maps workflow file -> runs as returned by the Actions API.
export function greenState(runsByWorkflow) {
  let pending = false;
  for (const [workflow, runs] of Object.entries(runsByWorkflow)) {
    const newest = runs.filter((r) => r.event === "push").sort((a, b) => b.created_at.localeCompare(a.created_at))[0];
    if (!newest) return { state: "none", reason: `${workflow}: no push run for this sha` };
    if (newest.status !== "completed") {
      pending = true;
      continue;
    }
    if (newest.conclusion !== "success") {
      return { state: "red", reason: `${workflow}: ${newest.conclusion} (${newest.html_url})` };
    }
  }
  return pending ? { state: "pending", reason: "a required workflow is still running" } : { state: "green", reason: "all required workflows passed" };
}

export function validateConfig(config) {
  const errors = [];
  if (!config.timezone) errors.push("timezone is required");
  if (!config.branch) errors.push("branch is required");
  if (!Array.isArray(config.required_workflows) || config.required_workflows.length === 0) {
    errors.push("required_workflows must list at least one workflow file");
  }
  if (!Array.isArray(config.packages)) errors.push("packages must be a list");
  const seen = new Set();
  for (const [i, pkg] of (config.packages ?? []).entries()) {
    const where = `packages[${i}]${pkg.name ? ` (${pkg.name})` : ""}`;
    if (!NAME_RE.test(pkg.name ?? "")) errors.push(`${where}: name must match ${NAME_RE}`);
    if (seen.has(pkg.name)) errors.push(`${where}: duplicate name`);
    seen.add(pkg.name);
    if (!KINDS.has(pkg.kind)) errors.push(`${where}: kind must be one of ${[...KINDS].join(", ")}`);
    if (!Array.isArray(pkg.paths) || pkg.paths.length === 0) errors.push(`${where}: paths must be non-empty`);
    if (!pkg.version_file) errors.push(`${where}: version_file is required`);
    if (pkg.kind === "dispatch" && !pkg.workflow) errors.push(`${where}: dispatch needs workflow`);
    if (pkg.kind === "docker" && !pkg.image) errors.push(`${where}: docker needs image`);
  }
  return errors;
}

export function assertSha(sha) {
  if (!SHA_RE.test(sha ?? "")) throw new Error(`not a 40-char commit sha: ${sha}`);
  return sha;
}

// Decide, per package, whether tonight releases it.
//   git.changed(fromTag, sha, paths) -> boolean (true when fromTag is not an
//   ancestor of sha, so a rewritten history still releases)
export function planPackages({ config, tags, date, sha, git, baseVersion }) {
  return config.packages.map((pkg) => {
    const tag = packageTag(pkg.name, date);
    const base = baseVersion(pkg.version_file);
    const version = renderVersion(pkg.version ?? "{base}-nightly.{date}", { base, date, sha });
    const previous = lastPackageTag(tags, pkg.name, date);
    const entry = { pkg, tag, version, previous };
    if (tags.includes(tag)) return { ...entry, action: "skip", reason: `already released today (${tag})` };
    if (previous && !git.changed(previous, sha, pkg.paths)) {
      return { ...entry, action: "skip", reason: `no change under ${pkg.paths.join(", ")} since ${previous}` };
    }
    return { ...entry, action: "release", reason: previous ? `changed since ${previous}` : "first nightly" };
  });
}

// Older nightly prereleases of one package beyond the newest `retain`.
export function releasesToPrune(releaseTags, name, retain) {
  const prefix = `nightly/${name}/`;
  const mine = releaseTags.filter((t) => t.startsWith(prefix)).sort().reverse();
  return mine.slice(retain);
}

// The run a `gh workflow run --ref <tag>` created: a workflow_dispatch run on
// that tag (GitHub reports the tag name as head_branch) at `sha`, created at or
// after `since`, an ISO time taken just before dispatching less a clock-skew
// allowance. Oldest match wins.
export function pickDispatchedRun(runs, tag, sha, since) {
  return (
    runs
      .filter((r) => r.event === "workflow_dispatch" && r.head_branch === tag && r.head_sha === sha && r.created_at >= since)
      .sort((a, b) => a.created_at.localeCompare(b.created_at))[0] ?? null
  );
}

// Release one package. Order: tag, prerelease, then the kind action. Every
// failure rolls the prerelease and tag back so the next trigger retries, except
// when a dispatched run is still in progress: it may still be checking the tag
// out, so the tag stays and the package is reported failed for a human.
//   ops: createTag, createPrerelease, deleteRelease, deleteTag, docker,
//        dispatch, findRun(entry, sha, since), waitRun(run), since(), warn
export async function releasePackage(entry, sha, ops) {
  const withRelease = entry.pkg.prerelease !== false;
  await ops.createTag(entry.tag, sha);
  try {
    if (withRelease) await ops.createPrerelease(entry, sha);
    if (entry.pkg.kind === "docker") return await ops.docker(entry, sha);
    if (entry.pkg.kind !== "dispatch") return "tag only";
    const since = ops.since();
    await ops.dispatch(entry);
    const started = await ops.findRun(entry, sha, since);
    if (!started) throw new Error(`no ${entry.pkg.workflow} run appeared for ${entry.tag}`);
    const run = await ops.waitRun(started);
    if (run.status !== "completed") {
      const error = new Error(`${entry.pkg.workflow} still running after the wait limit: ${run.html_url}`);
      error.keepTag = true;
      throw error;
    }
    if (run.conclusion !== "success") throw new Error(`${entry.pkg.workflow} ${run.conclusion}: ${run.html_url}`);
    return `${entry.pkg.workflow} succeeded: ${run.html_url}`;
  } catch (error) {
    if (!error.keepTag) {
      for (const undo of withRelease ? [ops.deleteRelease, ops.deleteTag] : [ops.deleteTag]) {
        try {
          await undo(entry.tag);
        } catch {
          ops.warn(`could not roll back ${entry.tag}; delete it by hand so the next trigger retries`);
        }
      }
    }
    throw error;
  }
}
