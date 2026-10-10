# Aiur Service Specification — Domain Model and Workflow Specification (§4–§5)

Part of the [Aiur Service Specification](../../SPEC.md); section numbers are unchanged.

## 4. Core Domain Model

### 4.1 Entities

#### 4.1.1 Issue

Normalized issue record used by orchestration, prompt rendering, and observability output.

Fields:

- `id` (string)
  - Stable tracker-internal ID.
- `identifier` (string)
  - Human-readable ticket key (example: `ABC-123`).
- `title` (string)
- `description` (string or null)
- `priority` (integer or null)
  - Lower numbers are higher priority in dispatch sorting.
- `state` (string)
  - Current tracker state name.
- `branch_name` (string or null)
  - Tracker-provided branch metadata if available.
- `url` (string or null)
- `labels` (list of strings)
  - Normalized to lowercase.
- `blocked_by` (list of blocker refs)
  - Each blocker ref contains:
    - `id` (string or null)
    - `identifier` (string or null)
    - `state` (string or null)
- `created_at` (timestamp or null)
- `updated_at` (timestamp or null)

#### 4.1.2 Workflow Definition

Parsed `.aiur/config` payload:

- `config` (map)
  - YAML root object.
- `prompt_template` (string)
  - Contents of the resolved `prompt_file:` template, trimmed, or the built-in default when no
    `prompt_file:` is configured.

#### 4.1.3 Service Config (Typed View)

Typed runtime values derived from `WorkflowDefinition.config` plus environment resolution.

Examples:

- poll interval
- workspace root
- active and terminal issue states
- concurrency limits
- coding-agent executable/args/timeouts
- workspace hooks

#### 4.1.4 Workspace

Filesystem workspace assigned to one issue identifier.

Fields (logical):

- `path` (absolute workspace path)
- `workspace_key` (sanitized issue identifier)
- `created_now` (boolean, used to gate `after_create` hook)

#### 4.1.5 Run Attempt

One execution attempt for one issue.

Fields (logical):

- `issue_id`
- `issue_identifier`
- `attempt` (integer or null, `null` for first run, `>=1` for retries/continuation)
- `workspace_path`
- `started_at`
- `status`
- `error` (OPTIONAL)

#### 4.1.6 Live Session (Agent Session Metadata)

State tracked while a coding-agent subprocess is running.

Fields:

- `session_id` (string, `<thread_id>-<turn_id>`)
- `thread_id` (string)
- `turn_id` (string)
- `codex_app_server_pid` (string or null)
- `last_codex_event` (string/enum or null)
- `last_codex_timestamp` (timestamp or null)
- `last_codex_message` (summarized payload)
- `codex_input_tokens` (integer)
- `codex_output_tokens` (integer)
- `codex_total_tokens` (integer)
- `last_reported_input_tokens` (integer)
- `last_reported_output_tokens` (integer)
- `last_reported_total_tokens` (integer)
- `turn_count` (integer)
  - Number of coding-agent turns started within the current worker lifetime.

#### 4.1.7 Retry Entry

Scheduled retry state for an issue.

Fields:

- `issue_id`
- `identifier` (best-effort human ID for status surfaces/logs)
- `attempt` (integer, 1-based for retry queue)
- `due_at_ms` (monotonic clock timestamp)
- `timer_handle` (runtime-specific timer reference)
- `error` (string or null)

#### 4.1.8 Orchestrator Runtime State

Single authoritative in-memory state owned by the orchestrator.

Fields:

- `poll_interval_ms` (configured base poll interval)
- `effective_poll_interval_ms` (current interval after widening and tracker floors)
- `max_concurrent_agents` (current effective global concurrency limit)
- `running` (map `issue_id -> running entry`)
- `claimed` (set of issue IDs reserved/running/retrying)
- `retry_attempts` (map `issue_id -> RetryEntry`)
- `completed` (set of issue IDs; bookkeeping only, not dispatch gating)
- `codex_totals` (aggregate tokens + runtime seconds)
- `codex_rate_limits` (latest rate-limit snapshot from agent events)

