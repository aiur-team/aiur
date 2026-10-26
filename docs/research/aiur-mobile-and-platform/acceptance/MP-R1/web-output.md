# MP-R1 web output

Commands target main `889212aa39a2fb992da7942c6e4236f7b70be376`.
Local checkout prefixes are rendered as `<isolated-main>` or `<workspace>`;
ANSI color codes and blank output lines are removed. Result lines are otherwise unchanged.

## 04-contracts-install

Working directory: `.`.

Command:

```sh
npm ci --prefix packages/aiur-contracts --ignore-scripts
```

```text
SHA: 889212aa39a2fb992da7942c6e4236f7b70be376
UTC start: 2026-10-26T11:39:09.278196Z
UTC end: 2026-10-26T11:39:09.978755Z
Exit code: 0
added 20 packages, and audited 21 packages in 627ms
9 packages are looking for funding
  run `npm fund` for details
1 moderate severity vulnerability
To address all issues, run:
  npm audit fix
Run `npm audit` for details.
```

## 05-contracts-check

Working directory: `.`.

Command:

```sh
npm run check --prefix packages/aiur-contracts
```

```text
SHA: 889212aa39a2fb992da7942c6e4236f7b70be376
UTC start: 2026-10-26T11:39:10.005184Z
UTC end: 2026-10-26T11:39:13.100386Z
Exit code: 0
> @aiur/contracts@0.0.0 check
> node scripts/generate.mjs --check && node scripts/validate.mjs && node scripts/check-fixture-types.mjs && tsc --noEmit
```

## 06-contracts-tests

Working directory: `.`.

Command:

```sh
npm test --prefix packages/aiur-contracts
```

```text
SHA: 889212aa39a2fb992da7942c6e4236f7b70be376
UTC start: 2026-10-26T11:39:13.131528Z
UTC end: 2026-10-26T11:39:15.144901Z
Exit code: 0
> @aiur/contracts@0.0.0 test
> npm run build && node --test test/*.test.mjs
> @aiur/contracts@0.0.0 build
> tsc
✔ golden report and refusal validate against v1 schemas (1.315454ms)
✔ missing report contract is invalid (0.335333ms)
✔ missing report contract_version is invalid (0.157114ms)
✔ missing report boot_id is invalid (0.183842ms)
✔ missing report revision is invalid (0.477291ms)
✔ missing report observed_at is invalid (0.184333ms)
✔ missing report age_ms is invalid (0.211409ms)
✔ missing report freshness is invalid (0.164219ms)
✔ missing report min_client_versions is invalid (0.1776ms)
✔ missing report machine is invalid (0.263567ms)
✔ missing report instance is invalid (0.225723ms)
✔ missing report repository is invalid (0.167797ms)
✔ missing report executor is invalid (0.140275ms)
✔ missing report capabilities is invalid (0.098208ms)
✔ missing refusal error is invalid (0.165391ms)
✔ missing refusal capability is invalid (0.104765ms)
✔ missing refusal state is invalid (0.108107ms)
✔ missing refusal reason is invalid (0.106203ms)
✔ missing refusal revision is invalid (0.079561ms)
✔ missing refusal boot_id is invalid (0.086571ms)
✔ unknown IDs and additive fields remain valid (1.103626ms)
✔ unavailable entries require a known non-null reason (0.289313ms)
✔ nullable identity and provider sections preserve unknown state (0.190264ms)
✔ documented harness pattern matches exactly one valid segment (0.247161ms)
✔ exported reasons match schema and contain every golden reason (0.803746ms)
✔ dependency refusals and report entries require dependency IDs (0.324711ms)
✔ absent and unknown executors may omit reserved identity fields (0.136854ms)
✔ merge policy modes validate without changing existing v1 reports (1.047081ms)
✔ agents golden fixture validates (1.208358ms)
✔ agents requires its contract marker (0.249364ms)
✔ agents rejects another contract version (0.127883ms)
✔ agents permits additive fields within v1 (0.124847ms)
✔ status golden fixture validates (0.161136ms)
✔ status requires its contract marker (0.301868ms)
✔ status rejects another contract version (0.206811ms)
✔ status permits additive fields within v1 (0.125358ms)
✔ ticket golden fixture validates (0.184915ms)
✔ ticket requires its contract marker (0.384153ms)
✔ ticket rejects another contract version (0.336448ms)
✔ ticket permits additive fields within v1 (0.152809ms)
✔ ticket cancel golden fixture validates (0.115105ms)
✔ ticket cancel requires its contract marker (0.139521ms)
✔ ticket cancel rejects another contract version (0.095925ms)
✔ ticket cancel permits additive fields within v1 (0.110421ms)
✔ ticket usage golden fixture validates (0.200885ms)
✔ ticket usage requires its contract marker (0.266969ms)
✔ ticket usage rejects another contract version (0.301738ms)
✔ ticket usage permits additive fields within v1 (0.15969ms)
✔ ticket progress golden fixture validates (0.066396ms)
✔ ticket progress requires its contract marker (0.127591ms)
✔ ticket progress rejects another contract version (0.081061ms)
✔ ticket progress permits additive fields within v1 (0.058384ms)
✔ ticket spend cap golden fixture validates (0.070215ms)
✔ ticket spend cap requires its contract marker (0.123648ms)
✔ ticket spend cap rejects another contract version (0.08408ms)
✔ ticket spend cap permits additive fields within v1 (0.08118ms)
✔ ticket spend cap reached golden fixture validates (0.066172ms)
✔ ticket spend cap reached requires its contract marker (0.097946ms)
✔ ticket spend cap reached rejects another contract version (0.075213ms)
✔ ticket spend cap reached permits additive fields within v1 (0.064406ms)
✔ ticket progress preserves explicitly unknown readings (0.470601ms)
✔ ticket usage accepts stale and known-empty states (0.37754ms)
✔ spend-cap reached event requires the distinct budget_exhausted end state (0.188848ms)
✔ ticket cancel reserves exit evidence for an observed process exit (0.347461ms)
✔ status accepts nullable polling and structured CI results emitted by the presenter (0.240254ms)
✔ ticket accepts the live retrying shape and absent capabilities (0.229623ms)
ℹ tests 66
ℹ suites 0
ℹ pass 66
ℹ fail 0
ℹ cancelled 0
ℹ skipped 0
ℹ todo 0
ℹ duration_ms 290.420145
```

