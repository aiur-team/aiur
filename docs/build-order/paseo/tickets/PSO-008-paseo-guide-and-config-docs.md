# PSO-008 — Documentation: Paseo guide page and config reference

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 2 — one new guide page, three cross-links, one nav entry; content is fixed by the design and spike

**Risk:** low

**Phase hint:** 2

**Depends on:** PSO-002

**Serializes with:** none

**External gates:** none

**Requirements:** R1, R2, R3, R4, R13

**Decisions:** DEC-001, DEC-002, DEC-011, DEC-013, DEC-014

**Design evidence:** 00-design.md sections 1, 2, 3, 5, 12; 01-spike-report.md sections 1, 10, 11; `docs/plans/2026-09-09-001-feat-paseo-integration-plan.md` Option 1

**Researched at:** 8199f5373 (aiur main), paseo 726067b4, aiur-claude 1.1.0

**Suggested labels:** `complexity:2`, `model:claude`, `phase:2`, `build-lane:paseo-integration`; never `agent:todo`

## Outcome

An operator who has never seen Paseo can, from the docs alone, install the daemon, pair a phone, install `aiur-paseo`, enable the backend for one issue, and know what they will see on each surface, what will not work, and what each failure means. The page is in the docs sidebar beside the other interface pages, and the configuration reference points at it.

## Context and evidence

Docs ship in the same PR as the change they describe (`src/AGENTS.md` "Docs Update Policy"). The config keys this page refers to are owned by PSO-002 (`agent.backend_configs.paseo-claude.*`, `agent.backend_configs.paseo-codex.*`, and the `model:paseo-*` labels); this ticket writes the narrative and the cross-links, not the key-by-key reference lines that `scripts/check-config-docs.py` enforces.

Where docs live and how they build:

- Pages: `website/docs-app/guide/*.md`, `concepts/*.md`, `reference/*.md`. Sidebar: `website/docs-app/.vitepress/config.ts` lines 48-90 (`Interfaces` group lists TUI, CLI, GUI, Stream Deck).
- Build: `.github/workflows/website.yml` runs `bun install --frozen-lockfile` and `bun run build` in `website/docs-app` on every PR touching `website/**`.
- Existing sibling to match in tone and length: `website/docs-app/guide/stream-deck.md` (an opt-in hardware surface) and the `## Remote control` section of `website/docs-app/concepts/operating-aiur.md` (lines 82-90).

## Scope

- `website/docs-app/guide/paseo.md`, sections in this order:
  1. **What you get.** One conversation, three views: the Paseo app on phone or desktop, the aiur TUI chat pane, the dashboard. Which agents: any issue routed to `paseo-claude` or `paseo-codex`. Why there is no handoff (Paseo owns the process; aiur drives it through the `aiur-paseo` sidecar). Mention that Claude Remote Control still exists and when to prefer it (no Paseo daemon, Claude subscription RC entitlement present).
  2. **Install Paseo.** `npm install -g @getpaseo/cli`; `paseo daemon start`; set a password (`paseo daemon set-password`, or write the bcrypt hash into `~/.paseo/config.json` as the spike had to; cite that the interactive prompt does not accept piped input); `paseo daemon pair` for the E2E relay QR; Tailscale direct-connection alternative (`daemon.listen` on the tailnet IP); default port `127.0.0.1:6767`.
  3. **Install the sidecar.** `npm install -g aiur-paseo`; add `PASEO_PASSWORD=...` to `.env` (and `PASEO_HOST` if not the default); `aiur-paseo --check` and its exit codes (0, 3, 4, 5, 6 from PSO-006).
  4. **Enable in aiur.** `agent.backend_configs.paseo-claude.enabled: true` (and `paseo-codex`); route with `agent.priority`, `agent.routing`, or the per-issue `model:paseo-claude` label; note `aiur init` offers the backends only when `aiur-paseo` is on PATH (PSO-013). Show one minimal `.aiur/config` excerpt.
  5. **What each surface shows.** TUI row 📱 Paseo indicator and deep link; dashboard row; the Paseo app entry titled `aiur <issue>: <title>` with labels `aiur_issue`, `aiur_repo`, `aiur_instance`; messages typed in Paseo appear in the aiur pane as user rows tagged phone; `aiur message` appears in Paseo.
  6. **Limitations.** Local only (no SSH workers); one Paseo agent per aiur workspace; permission mode defaults to `bypassPermissions` for Claude and `full-access` for Codex, and a prompting mode is forwarded but auto-denied after the turn timeout in v1 (DEC-011); coordination tools work through the sidecar's MCP bridge; the sidecar pins a Paseo version range and refuses others.
  7. **Troubleshooting.** A table: `paseo_unreachable` (daemon not running or wrong host), `paseo_unauthorized` (password mismatch), `paseo_unsupported_version` (daemon outside the pinned range; upgrade the sidecar or the daemon), `paseo_protocol_error`, the fallback attention (`paseo-claude` fell back to `claude` once at dispatch), "agent visible in Paseo but no 📱" (sidecar older than PSO-011), duplicate agents in one workspace (an older sidecar run left one; archive it in Paseo).
  8. **Without the package.** The three zero-code flows from the plan's Option 1: an Executor session in Paseo running the `aiur-run` and `aiur-monitor` skills; a Paseo terminal attached to a `claude-repl` agent's tmux pane; `paseo import` of a paused session with the pause-first rule. Keep this section short and link to the plan doc in the repo.