### 4.2 Stable Identifiers and Normalization Rules

- `Issue ID`
  - Use for tracker lookups and internal map keys.
- `Issue Identifier`
  - Use for human-readable logs and workspace naming.
- `Workspace Key`
  - Derive from `issue.identifier` by replacing any character not in `[A-Za-z0-9._-]` with `_`.
  - Use the sanitized value for the workspace directory name.
- `Normalized Issue State`
  - Compare states after `lowercase`.
- `Session ID`
  - Compose from coding-agent `thread_id` and `turn_id` as `<thread_id>-<turn_id>`.

## 5. Workflow Specification (Repository Contract)

### 5.1 File Discovery and Path Resolution

Config file path precedence:

1. Explicit application/runtime setting (set by CLI startup path).
2. Default: `.aiur/config` in the current process working directory.

Loader behavior:

- If the file cannot be read, return `missing_workflow_file` error.
- The config file is expected to be repository-owned and version-controlled.

### 5.2 File Format

`.aiur/config` is a pure YAML file.

Design note:

- `.aiur/config` SHOULD be self-contained enough to describe and run different workflows (prompt
  reference, runtime settings, hooks, and tracker selection/config) without requiring out-of-band
  service-specific configuration.

Parsing rules:

- The file is parsed as a single YAML document.
- The YAML MUST decode to a map/object; non-map YAML is an error.
- An optional `prompt_file:` key names a prompt template; its contents become the prompt body.
- When `prompt_file:` is absent or empty, a built-in default prompt is used.
- A `prompt_file:` that names a file which cannot be read is a `missing_prompt_file` error.
- The prompt body is trimmed before use.

Returned workflow object:

- `config`: YAML root object (not nested under a `config` key).
- `prompt_template`: trimmed prompt body from `prompt_file:` or the built-in default.

### 5.3 Config Schema

Top-level keys:

- `prompt_file`
- `tracker`
- `polling`
- `workspace`
- `hooks`
- `hooks_file`
- `agent`
- `codex`

Unknown keys SHOULD be ignored for forward compatibility.

Note:

- The config is extensible. Extensions MAY define additional top-level keys without
  changing the core schema above.
- Extensions SHOULD document their field schema, defaults, validation rules, and whether changes
  apply dynamically or require restart.

#### 5.3.0 `prompt_file` (string)

- OPTIONAL path to a prompt template file (typically Liquid/Markdown).
- Relative paths are resolved relative to the directory containing `.aiur/config`.
- When absent or empty, a built-in default prompt is used.
- A named file that cannot be read is a `missing_prompt_file` error.

#### 5.3.0.1 `hooks_file` (string)

- OPTIONAL path to a YAML file whose keys become the `hooks:` map (same fields as the inline `hooks:` object in 5.3.4).
- Relative paths are resolved relative to the directory containing `.aiur/config`.
- When set, it REPLACES any inline `hooks:` block; when absent or empty, the inline `hooks:` block (if any) is used unchanged.
- A named file that cannot be read is a `missing_hooks_file` error; a file whose top-level YAML is not a map is an `invalid_hooks_file` error.
- `aiur init` scaffolds `.aiur/hooks` and the generated `.aiur/config` references it via `hooks_file: hooks`.

#### 5.3.1 `tracker` (object)

Fields:

- `kind` (string)
  - REQUIRED for dispatch.
  - Current supported value: `linear`
- `endpoint` (string)
  - Default for `tracker.kind == "linear"`: `https://api.linear.app/graphql`
- `api_key` (string)
  - MAY be a literal token or `$VAR_NAME`.
  - Canonical environment variable for `tracker.kind == "linear"`: `LINEAR_API_KEY`.
  - If `$VAR_NAME` resolves to an empty string, treat the key as missing.
- `project_slug` (string)
  - REQUIRED for dispatch when `tracker.kind == "linear"`.
- `active_states` (list of strings)
  - Default: `Todo`, `In Progress`
- `terminal_states` (list of strings)
  - Default: `Closed`, `Cancelled`, `Canceled`, `Duplicate`, `Done`

