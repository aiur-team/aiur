---
ticket_id: MP-E6-C4-T04
feature_id: MP-E6
chunk_id: MP-E6-C4
bucket: 2-platform
title: Role registry for assistant pre-context, with a hash recorded per session
status: blocked
blocked_by: [DESIGN-E6, E6-OQ3, MP-E6-C3-T01]
prior_units: []
prior_boundaries: [VOX, CFG]
prior_features: []
prior_findings: []
size_owner: n/a (new file)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E6-C4-T04 — `Roles`

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E6 / C4.
- **User value:** configurable role/skill pre-context (brief E6): "ticket discussion" and
  "project discussion" ship by default; the operator can add or edit roles as files.
- **Deliverable:** `Aiur.VoiceConversation.Roles` (PROPOSED): `list/0 -> [%{id, title}]`,
  `get(id) -> {:ok, %{id, title, prompt, hash}} | {:error, :not_found}`; default role files
  shipped in `src/priv/voice_roles/*.md`; operator roles from
  `voice.conversation.roles_dir` override defaults by id. Each session records `role_id` and
  `role_hash` (sha256 of the prompt) in `session_started` (contract §9).

## Dependencies and blockers

- **Owner:** E6-OQ3 (location and default roles). Recommendation in DESIGN-E6 is applied
  only after the answer.
- **Predecessors:** C3-T01 (`roles_dir`).

## Verified starting point (base `45a290e3`)

- Glossary appended to every role: `.claude/skills/aiur-agent/dictated-input.md` content is
  copied at build time into `src/priv/voice_roles/_glossary.md` (the skill directory is not
  shipped in the release; copying keeps one source by a test that asserts equality).
- Config-relative path precedent: `prompt_file:` resolved relative to the config (AGENTS.md
  "Layout").

## Chosen design

- Role file format: Markdown with a YAML front-matter `id`, `title`, `targets: [worker |
  executor]`; body = prompt. Invalid files are skipped and listed in `aiur voice setup`
  output as warnings (C3-T02).
- Default `worker` role: "ticket discussion"; default `executor` role: "project discussion".
  Body text is DESIGN-E6 copy (the assistant's persona and rules: discuss, ask, draft;
  never claim to have sent anything).
- Prompt sent = role body + glossary; hash covers both.

## Implementation steps

1. Loader with front-matter parsing via `YamlElixir` (`{:yaml_elixir, "~> 2.12"}`,
   `src/mix.exs:169`); 2. defaults; 3. tests.

## Non-happy paths

- `roles_dir` missing → defaults only; no error.
- Duplicate ids → operator file wins; warning.

## Compatibility and rollout

Additive. Rollback: revert.

## Verification

| Test | Expected |
| --- | --- |
| "an operator role overrides a default by id" | temp dir role `worker` → returned prompt is the operator's |
| "the hash changes when the prompt changes" | two prompts → different hashes |
| "the shipped glossary equals the skill file" | regression guard (labelled) |
| "invalid front-matter is skipped with a warning" | listed in warnings |

```bash
env -C src mise exec -- mix test test/aiur/voice_conversation/roles_test.exs
make -C src fmt-check lint
```

Run in an implementation worktree with `GITHUB_TOKEN`/`GH_TOKEN` unset and hash-check
`~/.aiur/github-budget/agent-token` before and after.

**Mutation check.** Load defaults after operator files: the override test fails.

## Completion and handoff

- [ ] Registry, defaults, docs: `configuration.md` `roles_dir` entry explains the file
      format (same PR).
- **Dependents:** C4-T01 (start uses `Roles.get/1`), C7-T02 (role picker if DESIGN-E6 has one).

## Amendment 2026-10-09 — independent package

Source: [../plan.md](../plan.md) §17. Kevin, 2026-10-09: build the voice assistant as "its own
independent package that can be used separately from [aiur]". The core is the Mix project
`packages/elixir/voice_converse/` (OTP app `:voice_converse`, namespace `VoiceConverse.*`).
It has no `Aiur.*` reference, and aiur is one host behind ports (§17.4). Module moves:
plan §17.9. Core tests run with `env -C packages/elixir/voice_converse mise exec -- mix test`
and do not boot aiur.

- Home: `VoiceConverse.Roles`. Roles come from `Config.roles` (inline) or `Config.roles_dir`.
  The glossary comes from `Config.glossary`. aiur supplies its roles directory (E6-OQ3) and
  `.claude/skills/aiur-agent/dictated-input.md`. The core has no aiur glossary built in.
