"""Generate the platform-program Build Order from the research pack.

Usage:
  python3 -I generate.py [--install] [--state-dir DIR]

Reads every ticket under the pack (bucket-*/**/tickets/*.md, including the
U-units and U8 trees when they exist), the extra member docs in
build-order/extra/, and the optional Executor-owned promotions.json in the
state node. Writes build-order/build-order.json, build-order/tickets/<ID>.md
and build-order/epics.md. With --install it also copies build-order.json and
tickets/ to the state node. It never writes promotions.json or status.json.

Python 3 standard library only. Output order is deterministic.
"""
import json, os, re, shutil, sys
from collections import Counter, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
PACK = os.path.dirname(HERE)
STATE = os.path.expanduser("~/.aiur/repo/aiur-team/aiur/builds/platform-program-2026-10")
BUILD_ORDER_ID = "aiur-team/aiur:platform-program-2026-10"
DOC_LIMIT = 64_000  # PlanningSource.draft_body/2 drops larger bodies

# ---------------------------------------------------------------- epics ----
# id -> (title, purpose). Lane ids are what the dashboard shows.
EPICS = [
    ("queue", "Build queue and progress", "Keep the agent queue full without the Executor promoting each ticket."),
    ("home", "Home page and build history", "Replace the dashboard home with the continuous build-history view (MP-E8)."),
    ("refactor-units", "Prior refactor units", "Land the older U0-U7/U9 units; U0 is the review gate for all refactor work."),
    ("size-reduction", "Size reduction", "Split the oversized files named by the U8 size ledger."),
    ("kernel", "Component map and kernel", "Component manifest, identity, capabilities, config, journal, routes and docs."),
    ("tracker", "Tracker ports and GitHub listeners", "Split the tracker contract and move GitHub polling into listeners."),
    ("event-bus", "Event bus and export", "One event contract with durable consumers, a topic catalog and an export API."),
    ("harness", "Harness adapters", "Per-harness delivery primitives, native steer and the adapter package."),
    ("command-delivery", "Command delivery and answering", "Commands reach the right responder and can be answered on every surface."),
    ("executor", "Executor session and view", "Attach the Executor's own session and show its state in the dashboard."),
    ("conversations", "Conversation journal and view", "Durable conversation journal, anchors and the conversation view."),
    ("listener", "Listener modes and send path", "Steer, sync and async listener modes and one send path for every client."),
    ("voice", "Voice input and dictation", "The voice port and dictation on dashboard, phone and watch."),
    ("voice-assistant", "Conversational voice assistant", "Converse with a voice assistant that drafts instructions for agents."),
    ("pairing", "Device pairing and gateway", "Machine store, gateway, pairing, device tokens and device management."),
    ("push", "Encrypted push and notifications", "End-to-end encrypted push through a relay and the notification policy."),
    ("mobile-app", "Phone app shell and meta-dashboard", "The Expo app, native cores, WebView host and multi-machine summary."),
    ("watch", "Watch apps", "watchOS and Wear OS apps, watch push and Command cards."),
    ("operator-cli", "Operator CLI and accounts", "Small operator CLI fixes outside the program waves."),
    ("acceptance", "Feature acceptance QA", "One end-to-end QA member per feature, owned by the Executor."),
]
EPIC_IDS = [e[0] for e in EPICS]

# Most specific prefix wins: ticket id > chunk > feature. Keys are matched
# against the member id with a trailing "-" boundary.
EPIC_MAP = {
    "MP-E1": "queue", "MP-E8": "home",
    # MP-E8-C14 swaps the home modal onto other features' contracts.
    "MP-E8-C14-T01": "conversations", "MP-E8-C14-T02": "listener",
    "MP-E8-C14-T03": "conversations", "MP-E8-C14-T04": "command-delivery",
    "MP-R1": "kernel", "MP-R1-C7": "tracker", "MP-R1-C9": "tracker", "MP-R1-C8": "command-delivery",
    "MP-R2": "event-bus", "MP-R3": "kernel", "MP-R4": "kernel",
    "MP-R5": "voice", "MP-R6": "kernel", "MP-R6-C1": "conversations", "MP-R7": "harness",
    "MP-E2": "command-delivery",
    "MP-E3": "executor", "MP-E3-C5": "listener", "MP-E3-C6-T03": "command-delivery",
    "MP-E4": "conversations", "MP-E4-C4": "command-delivery", "MP-E4-C6-T01": "listener",
    "MP-E4-C6-T02": "command-delivery",
    "MP-E5": "voice", "MP-E6": "voice-assistant",
    "MP-E7": "listener", "MP-E7-C4": "harness",
    "MP-N1": "mobile-app", "MP-N2": "pairing", "MP-N3": "mobile-app",
    "MP-N4": "push", "MP-N4-C6": "watch", "MP-N5": "push",
    "MP-N6": "command-delivery", "MP-N6-C4": "voice", "MP-N6-C5": "watch",
    "MP-N7": "watch", "MP-N7-C4": "voice",
    "U8": "size-reduction",
    "GH-3032": "command-delivery", "GH-3033": "listener", "CLI-LOGIN-T01": "operator-cli",
}