- `website/docs-app/.vitepress/config.ts`: add `{ text: 'Paseo', link: '/guide/paseo' }` after Stream Deck in the `Interfaces` group.
- `website/docs-app/concepts/operating-aiur.md`: add `## Paseo` after `## Remote control` with a three-row table in the same shape (`model:paseo-claude` label / starts the agent under Paseo; Paseo app / chats with the live session; chat pane and `aiur message` / same session), and one sentence pointing to the guide.
- `website/docs-app/reference/configuration.md`: in the `## agent` section where `backend_configs` is described, add one sentence linking `paseo-claude` and `paseo-codex` to the guide. The per-key lines are PSO-002's; do not duplicate them.
- `website/docs-app/reference/cli.md`: no aiur CLI flag changes; confirm and leave untouched. Mention `aiur-paseo --check` only in the guide.
- Root `README.md`: if PSO-004 did not add the Paseo bullet, add it; otherwise leave it.

## Non-goals

- Reference lines for config keys (PSO-002) or the init wizard behaviour text (PSO-013 updates the guide's "Enable" section if the wizard changes it).
- Screenshots of the Paseo app; link to paseo.sh instead.
- Documenting Paseo's relay, hub, or plugin features.

## Existing owner and reuse target

Extend the VitePress docs app. Match `guide/stream-deck.md` for structure and `concepts/operating-aiur.md` for the control table shape.

## Contract and invariants

### Requirements

- PSO-008-R1. `guide/paseo.md` exists with the eight sections above, and every command in it was run on this machine or is quoted from the spike report.
- PSO-008-R2. The page names every config key it uses with the exact dotted path PSO-002 documents, and links to `reference/configuration.md`.
- PSO-008-R3. The troubleshooting table covers each `DaemonErrorCode` from PSO-006 and the fallback attention from DEC-013.
- PSO-008-R4. The sidebar lists the page under Interfaces; `bun run build` in `website/docs-app` passes with no dead-link warnings.
- PSO-008-R5. `python3 scripts/check-config-docs.py` passes (this ticket adds no keys, so it must not break it).
- PSO-008-R6. The "Without the package" section states the pause-first rule for session import verbatim: pause in aiur, import, chat, archive in Paseo, resume in aiur.

## Refreshable implementation notes

- Pull the exact `--check` exit codes and error names from PSO-006's README table once it lands; if PSO-006 is not merged yet, use the values in 00-design.md DEC-013 and PSO-006's contract and note the dependency in the PR.
- Re-read `00-design.md` section 12 (manual proof) and describe the same flow as the operator walkthrough in section 5 of the page.
- Keep prose in the docs house style (`website/docs-app/guide/tui.md` is the shortest example): second person, one idea per sentence, tables for parallel facts.

### Key technical decisions

- One guide page rather than scattering Paseo notes across TUI, GUI, and configuration pages, because the feature is an opt-in surface like Stream Deck.
- The zero-code flows are documented here, not as a separate page, so an operator evaluating Paseo sees both paths at once.

## Acceptance and verification

### Agent gate

- `cd website/docs-app && bun install --frozen-lockfile && bun run build` green, zero dead links reported by VitePress.
- `python3 scripts/check-config-docs.py` green.
- A link check over the new page: every relative link resolves to a file in `website/docs-app`.

### At-merge gate

- CI workflow `website` green on the PR head.
- PSO-002's reference lines and this page agree on key names (grep both for `backend_configs.paseo-`).

### Human/manual evidence

- Open the built page locally (`bun run dev`), navigate from the sidebar, and screenshot the troubleshooting table; attach to the PR.

## Failure, security, migration, and accessibility cases

- Never print a real password or the spike's throwaway one as a recommended value; use `<password>` placeholders.
- State plainly that the Paseo daemon password is a single shared secret and that `PASEO_PASSWORD` in `.env` inherits `.env` handling rules.
- Tables need a header row and no merged cells for screen readers; images need alt text if any are added.

## Surfaces

- Reads: `00-design.md`, `01-spike-report.md`, PSO-002 reference lines, PSO-006 README.
- Writes: `website/docs-app/guide/paseo.md`, `.vitepress/config.ts`, `concepts/operating-aiur.md`, `reference/configuration.md` (one sentence), optionally root `README.md`.
- Contracts: none.

## Sibling boundaries and open gates

PSO-002 owns key reference lines; PSO-013 owns the init wizard text and will amend section 4 if the wizard flow differs; PSO-012 owns the manual proof this page's walkthrough mirrors.

## Plan context

- [Design and decisions](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/paseo/00-design.md)
- [Spike report](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/paseo/01-spike-report.md)
- [Pack index](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/paseo/README.md)
- [Requirements plan](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/plans/2026-09-09-001-feat-paseo-integration-plan.md)
- Your issue's native parent is the Build Order root; native `blockedBy` edges are the dependency graph — the root issue renders the full picture.
