# Plan — De-hardcode the `:codex`/`:claude` provider union (registry-driven backends)

Issue: #1439 (complexity:4). Prerequisite for multi-provider support
(DeepSeek/Kimi/OpenRouter). Research: `docs/research/multi-provider-backends.md`
on `executor-handoff`.

## Goal

The registry promise in `coding_agent/backend.ex` ("adding a backend must
require nothing else") holds for the runtime hot path but is false for config,
metering/pricing, mid-ticket switching, and presentation — **54 files** hardcode
the `:codex | :claude` union. Make each of those subsystems resolve backend
identity from the registry so a backend added *only* via a `backends/0` entry
routes, dispatches, meters, prices, and renders with no edits elsewhere.

Two open bugs sit in this layer and are fixed first so new provider meters are
not built on top of them.

## Key design decision — provider descriptor keyed by *family*

Metering, pricing, and presentation key on the **provider family** (`:codex`,
`:claude`), not the transport backend (`claude` and `claude-repl` share family
`claude`). Config sections are also family-named (`claude:`, `codex:`). So the
new descriptor is provider/family-level, derived from the registry `:family`
values, exposed through accessors on `Aiur.CodingAgent` (and a
`Aiur.CodingAgent.Provider` descriptor module). Runtime dispatch keeps keying on
the backend string as today.

Each provider descriptor supplies: display `label`; presentation assets
(`logo_svg`, `token_icon_svg`, `css_class`, brand colors); config schema module +
section name; usage adapters; pricing dimension rules (valid context tiers /
cache-write durations, defaults, required dimensions); auth modes + trusted
sources; meter observation strategy + source atom.

## Work breakdown

Increment 0 — bug fixes (DONE):
- #1436 — streamdeck `providerSegment` fabricated 0% when `used_percent` absent.
  Guard the duration-less fallback on a finite `used_percent`; else `hasData:false`.
- #1406 — usage probe workspace never created / at bare root. Fold into the
  owner/repo-namespaced tree via `Workspace.workspace_path_under/2`.

Increment 1 — registry provider descriptor + test-only fake backend:
- Add family-level descriptor to the registry + accessors (`families/0`,
  `provider_atoms/0`, descriptor lookups).
- Register a `test`-env-only fake backend + config section to prove the paths.

Increment 2 — subsystem C (mid-ticket switching):
- `rate_limit_fallback.ex`: read primary/fallback from config, not module attrs.
- `config/schema/agent.ex`: validate `rate_limit_fallback` against
  `known_backends()` (like `switch_model_on_ratelimit`), not `["", "claude"]`.

Increment 3 — subsystem D (presentation):
- DONE: registry `presentation` descriptor (label, logo, token_icon, css_class,
  order) on the codex/claude entries + `provider_descriptors/0`,
  `provider_families/0`, `provider_descriptor/1` accessors. `run_summary_strip`,
  `units_table`, and `provider_meters_presenter` now render from the descriptor
  (behaviour identical for codex/claude — 47 presentation tests green).
- REMAINING: the per-provider SVG routes (`router.ex`) + `static_asset_controller`
  handlers, and the per-provider `dashboard.css` rules. The descriptor already
  centralizes the paths/classes; these static assets are a lower-risk follow-up
  (a new backend still needs its SVG files + one route + one CSS rule until then).

Increment 4 — subsystem B (usage/metering/pricing):
- DONE (provider enumeration): `@agent_families` (now
  `CodingAgent.provider_family_map/0`) in `usage/headless/context.ex`, and the
  `@providers` lists in `usage_envelope.ex`, `provider_meters/input.ex`
  (incl. the per-provider `*_app_server` `@sources`), `provider_meter_projection.ex`
  (compile-time attr so the `in @providers` guards still inline), and
  `usage/price_table/validator.ex` are all registry-derived. 197 usage tests green.
- REMAINING (per-provider dimension RULES — the hard part): the pricing/dimension
  validation that differs by provider (codex context-tiers vs claude
  cache-write-durations) in `usage/price_table/provider_dimensions.ex`,
  `usage/pricing/dimensions.ex`, `usage/headless/adapter.ex` defaults,
  `usage/headless/catalog.ex` adapters, `usage/price_table/data.ex`, and
  `provider_account_generation/validation.ex` (auth modes / trusted sources).
  These must move the per-provider rules into a `pricing`/`auth` descriptor on
  the registry entry.

Increment 5 — subsystem A (config) + E (misc):
- Registry-driven config-section resolution (`inferred_agent_kind`, fallbacks,
  `agent_executable`, install hints, routing order). Ecto embeds stay compile-
  time but their *set* derives from the registry list.
- Misc: metadata keys, skill install paths, `model:claude` label fallback,
  `backend_key`, telemetry dispatch.

## Acceptance

Fake backend registered only in the registry (test env) routes, dispatches,
meters, prices, and renders with zero edits elsewhere. `rate_limit_fallback`
accepts any registered backend pair. No behaviour change for codex/claude.
#1406 and #1436 closed.
</content>