# ---------------------------------------------------------------- phases ---
# Soft presentation phases. Waves 0, 0b, 1..5 map to phases 0..6.
PHASES = {0: "wave 0: MP-E1 build queue", 1: "wave 0b: MP-E8 home page",
          2: "wave 1: refactor (U-units, MP-R1..R7, U8)", 3: "wave 2: MP-E2 Commands",
          4: "wave 3: E7-C1..C3, E3, E4", 5: "wave 4: R2-C5, E5, E6, E7 rest",
          6: "wave 5: mobile and watch"}
WAVE_TO_PHASE = {"0": 0, "0b": 1, "1": 2, "2": 3, "3": 4, "4": 5, "5": 6}
FEATURE_WAVE = {"MP-E1": "0", "MP-E8": "0b", "MP-E2": "2", "MP-E3": "3", "MP-E4": "3",
                "MP-E5": "4", "MP-E6": "4"}
FEATURE_WAVE.update({"MP-R%d" % i: "1" for i in range(1, 8)})
FEATURE_WAVE.update({"MP-N%d" % i: "5" for i in range(1, 8)})
# Ticket-level wave decisions (graph-check.md, RC-29, RC-31).
TICKET_WAVE = {"MP-E7-C2-T05": "4", "MP-E5-C7-T01": "5", "MP-E1-C3-T08": "1"}

MEMBER_ID = re.compile(r"^(MP-[A-Z]\d-C\d+-T\d+|U\d+[A-Za-z0-9-]*?-T\d+[a-z]?)$")
TREF = re.compile(r"(?:MP-)?([A-Z]\d)-C(\d+)-T(\d+)")
UREF = re.compile(r"\bU\d+[A-Za-z0-9-]*?-T\d+[a-z]?\b")
EXTRA = [("GH-3032", 3032), ("GH-3033", 3033), ("CLI-LOGIN-T01", None)]


def natkey(s):
    return [int(x) if x.isdigit() else x for x in re.split(r"(\d+)", s)]


def frontmatter(text):
    lines = text.split("\n")
    fm = {}
    if not lines or lines[0].strip() != "---":
        return fm
    for ln in lines[1:]:
        if ln.strip() == "---":
            break
        m = re.match(r"^([A-Za-z_]+):\s*(.*)$", ln)
        if m:
            fm[m.group(1)] = m.group(2)
    return fm


def split_list(raw):
    """Split a YAML-ish inline list, keeping commas inside parentheses/quotes."""
    raw = raw.strip()
    if not raw.startswith("["):
        raw = re.sub(r"\s+#.*$", "", raw)
    else:
        depth, end, q = 0, len(raw), False
        for i, ch in enumerate(raw):
            if ch == '"':
                q = not q
            elif not q and ch == "[":
                depth += 1
            elif not q and ch == "]":
                depth -= 1
                if depth == 0:
                    end = i
                    break
        raw = raw[1:end]
    items, cur, depth, q = [], "", 0, False
    for ch in raw:
        if ch == '"':
            q = not q
            continue
        if not q and ch == "(":
            depth += 1
        elif not q and ch == ")":
            depth -= 1
        if ch == "," and depth <= 0 and not q:
            items.append(cur.strip())
            cur = ""
        else:
            cur += ch
    if cur.strip():
        items.append(cur.strip())
    return [i for i in items if i and i.lower() not in ("none", "n/a")]


def h1(text):
    m = re.search(r"^#\s+(.+)$", text, re.M)
    return m.group(1).strip() if m else None


