---
ticket_id: MP-R5-C2-T02
feature_id: MP-R5
chunk_id: MP-R5-C2
bucket: 1-refactor
title: Voice owns its elevenlabs config section in the manifest and contributes its aiur init step through a registry
status: blocked
blocked_by: [DESIGN-R5, MP-R5-C1-T01, MP-R1-C4-T01, MP-R1-C4-T05]
prior_units: [U8]
prior_boundaries: ["VOX #36", "CFG #2", "INI #37"]
prior_features: [config-33]
prior_findings: []
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R5-C2-T02 — Voice owns its config section and contributes its `init` step

## Identity and outcome

- **Bucket / feature / chunk:** 1-refactor / MP-R5 / C2.
- **User value:** none visible. These stay byte-identical:
  - the keys `elevenlabs.api_key`, `elevenlabs.language_code` and
    `elevenlabs.voice_id`;
  - `ELEVENLABS_API_KEY`;
  - the `aiur init` prompt and YAML;
  - the resume line.

  `Aiur.Init` stops naming `Aiur.Init.ElevenLabs`, so C3 can move it. The
  `elevenlabs` schema embed stays where it is (see "Chosen design").
- **Deliverable:**
  - The voice component declares `owns.config: ["elevenlabs"]` and
    `owns.env: ["ELEVENLABS_API_KEY"]` in `components.json` (the MP-R1-C4-T05
    ownership rules O-config and O-env).
  - The `init` prompt, the resume entry and the template section are
    contributed through a voice `init` contribution that `Aiur.Init` iterates.
  - `Aiur.Config.elevenlabs_*` accessors stay on `Aiur.Config` unchanged (they
    are section reads owned by the `config` component, like every other
    section accessor after MP-R1-C4-T03).
- **Non-goals:**
  - renaming keys. RC-13: speech-to-text keeps `elevenlabs.*`, and new
    conversational keys go under `voice.conversation.*` (MP-E6, not here).

## Dependencies and blockers

- **Blocked by:**
  - **MP-R1-C4-T05**, which answers the R1 plan § C4 research (RQ4): config
    sections **stay literal `embeds_one` lines in the root schema**, because
    `check-config-docs.py` walks those lines textually and a generated schema
    would break the docs gate. Ownership is manifest data (`owns.config`).
    This ticket therefore registers no schema section and invents no mechanism.
  - **MP-R1-C4-T01**, whose ordered app-env registry in `src/config/config.exs`
    is the pattern this ticket reuses for the `init` contribution list.
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

One design, fixed by MP-R1-C4-T05 (RQ4):

1. **The schema embed stays.** `schema.ex:70` keeps
   `embeds_one(:elevenlabs, ElevenLabs, …)` and `config/schema/eleven_labs.ex`
   stays in the `config` component. Voice owns the section as manifest data
   (`owns.config`), which the R1 checker enforces. Because the embed is always
   compiled, a config file with `elevenlabs:` loads whether or not the voice
   provider is installed; no unknown-section handling is needed.
2. **`api_key` redaction stays** at `schema.ex:232-241`, untouched.
3. **The `init` contribution moves behind a registry.** Add
   `Aiur.Voice.init_contribution/0` returning
   `%{id: :elevenlabs, prompt: fun/3, resume: fun/1, yaml: fun/1}` (the three
   bodies are today's `Init.ElevenLabs.prompt_eleven_labs/3`, the
   `resume.ex:65-67` entry and the `templates.ex:132-133` section). Register it
   in an ordered `:aiur, :init_contributions` list in `src/config/config.exs`,
   in the MP-R1-C4-T01 registry style. `Aiur.Init`, `Init.Resume` and
   `Init.Templates` iterate that list at the position the ElevenLabs step holds
   today, so the prompt order is unchanged.
4. **The `init` output is byte-identical.** The template golden test
   (`src/test/aiur/init/templates_test.exs`, 21 elevenlabs references) and
   `src/test/aiur/init/resume_test.exs` (11) keep their expectations unchanged.
5. **Provider nil:** the contribution list is empty for voice, so `aiur init`
   skips the ElevenLabs question and writes no `elevenlabs:` block. This only
   happens in the C3 core-only CI build; the default release always includes
   voice (DESIGN-R5 §3 Q1).

## Implementation steps

1. Add the `owns.config` and `owns.env` entries for the voice component in
   `components.json` and run the R1 checker.
2. Add `Aiur.Voice.init_contribution/0` and the `:init_contributions` registry
   entry.
3. Replace the direct `ElevenLabs` calls in `init.ex:171`,
   `resume.ex:39,65-67,154-156` and `templates.ex:109,132-133` with iteration
   over the registry.
4. Remove the `ElevenLabs` aliases from `init.ex`, `resume.ex` and
   `templates.ex`. `schema.ex` keeps its alias (step 1 of the design).

## Non-happy paths

- **Config with `elevenlabs:` and no provider:** loads, because the embed is
  always compiled (design item 1).
- **Registry missing from app env:** `aiur init` raises
  `{:error, :init_contributions_unregistered}`, the same shape as MP-R1-C4-T01's
  `:config_checks_unregistered`; it never silently skips every contribution.
- **An `ELEVENLABS_API_KEY` env reference in YAML:** resolution is unchanged
  (`$ELEVENLABS_API_KEY` syntax, `website/docs-app/apis/elevenlabs.md:29`).

## Compatibility and rollout

- Config keys are unchanged. `scripts/check-config-docs.py` must keep passing
  with no docs edit, and needs no change because the embed line stays.
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
- "init iterates registered contributions in order": register a test
  contribution before and after `:elevenlabs`; assert the prompts run in that
  order and the YAML sections appear in that order.
  - Mutation: call `Init.ElevenLabs` directly again (bypassing the registry).
    The test fails because the test contributions never run.
- "with no voice contribution, init writes no elevenlabs block": empty the
  registry for voice; assert the generated YAML has no `elevenlabs:` key and
  the prompt list has no ElevenLabs question.
  - Mutation: keep a hard-coded `{{ELEVENLABS_SECTION}}` fill. The test fails.
- "components.json assigns elevenlabs and ELEVENLABS_API_KEY to voice": run
  the R1 ownership checker on the edited manifest.
  - Mutation: remove the `owns.config` entry. The O-config rule exits 1.

The existing templates golden test must pass unchanged. That is the
byte-identity oracle.

## Completion and handoff

- [ ] `git grep -n "ElevenLabs" -- src/lib/aiur/init.ex src/lib/aiur/init/resume.ex src/lib/aiur/init/templates.ex`
  is empty. (`schema.ex` keeps its embed line by RQ4.)
- [ ] The config docs checker is green with no docs change.
- [ ] Docs: none. Keys are unchanged, and `reference/configuration.md` is
  untouched.
- **Dependents:** C3-T01.