## 14-docs-install

Working directory: `website/docs-app`.

Command:

```sh
mise exec bun@1.4.2 -- bun install --frozen-lockfile
```

```text
SHA: 889212aa39a2fb992da7942c6e4236f7b70be376
UTC start: 2026-10-26T11:39:15.174264Z
UTC end: 2026-10-26T11:39:15.825361Z
Exit code: 0
mise WARN  tracking config: failed to ln -sf <isolated-main>/mise.toml /home/everdred/.local/state/mise/tracked-configs/b3628209ca1b5375: Read-only file system (os error 30)
bun install v1.4.2 (744846f84)
+ mermaid@11.17.0
+ vitepress@1.6.4
+ vitepress-plugin-mermaid@2.0.17
243 packages installed [573.00ms]
```

## 15-docs-tests

Working directory: `website/docs-app`.

Command:

```sh
mise exec bun@1.4.2 -- bun run test:components
```

```text
SHA: 889212aa39a2fb992da7942c6e4236f7b70be376
UTC start: 2026-10-26T11:39:15.849412Z
UTC end: 2026-10-26T11:39:16.454237Z
Exit code: 0
mise WARN  tracking config: failed to ln -sf <isolated-main>/mise.toml /home/everdred/.local/state/mise/tracked-configs/b3628209ca1b5375: Read-only file system (os error 30)
$ node --test scripts/test-components*.mjs
✔ minimum_voice_combination_follows_requires_and_handles_cycles (2.34214ms)
✔ minimum_combination_absent_or_incomplete (0.555569ms)
✔ projects_only_public_fields (1.552548ms)
✔ drops_feature_ids_and_flags (0.973466ms)
✔ planned_lists_only_public_unshipped (0.236163ms)
✔ planned_component_hidden_from_components (0.177854ms)
✔ missing_summary_throws (0.467305ms)
✔ empty_manifest_throws (0.187943ms)
✔ unknown_status_throws (0.181274ms)
✔ validates_public_arrays_and_install (0.441208ms)
✔ sorts_names_case_insensitively_within_status (6.437173ms)
✔ groups_by_goal_in_approved_order (3.711056ms)
✔ goal_required_for_non_planned (0.450866ms)
(!) Could not auto-determine entry point from rollupOptions or html files and there are no explicit optimizeDeps.include patterns. Skipping dependency pre-bundling.
✔ renders_missing_docs_and_empty_planned_without_placeholder_link (276.835367ms)
✔ renders_status_notes_full_fields_and_real_links (1.971298ms)
✔ planned_is_public_copy_only_and_shared_links_use_product_docs (1.183089ms)
ℹ tests 16
ℹ suites 0
ℹ pass 16
ℹ fail 0
ℹ cancelled 0
ℹ skipped 0
ℹ todo 0
ℹ duration_ms 528.548225
```

## 16-docs-build

Working directory: `website/docs-app`.

Command:

```sh
mise exec bun@1.4.2 -- bun run build
```

```text
SHA: 889212aa39a2fb992da7942c6e4236f7b70be376
UTC start: 2026-10-26T11:39:16.485217Z
UTC end: 2026-10-26T11:39:31.984551Z
Exit code: 0
mise WARN  tracking config: failed to ln -sf <isolated-main>/mise.toml /home/everdred/.local/state/mise/tracked-configs/b3628209ca1b5375: Read-only file system (os error 30)
$ vitepress build .
  vitepress v1.6.4
- building client + server bundles...
(!) Some chunks are larger than 500 kB after minification. Consider:
- Using dynamic import() to code-split the application
- Use build.rollupOptions.output.manualChunks to improve chunking: https://rollupjs.org/configuration-options/#output-manualchunks
- Adjust chunk size limit for this warning via build.chunkSizeWarningLimit.
✓ building client + server bundles...
- rendering pages...
✓ rendering pages...
build complete in 15.07s.
```

## 17-cli-reference

Working directory: `.`.

Command:

```sh
bash website/docs-app/scripts/check-cli-reference.sh && bash website/docs-app/scripts/test-check-cli-reference.sh
```

```text
SHA: 889212aa39a2fb992da7942c6e4236f7b70be376
UTC start: 2026-10-26T11:39:32.023661Z
UTC end: 2026-10-26T11:39:36.903019Z
Exit code: 0
check-cli-reference guard: all cases passed
```