def clean_title(tid, title):
    title = title.strip().strip('"').strip("'")
    return re.sub(r"^%s\s*[—–-]\s*" % re.escape(tid), "", title).replace("`", "")


def complexity_estimate(nbytes):
    # ponytail: the pack has no complexity field; doc size is a rough proxy.
    for limit, points in ((4000, 1), (7000, 2), (10000, 3), (14000, 4)):
        if nbytes <= limit:
            return points
    return 5


def unit_of(tid):
    m = re.match(r"^(U\d+)", tid)
    return m.group(1) if m else None


# --------------------------------------------------------------- loading ---
def load_tickets():
    tickets = {}
    findings = defaultdict(list)
    for dp, dirs, fs in os.walk(PACK):
        dirs.sort()
        if os.path.basename(dp) != "tickets" or "/bucket-" not in dp:
            continue
        for fn in sorted(fs):
            if not fn.endswith(".md"):
                continue
            path = os.path.join(dp, fn)
            text = open(path, encoding="utf-8").read()
            fm = frontmatter(text)
            tid = (fm.get("ticket_id") or fm.get("id") or "").strip().strip('"') or fn[:-3]
            if not MEMBER_ID.match(tid):
                if fm:
                    findings["skipped_files"].append(os.path.relpath(path, PACK))
                continue
            if tid in tickets:
                findings["duplicate_ids"].append([tid, os.path.relpath(path, PACK)])
                continue
            unit = unit_of(tid)
            feature = (fm.get("feature_id") or fm.get("unit") or fm.get("unit_id") or "").strip().strip('"')
            if not feature:
                feature = unit or "-".join(tid.split("-")[:2])
            if unit and not feature.startswith("U"):
                feature = unit
            chunk = (fm.get("chunk_id") or "").strip() or "-".join(tid.split("-")[:-1])
            raw = []
            for key in ("blocked_by", "depends_on", "predecessors"):
                if fm.get(key):
                    raw += split_list(fm[key])
            tickets[tid] = {
                "id": tid, "feature": feature, "chunk": chunk, "path": path, "text": text,
                "title": clean_title(tid, fm.get("title") or h1(text) or tid),
                "status": (fm.get("status") or "").split("#")[0].strip(),
                "fm_wave": (fm.get("wave") or "").split("#")[0].strip().strip('"') or None,
                "raw": raw,
                "complexity": int(fm["complexity"].split("#")[0]) if re.match(r"^\s*[1-5]\b", fm.get("complexity", "")) else None,
                "conflicts": [c for c in split_list(fm.get("conflicts", "")) if MEMBER_ID.match(c)],
            }
    return tickets, findings


def nominal_wave(t):
    if t["id"] in TICKET_WAVE:
        return TICKET_WAVE[t["id"]]
    if t["chunk"] == "MP-R2-C5":
        return "4"
    if re.match(r"MP-R2-C[67]$", t["chunk"]) or t["chunk"] == "MP-E5-C8":
        return "5"
    if t["feature"] == "MP-E7":
        return "3" if int(re.search(r"-C(\d+)", t["chunk"]).group(1)) <= 3 else "4"
    if t["feature"].startswith("U"):
        return "1"
    return FEATURE_WAVE.get(t["feature"], "1")


def wave_of(t, findings):
    w = t["fm_wave"]
    if w:
        m = re.match(r"(0b|\d)", w)
        if m and m.group(1) in WAVE_TO_PHASE:
            # RC-09/RC-31 chunk moves outrank a stale front-matter wave.
            nom = nominal_wave(t)
            if t["chunk"].startswith("MP-R2-C") and nom != m.group(1):
                return nom
            return m.group(1)
        findings["bad_wave"].append([t["id"], w])
    return nominal_wave(t)


def edges_md_pairs(ids):
    """Read A -> B lines from */edges.md under bucket-1-refactor: B depends on A."""
    pairs = []
    for dp, dirs, fs in os.walk(os.path.join(PACK, "bucket-1-refactor")):
        dirs.sort()
        if "edges.md" in fs:
            for ln in open(os.path.join(dp, "edges.md"), encoding="utf-8"):
                for a, b in re.findall(r"([A-Z][\w-]*\d)\s*(?:->|→)\s*([A-Z][\w-]*\d)", ln):
                    if a in ids and b in ids:
                        pairs.append((a, b))
    return pairs


