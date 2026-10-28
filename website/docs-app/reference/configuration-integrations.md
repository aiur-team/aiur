# Integration configuration

## elevenlabs

Both capture clients stream audio to Aiur, and Aiur calls ElevenLabs with the credential below; interactive conversation also streams speech audio back to the browser. This is the only place the credential is configured, and neither the sidecar nor the browser holds it.

This optional section configures voice features; `aiur init` records declines as `enabled: false` and skips them on resume.

| Key | Type | Default | Controls | <!-- generated-reference:config-configuration-14 -->
| --- | --- | --- | --- |
| `elevenlabs.api_key` | string or nil | nil | ElevenLabs credential. Accepts a literal value or a `$ELEVENLABS_API_KEY` environment reference. Speech input needs Speech to Text permission; spoken replies also need Text to Speech permission. |
| `elevenlabs.enabled` | boolean | true | Enables ElevenLabs voice features. Set false to keep an explicit declined setup choice and suppress configured or environment-provided credentials. Existing configs without this key remain enabled. |
| `elevenlabs.language_code` | string | `eng` | ISO-639-3 transcription language. ElevenLabs uses `eng` for English. |
| `elevenlabs.voice_id` | string or nil | nil | Stock or owned ElevenLabs voice used for Dashboard interactive conversation replies. Find the identifier in **My Voices**; Aiur does not clone or manage voices. |

`ELEVENLABS_API_KEY` is the environment variable for the credential. When `elevenlabs.enabled` is true, an explicit `elevenlabs.api_key` value wins; when the key is absent, or is the `$ELEVENLABS_API_KEY` reference, the variable supplies it. `enabled: false` suppresses both sources. An environment variable set to the empty string resolves to no key.

The key is a secret. Keep it in `.env` and leave the `$ELEVENLABS_API_KEY` reference in the config file rather than pasting the value there. Aiur never logs the key, and the daemon scrubs every `*_API_KEY` variable, `ELEVENLABS_API_KEY` included, from agent process environments, local and SSH-launched alike, so no coding agent inherits it.

Configuring the key also adds an ElevenLabs meter beside the GitHub API meter on the Build page [usage strip](/concepts/build-history#usage-strip) and the Units [API meters](/concepts/units#api-meters). It reads the account credit quota and next-invoice amount due from `GET /v1/user/subscription`; with no key configured the meter is absent entirely.

## opencode
| Key | Type | Default | Controls | <!-- generated-reference:config-configuration-19 -->
| --- | --- | --- | --- |
| `opencode.bridge_host` | string | `127.0.0.1` | Aiur↔opencode bridge host. |
| `opencode.bridge_port` | integer | 4097 | Aiur↔opencode bridge port. |
| `opencode.command` | string | `opencode` | Command launching opencode. |
| `opencode.model_prefix` | string | `aiur` | Prefix for registered synthetic models. |
| `opencode.prewarm_disabled` | boolean | false | Disables opencode session pre-warming. |
| `opencode.serve_args` | array | `[]` | Extra `opencode serve` arguments. |
## experiments
The daemon owns [experiment](../concepts/experiments) writes through control RPC.

| Key | Type | Default | Description | <!-- generated-reference:config-configuration-20 -->
| --- | --- | --- | --- |
| `experiments.analyst.auto_request` | boolean | true | Request analysts automatically; false keeps on-demand CLI analysis available. |
| `experiments.auto.after_days` | integer | 14 | Initial after window length in days; positive. |
| `experiments.auto.after_max_days` | integer | 42 | Maximum after window days; at least after_days. |
| `experiments.auto.after_step_days` | integer | 7 | After window extension in days; positive. |
| `experiments.auto.before_days` | integer | 14 | Baseline window length in days; positive. |
| `experiments.auto.enabled` | boolean | true | Enable automatic line workers and the deploy ledger. |
| `experiments.auto.feature_label` | string | experiment:feature | Non-empty label marking measured feature epics. |
| `experiments.auto.feature_live_signal` | string | auto | One of auto, merge, release, daemon_boot. |
| `experiments.auto.feature_quiet_hours` | integer | 6 | Hours without new epic members; positive. |
| `experiments.auto.live_signal_max_wait_hours` | integer | 72 | Hours before falling back to merge time; positive. |
| `experiments.auto.metric_packs` | string list | ["delivery"] | Metric packs used for automatic experiments. |
| `experiments.auto.release_include_prereleases` | boolean | false | Include prerelease tags. |
| `experiments.auto.release_line` | boolean | true | Enable repository release lines. |
| `experiments.auto.release_min_interval_days` | integer | 7 | Minimum days between release lines; positive. |
| `experiments.auto.release_tag_pattern` | string | v* | Release tag pattern; non-empty, no whitespace. |
| `experiments.auto.version_line` | boolean | true | Enable base-semver version lines. |
| `experiments.checkpoint_interval_ms` | integer | 3600000 | Observation checkpoint interval in milliseconds; positive, reserved for snapshot capture. |
| `experiments.default_before_days` | integer | 14 | Default baseline window in days; positive. |
| `experiments.default_min_samples` | integer | 15 | Minimum samples per arm; positive. |
| `experiments.disabled_packs` | string list | [] | Pack IDs to disable; reserved for metric packs. |
| `experiments.enabled` | boolean | true | Start the experiment store. Disabled stores refuse writes. |
| `experiments.max_snapshot_observations` | integer | 50000 | Maximum observations in a snapshot; positive, reserved for snapshot capture. |
| `experiments.pack_dirs` | string list | [".aiur/experiments/packs"] | Consumer metric pack directories, relative to the base checkout; reserved for metric packs. |
| `experiments.script_timeout_ms` | integer | 60000 | Script metric timeout in milliseconds; positive, reserved for metric packs. |
