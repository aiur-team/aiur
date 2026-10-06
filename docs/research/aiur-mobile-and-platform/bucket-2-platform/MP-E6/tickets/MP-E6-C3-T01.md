---
ticket_id: MP-E6-C3-T01
feature_id: MP-E6
chunk_id: MP-E6-C3
bucket: 2-platform
title: voice.conversation.* configuration schema, example and reference entries (RC-13)
status: blocked
blocked_by: [DESIGN-E6, E6-OQ6, E6-OQ7, MP-R5-C2-T01]
prior_units: []
prior_boundaries: [VOX, CFG]
prior_features: [config-33]
prior_findings: []
size_owner: n/a (new schema file; schema.ex gains two lines)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E6-C3-T01 — `voice.conversation.*` config

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E6 / C3 provisioning, config, preflight.
- **User value:** the operator configures the assistant (which provider agent, which LLM,
  where roles live, cost caps) in `.aiur/config` like every other aiur setting.
- **Deliverable:** schema `Aiur.Config.Schema.Voice` with embed `conversation`
  (`Aiur.Config.Schema.VoiceConversation`), registered on the root schema; accessor
  functions; a commented block in `.aiur/examples/config.example`; one entry per key in
  `website/docs-app/reference/configuration.md`; `scripts/check-config-docs.py` green.
- **Non-goals:** the setup CLI (C3-T02); enforcing caps (C4-T01); renaming `elevenlabs.*`
  (RC-13: unchanged).

## Dependencies and blockers

- **Owner:** E6-OQ6 (session length, idle end, daily minutes defaults) and E6-OQ7 (LLM
  choice). This ticket ships the owner's numbers as defaults; it does not choose them.
- **Predecessors:** MP-R5-C2-T01 (schema registration mechanism for the voice component);
  if R5 keeps the core-schema approach, register directly in `schema.ex` as below.

## Verified starting point (base `45a290e3`)

| Item | Evidence |
| --- | --- |
| Embed pattern | `schema.ex:70` `embeds_one(:elevenlabs, ElevenLabs, on_replace: :update, defaults_to_struct: true)`; cast `:182` |
| Leaf schema style | `config/schema/eleven_labs.ex:1-26` (comment per field, `changeset/2` with `cast/4`) |
| Example config | `.aiur/examples/config.example:153` (`{{ELEVENLABS_SECTION}}` placeholder filled by `init/templates.ex`) |
| Reference page | `website/docs-app/reference/configuration.md:641` `## elevenlabs` |
| Docs gate | `scripts/check-config-docs.py` walks `embeds_one` from the root schema and requires every full dotted path in the reference (`:1-20`) |

## Chosen design

| Key | Type | Default | Validation |
| --- | --- | --- | --- |
| `voice.conversation.agent_id` | string | `null` | non-empty when set; not a secret (an account-visible id) |
| `voice.conversation.llm` | string | E6-OQ7 answer (recommendation: a Claude Haiku 4.5 or Gemini Flash built-in id) | non-empty |
| `voice.conversation.roles_dir` | string | E6-OQ3 answer (recommendation `.aiur/voice/roles`) | relative paths resolve against the config file's directory, like `prompt_file:` (AGENTS.md "Layout") |
| `voice.conversation.max_session_seconds` | integer | E6-OQ6 (recommendation 1200) | 60..3600 |
| `voice.conversation.idle_timeout_seconds` | integer | E6-OQ6 (recommendation 120) | 15..900 |
| `voice.conversation.daily_minutes_cap` | integer or null | E6-OQ6 (recommendation: owner sets; `null` = no cap) | ≥ 1 |
| `voice.conversation.context_token_budget` | integer | 8000 (adjusted by spike RQ-E6-4) | 1000..32000 |

- `voice.conversation` capability is `not_configured` until `agent_id` is set (contract §7).
- No new secret and no new environment variable (contract §12).

## Implementation steps

1. `config/schema/voice.ex` and `config/schema/voice_conversation.ex`.
2. `schema.ex`: `embeds_one(:voice, Voice, on_replace: :update, defaults_to_struct: true)`
   and `cast_embed(:voice, with: &Voice.changeset/2)`.
3. `Aiur.Config.voice_conversation/0` accessor returning the struct.
4. `.aiur/examples/config.example`: commented `voice:` block after the ElevenLabs section;
   `src/examples/workflows/*.yaml` unchanged (voice is optional).
5. `configuration.md`: `## voice` section with one row per key and its default.

## Non-happy paths

- Invalid values → the existing config error path (changeset errors at load) with the field
  name; the daemon's existing behaviour on invalid config applies.
- Missing `voice:` block → struct defaults; capability `not_configured`.

## Compatibility and rollout

Additive keys; existing configs load unchanged. Rollback: revert (unknown keys in a user's
config would then be rejected or ignored per the schema's existing unknown-key policy — the
implementer states which, citing `schema.ex`).

## Verification

| Test | Expected |
| --- | --- |
| `test/aiur/config/schema/voice_conversation_test.exs` "defaults match the owner decisions" | struct defaults equal the E6-OQ6/OQ7 numbers recorded in DESIGN-E6 |
| "out-of-range values are rejected with the field name" | `max_session_seconds: 10` → error on that field |
| "roles_dir resolves relative to the config file" | given `/tmp/x/.aiur/config`, `voice/roles` → `/tmp/x/.aiur/voice/roles` |
| `python3 scripts/check-config-docs.py` | exit 0 |
| `bash scripts/test-check-config-docs.sh` | exit 0 |

```bash
env -C src mise exec -- mix test test/aiur/config/schema/voice_conversation_test.exs
python3 scripts/check-config-docs.py
make -C src fmt-check lint
```

Run in an implementation worktree with `GITHUB_TOKEN`/`GH_TOKEN` unset and hash-check
`~/.aiur/github-budget/agent-token` before and after.

**Mutation check.** Remove one key's reference entry: `check-config-docs.py` fails. Change a
range bound: the rejection test fails.

## Completion and handoff

- [ ] Schema, accessor, example block, reference entries; config-docs gate green.
- **Dependents:** MP-E6-C3-T02, MP-E6-C3-T03, MP-E6-C4-T01, MP-E6-C4-T03, MP-E6-C4-T04.