# -------------------------------------------------------------- resolving --
def resolve(tickets, findings):
    ids = set(tickets)
    by_chunk, by_feat = defaultdict(list), defaultdict(list)
    for t in tickets.values():
        by_chunk[t["chunk"]].append(t["id"])
        by_feat[t["feature"]].append(t["id"])
    raw_edges = set()
    gates = defaultdict(set)  # member -> gate ids
    gate_kind = {}
    refs = {"chunk": 0, "feature": 0, "unit": 0}

    def gate(tid, kind, key):
        gates[tid].add(key)
        gate_kind.setdefault(key, kind)

    def ticket_ref(m):
        f, c, n = m.group(1), int(m.group(2)), int(m.group(3))
        for cand in ("MP-%s-C%d-T%02d" % (f, c, n), "MP-%s-C%d-T%d" % (f, c, n), "MP-%s-C%d-T%03d" % (f, c, n)):
            if cand in ids:
                return cand
        return None

    for t in sorted(tickets.values(), key=lambda x: natkey(x["id"])):
        tid = t["id"]
        for item in t["raw"]:
            s = item.strip().strip('"').strip()
            head = re.split(r"[\s(]", s, maxsplit=1)[0]
            preds = []
            if "device voice path" in s:  # RC-16 alias
                s, head = "MP-E5-C8", "MP-E5-C8"
            if head in ids:
                preds = [head]
            elif re.match(r"^DESIGN-[A-Z]\d", s):
                gate(tid, "design", re.match(r"^DESIGN-[A-Z]\d", s).group())
            elif s.startswith("RQ-") or re.match(r"^[A-Z]\d-RQ\d", s):
                gate(tid, "research", re.match(r"^(RQ-[A-Z0-9-]+|[A-Z]\d-RQ\d+)", s).group().rstrip("-"))
            elif re.match(r"^(OQ-[A-Z0-9-]+|E\d-D\d+|D-[A-Z0-9-]+|[A-Z]\d-OQ\d+|KQ-[A-Z0-9-]+|CR-[A-Z0-9-]+)", s):
                gate(tid, "owner", re.match(r"^(OQ-[A-Z0-9-]+|E\d-D\d+|D-[A-Z0-9-]+|[A-Z]\d-OQ\d+|KQ-[A-Z0-9-]+|CR-[A-Z0-9-]+)", s).group())
            elif re.match(r"^(OWNER-|owner authorization|coordinator|MP-E1 owner review|MP-E7 contract request)", s):
                gate(tid, "owner", "CR-R2-1" if s.startswith("coordinator") else s.split(" (")[0])
            elif re.match(r"^(#\d+|PR #\d+)", s):
                gate(tid, "external", re.search(r"#\d+", s).group())
            elif UREF.search(s.split(" (")[0]) and any(u in ids for u in UREF.findall(s)):
                preds = [u for u in UREF.findall(s) if u in ids]
            elif re.match(r"^U\d+\b", s):
                unit = re.match(r"^U\d+", s).group()
                if by_feat.get(unit):
                    preds = sinks(by_feat[unit], tickets)
                    refs["unit"] += 1
                else:
                    gate(tid, "prior-unit", unit)
            elif TREF.match(s):
                for m in TREF.finditer(s.split(" (")[0]):
                    r = ticket_ref(m)
                    if r:
                        preds.append(r)
                    else:
                        findings["dangling_refs"].append([tid, s])
            elif re.match(r"^MP-[A-Z]\d C\d+[–-]C\d+", s):
                m = re.match(r"^(MP-[A-Z]\d) C(\d+)[–-]C(\d+)", s)
                for c in range(int(m.group(2)), int(m.group(3)) + 1):
                    preds += by_chunk.get("%s-C%d" % (m.group(1), c), [])
                refs["chunk"] += 1
            elif re.match(r"^MP-[A-Z]\d-C\d+\b", s):
                ch = re.match(r"^MP-[A-Z]\d-C\d+", s).group()
                if by_chunk.get(ch):
                    preds = sinks(by_chunk[ch], tickets)
                    refs["chunk"] += 1
                else:
                    findings["dangling_refs"].append([tid, s])
            elif re.match(r"^MP-[A-Z]\d\b", s):
                feat = re.match(r"^MP-[A-Z]\d", s).group()
                for f, c1, sep, c2 in re.findall(r"\b([A-Z]\d)-C(\d+)(?:(/|\.\.)C(\d+))?", s):
                    cs = [int(c1)] + ([int(c2)] if sep == "/" else list(range(int(c1) + 1, int(c2) + 1)) if c2 else [])
                    for c in cs:
                        preds += by_chunk.get("MP-%s-C%s" % (f, c), [])
                if not preds:
                    preds = sinks(by_feat.get(feat, []), tickets)
                refs["feature"] += 1
            else:
                gate(tid, "unparsed", s[:80])
                findings["unparsed_blockers"].append([tid, s])
            for p in preds:
                if p != tid:
                    raw_edges.add((p, tid))
    for a, b in edges_md_pairs(ids):
        raw_edges.add((a, b))
        findings["edges_md_pairs"].append([a, b])
    # U0-T01 is the review gate before every MP-R1..R7 and U1..U7 ticket
    # (U0-T01.md, RC-19). Explicit edges may already say so; the transitive
    # reduction removes the duplicates.
    if "U0-T01" in ids:
        for t in tickets.values():
            if re.match(r"^(MP-R\d|U[1-7]-)", t["id"]):
                raw_edges.add(("U0-T01", t["id"]))
    return raw_edges, gates, gate_kind, refs