#### 5.3.2 `polling` (object)

Fields:

- `interval_seconds` (positive integer)
  - Default: `120`
  - Changes SHOULD be re-applied at runtime and affect future tick scheduling without restart.
- `idle_widen_factor` (number from `1.0` through `100.0`)
  - Default: `5.0`
  - Multiplies the base interval while no agent is actively running and composes with other widening factors.

#### 5.3.3 `workspace` (object)

Fields:

- `root` (path string or `$VAR`)
  - Default: `<system-temp>/aiur_workspaces`
  - `~` is expanded.
  - Relative paths are resolved relative to the directory containing `.aiur/config`.
  - The effective workspace root is normalized to an absolute path before use.

#### 5.3.4 `hooks` (object)

Fields:

- `after_create` (multiline shell script string, OPTIONAL)
  - Runs only when a workspace directory is newly created.
  - Failure aborts workspace creation.
- `before_run` (multiline shell script string, OPTIONAL)
  - Runs before each agent attempt after workspace preparation and before launching the coding
    agent.
  - Failure aborts the current attempt.
  - A recognized stale-workspace refresh refusal on a `todo` issue MAY recreate the workspace
    and retry the hook once; dirty workspaces for resumed active issues must still fail closed.
- `after_run` (multiline shell script string, OPTIONAL)
  - Runs after each agent attempt (success, failure, timeout, or cancellation) once the workspace
    exists.
  - Failure is logged but ignored.
- `before_remove` (multiline shell script string, OPTIONAL)
  - Runs before workspace deletion if the directory exists.
  - Failure is logged but ignored; cleanup still proceeds.
- `timeout_ms` (integer, OPTIONAL)
  - Default: `60000`
  - Applies to all workspace hooks.
  - Invalid values fail configuration validation.
  - Changes SHOULD be re-applied at runtime for future hook executions.

#### 5.3.5 `agent` (object)

Fields:

- `max_concurrent_agents` (integer)
  - Default: `10`
  - Changes SHOULD be re-applied at runtime and affect subsequent dispatch decisions.
- `max_concurrent_builds` (non-negative integer)
  - Default: `2`.
  - Caps agent-launched `mix compile` and `mix test` commands across local workspaces for
    the current OS user. `0` deliberately disables this concurrency cap.
  - When enabled, implementations MUST fail a gated Mix command without invoking Mix if
    the shared gate directory or lease mechanism is unavailable. The failure MUST be
    bounded and identify how to repair or deliberately disable the gate.
  - Linux lease liveness MUST NOT depend on sandbox-local PID/PGID values. Those values
    MAY be retained as diagnostics, but shared ownership and reclamation require a
    host-stable primitive.
- `max_turns` (positive integer)
  - Default: `20`
  - Limits the number of coding-agent turns within one worker session.
  - Invalid values fail configuration validation.
- `max_retry_backoff_ms` (integer)
  - Default: `300000` (5 minutes)
  - Changes SHOULD be re-applied at runtime and affect future retry scheduling.
- `max_concurrent_agents_by_state` (map `state_name -> positive integer`)
  - Default: empty map.
  - State keys are normalized (`lowercase`) for lookup.
  - Invalid entries (non-positive or non-numeric) are ignored.
- `kind` (backend string)
  - The global coding-agent backend used when an issue resolves to no more specific backend.
  - MUST be one of the implementation's known backends.
- `routing` (map `complexity_level -> backend string`)
  - Default: empty map.
  - Maps an issue's highest `complexity:N` label to a backend, so a single run MAY drive
    multiple backends concurrently. Levels not present in the map fall through to `agent.kind`.
  - Keys MUST be positive integers (string keys are normalized to integers); values MUST be
    known backends. Invalid entries fail configuration validation.
  - A per-issue `model:<backend>` label overrides this table; the table overrides `agent.kind`.

#### 5.3.6 `codex` (object)

Fields:

