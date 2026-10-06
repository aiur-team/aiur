---
ticket_id: MP-R5-C2-T02
feature_id: MP-R5
chunk_id: MP-R5-C2
bucket: 1-refactor
title: Voice registers its elevenlabs config section and its aiur init contribution through the MP-R1 registration mechanism
status: blocked
blocked_by: [DESIGN-R5, MP-R5-C1-T01, MP-R1-C4-T1]
prior_units: [U8]
prior_boundaries: ["VOX #36", "CFG #2", "INI #37"]
prior_features: [config-33]
prior_findings: []
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R5-C2-T02 — Voice registers its config section and its `init` contribution

## Identity and outcome

- **Bucket / feature / chunk:** 1-refactor / MP-R5 / C2.
- **User value:** none visible. These stay byte-identical:
  - the keys `elevenlabs.api_key`, `elevenlabs.language_code` and
    `elevenlabs.voice_id`;
  - `ELEVENLABS_API_KEY`;
  - the `aiur init` prompt and YAML;
  - the resume line.

  Core stops naming `Aiur.Config.Schema.ElevenLabs` and `Aiur.Init.ElevenLabs`,
  so C3 can move them.
- **Deliverable:**
  - The `elevenlabs` embed is registered by the voice provider through MP-R1's
    config-registration mechanism.
  - The `init` prompt, the resume entry and the template section are
    contributed through a voice hook.
  - `Aiur.Config.elevenlabs_*` accessors move behind the facade, or are kept as
    thin delegates if the R1 mechanism keeps per-section accessors on
    `Aiur.Config`. Follow R1.
- **Non-goals:**
  - renaming keys. RC-13: speech-to-text keeps `elevenlabs.*`, and new
    conversational keys go under `voice.conversation.*` (MP-E6, not here).

## Dependencies and blockers

- **Blocked by:**
  - **MP-R1-C4-T1**, the registration mechanism. R1 plan § C4 records the open
    research: "whether Ecto `embeds_one` can be composed at compile time from a
    registry, or the checker must learn registration". This ticket must not
    invent its own mechanism.
  - DESIGN-R5 and MP-R5-C1-T01.
- **May run concurrently with:** C2-T01 and C4-*. It must precede C3-T01.

## Verified starting point (base `45a290e3`)

- **Schema:**
  - `src/lib/aiur/config/schema.ex:17` (alias);
  - `:70` (`embeds_one(:elevenlabs, ElevenLabs, on_replace: :update, defaults_to_struct: true)`);
  - `:182` (`cast_embed`);
  - `:232-241` (redaction of `api_key` in the inspected settings).
- **Embed:** `src/lib/aiur/config/schema/eleven_labs.ex` (26 lines).
- **Accessors:** `src/lib/aiur/config.ex:329-340` (`elevenlabs_api_key/0`,
  `elevenlabs_language_code/0` default `"eng"`, `elevenlabs_voice_id/0`).
- **Init:**
  - `src/lib/aiur/init.ex:171` (`ElevenLabs.prompt_eleven_labs/3`);
  - `src/lib/aiur/init/resume.ex:39,65-67,154-156`;
  - `src/lib/aiur/init/templates.ex:109,132-133` (`{{ELEVENLABS_SECTION}}`);
  - `src/lib/aiur/init/eleven_labs.ex` (73 lines).
- **Docs checker:** `scripts/check-config-docs.py` resolves every key through
  `embeds_one` reachability. It runs in the required `lint` job
  (`.github/workflows/ci.yml:259-262`).

## Chosen design

Apply whatever MP-R1-C4-T1 ships. The constraints this ticket adds:

1. **The resolved config is identical.** For `.aiur/examples/config.example`
   and the three `src/examples/workflows/*.yaml`, the loaded
   `Aiur.Config.Schema` struct has the same `elevenlabs` value before and
   after.
2. **`api_key` redaction stays.** The `:232-241` redaction moves with the
   section, or is driven by a `secret_fields` declaration in the registration.
3. **The `init` output is byte-identical.** The template golden test
   (`src/test/aiur/init/templates_test.exs`, 21 elevenlabs references) and
   `src/test/aiur/init/resume_test.exs` (11) keep their expectations unchanged.
4. **Provider nil:** the section is not registered. A config file that still
   contains `elevenlabs:` must load **without error**, with the section
   ignored, and the daemon should log once at info level. Failing to boot over
   an optional component's leftover keys would make removal break existing
   repositories. The exact unknown-section behaviour is R1's; if R1 rejects
   unknown sections, raise that as an R1 item before implementing.

## Implementation steps

1. Read MP-R1-C4-T1 as merged, and its registration API.
2. Register the `elevenlabs` section from `Aiur.ElevenLabs`, keeping the same
   module `Aiur.Config.Schema.ElevenLabs` until C3 moves it.
3. Replace the direct `init` calls with a voice `init` contribution (prompt,
   resume line, YAML section), using R1's init-hook shape. If R1 defines none,
   add a minimal `Aiur.Voice.init_contribution/0` returning
   `%{prompt: fun, resume: fun, yaml: fun}`, and have `Aiur.Init` iterate the
   registered contributions.
4. Remove the `ElevenLabs` aliases from `schema.ex`, `init.ex`, `resume.ex`
   and `templates.ex`.

## Non-happy paths

- **Config with `elevenlabs:` and no provider:** loads (see constraint 4).
- **An `ELEVENLABS_API_KEY` env reference in YAML:** resolution is unchanged
  (`$ELEVENLABS_API_KEY` syntax, `website/docs-app/apis/elevenlabs.md:29`).

## Compatibility and rollout

- Config keys are unchanged. `scripts/check-config-docs.py` must keep passing
  with no docs edit. If R1's mechanism needs the checker changed, that is R1's
  PR.
- Rollback means reverting the PR.

## Verification

```bash
python3 scripts/check-config-docs.py && bash scripts/test-check-config-docs.sh
env -C <worktree>/src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test \
  test/aiur/init/templates_test.exs test/aiur/init/resume_test.exs test/aiur/config_test.exs
```

New tests:

- "elevenlabs section round-trips unchanged through registration": load
  `.aiur/examples/config.example` and assert the `elevenlabs` struct equals a
  literal of today's values.
  - Mutation: drop `language_code` from the registered fields. The test fails.
- "a leftover elevenlabs section loads when voice is not installed": set the
  provider to nil and load a config containing `elevenlabs:`; assert `{:ok, _}`.
  - Mutation: make the loader reject unknown sections. The test fails.

The existing templates golden test must pass unchanged. That is the
byte-identity oracle.

## Completion and handoff

- [ ] `git grep -n "ElevenLabs" -- src/lib/aiur/config/schema.ex src/lib/aiur/init.ex src/lib/aiur/init/resume.ex src/lib/aiur/init/templates.ex`
  is empty.
- [ ] The config docs checker is green with no docs change.
- [ ] Docs: none. Keys are unchanged, and `reference/configuration.md` is
  untouched.
- **Dependents:** C3-T01.