def sinks(members, tickets, _cache={}):
    """Members of a group that no other member of the same group depends on.

    Filled lazily from the group's own blocked_by text; good enough because a
    group reference means 'after the whole group', and its sinks imply the rest.
    """
    group = set(members)
    inner = set()
    for m in members:
        for item in tickets[m]["raw"]:
            for ref in re.findall(r"(?:MP-)?[A-Z]\d-C\d+-T\d+|U\d+[A-Za-z0-9-]*?-T\d+", item):
                ref = ref if ref.startswith(("MP-", "U")) else "MP-" + ref
                if ref in group:
                    inner.add(ref)
    out = sorted(group - inner, key=natkey)
    return out or sorted(group, key=natkey)


# ---------------------------------------------------------------- graph ----
def toposort(nodes, edges):
    preds, succs = defaultdict(set), defaultdict(set)
    for a, b in edges:
        preds[b].add(a)
        succs[a].add(b)
    indeg = {n: len(preds[n]) for n in nodes}
    ready = sorted([n for n in nodes if indeg[n] == 0], key=natkey)
    order = []
    while ready:
        n = ready.pop(0)
        order.append(n)
        for s in sorted(succs[n], key=natkey):
            indeg[s] -= 1
            if indeg[s] == 0:
                ready.append(s)
        ready.sort(key=natkey)
    cyclic = sorted((n for n in nodes if indeg[n] > 0), key=natkey)
    return order, cyclic, preds, succs


def transitive_reduction(order, preds):
    pos = {n: i for i, n in enumerate(order)}
    anc = {}
    reduced = {}
    for n in order:
        ps = sorted(preds[n], key=lambda p: -pos[p])
        keep, covered = [], set()
        for p in ps:  # latest predecessor first
            if p in covered:
                continue
            keep.append(p)
            covered |= anc[p] | {p}
        reduced[n] = sorted(keep, key=natkey)
        a = set()
        for p in preds[n]:
            a |= anc[p] | {p}
        anc[n] = a
    return reduced


def longest_path(order, preds):
    best = {}
    for n in order:
        p = max(preds[n], key=lambda x: (best[x][0], x), default=None)
        best[n] = (best[p][0] + 1, p) if p else (1, None)
    end = max(order, key=lambda n: (best[n][0], n))
    path = [end]
    while best[path[-1]][1]:
        path.append(best[path[-1]][1])
    return path[::-1]


# ----------------------------------------------------------------- main ----
def epic_of(mid):
    key = mid
    while key:
        if key in EPIC_MAP:
            return EPIC_MAP[key]
        key = key.rsplit("-", 1)[0] if "-" in key else ""
    return "refactor-units" if mid.startswith("U") else None


def design_gates():
    out = {}
    d = os.path.join(PACK, "owner-design-tasks")
    for fn in sorted(os.listdir(d), key=natkey):
        if fn.startswith("DESIGN-") and fn.endswith(".md"):
            out[fn[:-3]] = h1(open(os.path.join(d, fn), encoding="utf-8").read()) or fn[:-3]
    return out