For Codex-owned config values such as `approval_policy`, `thread_sandbox`, and
`turn_sandbox_policy`, supported values are defined by the targeted Codex app-server version.
Implementors SHOULD treat them as pass-through Codex config values rather than relying on a
hand-maintained enum in this spec. To inspect the installed Codex schema, run
`codex app-server generate-json-schema --out <dir>` and inspect the relevant definitions referenced
by `v2/ThreadStartParams.json` and `v2/TurnStartParams.json`. Implementations MAY validate these
fields locally if they want stricter startup checks.

- `command` (string shell command)
  - Default: `codex app-server`
  - The runtime launches this command via `bash -lc` in the workspace directory.
  - The launched process MUST speak a compatible app-server protocol over stdio.
- `approval_policy` (Codex `AskForApproval` value)
  - Default: implementation-defined.
- `thread_sandbox` (Codex `SandboxMode` value)
  - Default: implementation-defined.
- `turn_sandbox_policy` (Codex `SandboxPolicy` value)
  - Default: implementation-defined.
  - When the value is a Codex `workspaceWrite` policy, implementations MUST add the
    runtime issue workspace to `writableRoots` before starting a turn. When the local
    build gate is enabled, implementations MUST also prepare and add its canonical
    shared directory. Existing roots and writable Git metadata roots are preserved.
    This keeps both agent-visible Git metadata and shared leases writable even when
    the workflow config supplies extra explicit roots.
  - Non-`workspaceWrite` policy types are passed through unchanged.
- `turn_timeout_ms` (integer)
  - Default: `3600000` (1 hour)
- `read_timeout_ms` (integer)
  - Default: `5000`
- `stall_timeout_ms` (integer)
  - Default: `300000` (5 minutes)
  - If `<= 0`, stall detection is disabled.

#### 5.3.12 `pr_watch` (extension, OPTIONAL)

Opt-in repo-wide PR comment monitoring. When `enabled` is false (the default), aiur only reacts to
comments on the `aiur/<id>` PRs it created. When enabled, two triggers let a code owner or
`github.trusted_accounts` member direct an agent on any PR in the repo:

- `enabled` (boolean) — Default `false`. Strict opt-in: untagged, un-commanded PRs are never acted on.
- `watch_label` (string) — Default `"watch"`. Combined with `github.label_prefix` (e.g. `agent:watch`);
  labelling a PR enrolls it for persistent monitoring of all its code-owner / trusted comments.
- `command_prefix` (string) — Default `"/aiur"`. A trusted comment starting with this prefix — or
  mentioning `github.bot_account` — handles that one comment, no label required (one-and-done).

Requires `github.bot_account` (the agent's reply identity, used by read-after-write reply verification)
and a CODEOWNERS file / `github.trusted_accounts` (the authors permitted to direct the agent). A
triggered agent works the PR's existing branch directly (PR-anchored, keyed by PR number rather than
`aiur/<id>`), replies on the review thread, and does not auto-resolve threads.

### 5.4 Prompt Template Contract

The prompt template referenced by `.aiur/config`'s `prompt_file:` (or the built-in default) is the
per-issue prompt template.

Rendering requirements:

- Use a strict template engine (Liquid-compatible semantics are sufficient).
- Unknown variables MUST fail rendering.
- Unknown filters MUST fail rendering.

Template input variables:

- `issue` (object)
  - Includes all normalized issue fields, including labels and blockers.
- `attempt` (integer or null)
  - `null`/absent on first attempt.
  - Integer on retry or continuation run.

Fallback prompt behavior:

- If the workflow prompt body is empty, the runtime MAY use a minimal default prompt
  (`You are working on an issue from Linear.`).
- Workflow file read/parse failures are configuration/validation errors and SHOULD NOT silently fall
  back to a prompt.

### 5.5 Workflow Validation and Error Surface

Error classes:

- `missing_workflow_file`
- `workflow_parse_error`
- `workflow_front_matter_not_a_map`
- `template_parse_error` (during prompt rendering)
- `template_render_error` (unknown variable/filter, invalid interpolation)

Dispatch gating behavior:

- Workflow file read/YAML errors block new dispatches until fixed.
- Template errors fail only the affected run attempt.