def acceptance_doc(fid, deps, members, title):
    lines = ["# %s — %s acceptance QA" % (fid + "-ACC", fid), "",
             "**Complexity:** 2", "**Kind:** feature acceptance capstone (Executor-owned QA)",
             "**Depends on:** " + ", ".join(deps), "",
             "## Outcome", "",
             "The Executor proves %s end to end on current main and records the evidence." % fid, "",
             "## Scope", "",
             "- Rebuild and restart the daemon from current main; confirm the loaded build.",
             "- Run the feature's own acceptance criteria from its plan in the research pack"
             " (`docs/research/aiur-mobile-and-platform/**/%s/`)." % fid,
             "- Drive the real surfaces (CLI, dashboard, TUI, device) as AGENTS.md"
             " \"Manual testing\" defines it; capture screenshots or pane captures.",
             "- File P0/P1 acceptance blockers against the owning ticket; put P2/P3 findings"
             " in the deferred ledger.", "",
             "## Members covered (%d)" % len(members), ""]
    lines += ["- %s — %s" % (m, title[m]) for m in members]
    lines += ["", "## Acceptance and verification", "",
              "- Every member above is merged.",
              "- The feature's acceptance criteria pass on current main, with dated evidence.", ""]
    return "\n".join(lines)


def main(argv):
    install = "--install" in argv
    state = argv[argv.index("--state-dir") + 1] if "--state-dir" in argv else STATE
    tickets, findings = load_tickets()
    raw_edges, gates, gate_kind, refs = resolve(tickets, findings)
    title = {tid: t["title"] for tid, t in tickets.items()}
    docs = {tid: fit_doc(t["text"]) for tid, t in tickets.items()}
    feature = {tid: t["feature"] for tid, t in tickets.items()}
    phase = {tid: WAVE_TO_PHASE[wave_of(t, findings)] for tid, t in tickets.items()}

    # Extra members with hand-written docs.
    for mid, _num in EXTRA:
        p = os.path.join(HERE, "extra", mid + ".md")
        if os.path.exists(p):
            docs[mid] = open(p, encoding="utf-8").read()
            title[mid] = clean_title(mid, h1(docs[mid]) or mid)
            feature[mid] = mid
            phase[mid] = 0
        else:
            findings["missing_extra_doc"].append(mid)

    # Acceptance capstone per program feature (MP-*, U-units together, U8).
    def acc_feature(f):
        if f == "U8":
            return "U8"
        if f.startswith("U"):
            return "U-units"
        return f if f.startswith("MP-") else None
    groups = defaultdict(list)
    for tid in tickets:
        if acc_feature(feature[tid]):
            groups[acc_feature(feature[tid])].append(tid)
    nodes0 = set(docs)
    _, cyc0, _, succs0 = toposort(nodes0, raw_edges)
    for f in sorted(groups, key=natkey):
        mem = sorted(groups[f], key=natkey)
        g = set(mem)
        finals = [m for m in mem if not (succs0[m] & g)]
        aid = f + "-ACC"
        raw_edges |= {(m, aid) for m in finals}
        title[aid] = "%s acceptance QA" % f
        docs[aid] = acceptance_doc(f, finals, mem, title)
        feature[aid] = f
        phase[aid] = max(phase[m] for m in mem)

    nodes = set(docs)
    dangling = sorted({(a, b) for a, b in raw_edges if a not in nodes or b not in nodes})
    order, cyclic, preds, _ = toposort(nodes, raw_edges)
    ok = not dangling and not cyclic and not findings.get("duplicate_ids")
    if not ok:
        print("VALIDATION FAILED: dangling=%s cyclic=%s dup=%s" % (dangling[:5], cyclic[:10], findings.get("duplicate_ids")))
        return 1
    reduced = transitive_reduction(order, preds)
    crit = longest_path(order, preds)

    promotions = {}
    ppath = os.path.join(state, "promotions.json")
    if os.path.exists(ppath):
        promotions = json.load(open(ppath, encoding="utf-8"))
    extra_numbers = dict(EXTRA)

    members, oversize = [], []
    for mid in sorted(nodes, key=lambda m: (phase[m], natkey(m))):
        epic = "acceptance" if mid.endswith("-ACC") else epic_of(mid)
        if epic not in EPIC_IDS:
            findings["no_epic"].append(mid)
            epic = "refactor-units"
        num = promotions.get(mid, extra_numbers.get(mid))
        nbytes = len(docs[mid].encode("utf-8"))
        if nbytes > DOC_LIMIT:
            oversize.append([mid, nbytes])
        member = {"id": mid, "title": title[mid], "lane": epic, "phase": phase[mid],
                  "complexity": 2 if mid.endswith("-ACC") else (tickets[mid]["complexity"] if mid in tickets and tickets[mid]["complexity"] else complexity_estimate(nbytes)),
                  "depends_on": reduced[mid], "ticket": num if isinstance(num, int) else None,
                  "doc": "tickets/%s.md" % mid, "feature": feature[mid]}
        if mid in tickets and tickets[mid]["conflicts"]:
            member["serializes_with"] = sorted({c for c in tickets[mid]["conflicts"] if c in nodes}, key=natkey)
        if mid in tickets and not tickets[mid]["complexity"] and not mid.endswith("-ACC"):
            member["complexity_estimated"] = True
        if gates.get(mid):
            member["external_gates"] = sorted(gates[mid], key=natkey)
        members.append(member)

    dgates = design_gates()
    used = sorted({g for m in members for g in m.get("external_gates", [])}, key=natkey)
    ext = []
    for g in used:
        kind = gate_kind.get(g, "design")
        ext.append({"id": g, "kind": kind,
                    "title": dgates.get(g, g),
                    "owner": "Kevin (owner)" if kind in ("design", "owner") else "Feature Planner / Executor",
                    "resolution_criteria": "Owner approves %s in owner-design-tasks/%s.md." % (g, g) if kind == "design"
                    else "Resolved as recorded in the research pack.",
                    "blocks": sum(1 for m in members if g in m.get("external_gates", []))})
    root = promotions.get("_root")
    pack = {
        "schema_version": 1,
        "build_order_id": BUILD_ORDER_ID,
        "title": "BO: Platform program 2026-10",
        "icon": "map",
        "repository": "aiur-team/aiur",
        "ticket_prefix": "MP",
        "plan_version": 1,
        "researched_at_commit": "45a290e3",
        "github_root": {"number": root} if isinstance(root, int) else None,
        "completed": False,
        "workstreams": [{"id": i, "title": t, "purpose": p} for i, t, p in EPICS],
        "phases": [{"phase": k, "title": v} for k, v in sorted(PHASES.items())],
        "external_gates": ext,
        "feature_boundary": {
            "acceptance_criteria": ["Every feature's <feature>-ACC member passes on current main."],
            "critical_path_ticket_ids": crit,
            "completion_condition": "Every member is merged and every -ACC member has dated evidence.",
        },
        "tickets": members,
    }

    # ----------------------------------------------------------- write ----
    out_tickets = os.path.join(HERE, "tickets")
    os.makedirs(out_tickets, exist_ok=True)
    want = {m["id"] + ".md" for m in members}
    for fn in os.listdir(out_tickets):
        if fn.endswith(".md") and fn not in want:
            os.remove(os.path.join(out_tickets, fn))
    for m in members:
        write_if_changed(os.path.join(out_tickets, m["id"] + ".md"), docs[m["id"]])
    write_if_changed(os.path.join(HERE, "build-order.json"), json.dumps(pack, indent=1, ensure_ascii=False) + "\n")
    write_if_changed(os.path.join(HERE, "epics.md"), epics_md(members, crit))
    missing_docs = [m["id"] for m in members if not os.path.exists(os.path.join(out_tickets, m["id"] + ".md"))]

    if install:
        os.makedirs(os.path.join(state, "tickets"), exist_ok=True)
        for fn in os.listdir(os.path.join(state, "tickets")):
            if fn.endswith(".md") and fn not in want:
                os.remove(os.path.join(state, "tickets", fn))
        for m in members:
            write_if_changed(os.path.join(state, "tickets", m["id"] + ".md"), docs[m["id"]])
        shutil.copyfile(os.path.join(HERE, "build-order.json"), os.path.join(state, "build-order.json"))

    # --------------------------------------------------------- summary ----
    n_raw = len(raw_edges)
    n_red = sum(len(m["depends_on"]) for m in members)
    print("members %d  (tickets %d, extra %d, acceptance %d)" % (
        len(members), len(tickets), sum(1 for m, _ in EXTRA if m in nodes), sum(1 for m in members if m["id"].endswith("-ACC"))))
    print("edges declared %d -> after transitive reduction %d" % (n_raw, n_red))
    print("group refs expanded: %s; edges.md pairs %d" % (refs, len(findings.get("edges_md_pairs", []))))
    print("validation: dangling 0, cycles 0, missing docs %d, oversize docs %d, unparsed blockers %d, no-epic %d, skipped files %d" % (
        len(missing_docs), len(oversize), len(findings.get("unparsed_blockers", [])), len(findings.get("no_epic", [])),
        len(findings.get("skipped_files", []))))
    print("critical path %d members: %s ... %s" % (len(crit), " -> ".join(crit[:3]), " -> ".join(crit[-3:])))
    print("promotions applied: %d ticket numbers, root %s" % (sum(1 for m in members if m["ticket"]), root))
    print("external gates %d (%s)" % (len(ext), dict(Counter(g["kind"] for g in ext))))
    for label, key in (("feature", "feature"), ("epic", "lane"), ("phase", "phase")):
        c = Counter(m[key] for m in members)
        print("by %s: %s" % (label, ", ".join("%s=%d" % (k, c[k]) for k in sorted(c, key=lambda x: natkey(str(x))))))
    present = {f for f in feature.values()}
    for want_f in ("MP-E8", "U8", "U0"):
        if want_f not in present:
            print("NOT YET IN PACK: %s" % want_f)
    if install:
        print("installed to %s" % state)
    return 0 if not missing_docs else 1


def fit_doc(text):
    """Drop a trailing "## Review log" when the doc is over DOC_LIMIT.

    The review log is history, not the ticket contract; the source file keeps it.
    """
    if len(text.encode("utf-8")) <= DOC_LIMIT:
        return text
    i = text.find("\n## Review log")
    if i < 0:
        return text
    return text[:i].rstrip() + "\n\n(Review log omitted from the issue body; see the research pack file.)\n"


def write_if_changed(path, content):
    if os.path.exists(path) and open(path, encoding="utf-8").read() == content:
        return
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(content)


def epics_md(members, crit):
    by_epic = defaultdict(list)
    for m in members:
        by_epic[m["lane"]].append(m)
    lines = ["# Platform program Build Order — epics", "",
             "Generated by `generate.py`; do not edit by hand. Epics are the Build Order",
             "`workstreams`; each member's `lane` is its epic.", "",
             "## Why these epics", "",
             "Features (MP-E*, MP-R*, MP-N*, U-units) are delivery units: each has a design",
             "gate and an acceptance member. Epics cut across features by the contract a",
             "ticket builds or consumes, so one reviewer sees one contract end to end. For",
             "example, \"command-delivery\" holds the Commands facade (R1-C8), routing and",
             "answering (E2), the Command links and inline answers in conversations",
             "(E4-C4, E4-C6-T02, E3-C6-T03), the phone Command API and screens (N6) and the",
             "`aiur command` CLI (#3032). Mapping is by chunk, with ticket-level exceptions",
             "where one chunk mixes contracts (`EPIC_MAP` in generate.py).", "",
             "## Epic list", "",
             "| Epic (lane) | Title | Purpose | Members | Features |", "|---|---|---|---|---|"]
    for eid, t, p in EPICS:
        ms = by_epic.get(eid, [])
        feats = Counter(m["feature"] for m in ms)
        lines.append("| `%s` | %s | %s | %d | %s |" % (eid, t, p, len(ms),
                     ", ".join("%s (%d)" % (f, feats[f]) for f in sorted(feats, key=natkey))))
    lines += ["", "## Mapping rules", "", "| Prefix | Epic |", "|---|---|"]
    for k in sorted(EPIC_MAP, key=natkey):
        lines.append("| `%s` | `%s` |" % (k, EPIC_MAP[k]))
    lines += ["| `U*` (except U8) | `refactor-units` |", "| `*-ACC` | `acceptance` |", "",
              "## Phases (soft)", "",
              "Phases are presentation hints from value-and-sequencing.md. No wave-barrier",
              "edges exist: a ticket is ready when its hard `depends_on` are merged, so the",
              "next feature can start while the previous one finishes.", "",
              "| Phase | Wave | Members |", "|---|---|---|"]
    c = Counter(m["phase"] for m in members)
    for k, v in sorted(PHASES.items()):
        lines.append("| %d | %s | %d |" % (k, v, c[k]))
    lines += ["", "## Critical path (%d members)" % len(crit), "", " → ".join(crit), ""]
    return "\n".join(lines)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
