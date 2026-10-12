defmodule Aiur.CodingAgent.Providers.Codex do
  @moduledoc "Registry definition for the Codex app-server backend."

  alias Aiur.Codex.SessionRecovery
  alias Aiur.ModelCatalog
  alias Aiur.ProviderMeterProbe
  alias Aiur.RunTelemetry.Lifecycle

  @spec entry() :: Aiur.CodingAgent.Backend.capabilities()
  def entry do
    %{
      adapter: Aiur.Codex.CodingAgent,
      transcript: Aiur.Codex.Transcript,
      family: "codex",
      accounts: %{kind: :profile, multi: :available, usage: :codex_probe, supported: true},
      default: true,
      rate_limit_fallback: "claude",
      rate_limit_fallback_target: false,
      skill_install: %{path: ".codex/skills", link_to: ".claude/skills"},
      configurable: true,
      init_order: 1,
      default_command: "codex app-server",
      model_catalog: &ModelCatalog.extract_codex/1,
      can_interrupt: true,
      safe_checkpoints: [:notification, :tool_result],
      control_application_confirmation: :confirmed,
      remote_control: false,
      # The codex app-server can rejoin a prior thread across an aiur restart
      # via `thread/resume` against its on-disk rollout, so a respawned
      # session continues rather than cold-starting (issue #378).
      resumable: true,
      recoverable_session_error: &SessionRecovery.recoverable?/1,
      models: [
        "gpt-5.6-sol",
        "gpt-5.6-terra",
        "gpt-5.6-luna",
        "gpt-5.5",
        "gpt-5.4",
        "gpt-5.5-mini",
        "gpt-5.4-mini"
      ],
      # codex has no generic model alias of its own, so aiur derives one per
      # family from the ids above and resolves it to the newest member (see
      # `resolve_model/2`). `codex:sol` therefore keeps following the latest
      # `*-sol` release instead of naming a version that will be retired.
      model_aliases: :derived,
      efforts: ["none", "low", "medium", "high", "xhigh", "max"],
      # Provider-level presentation descriptor, keyed by family, used by every
      # dashboard/strip surface so a new backend renders from its registry
      # entry rather than a per-provider `case`. `order` fixes card ordering.
      presentation: %{
        order: 0,
        label: "Codex",
        logo: "/provider-assets/codex-color.svg",
        token_icon: "/provider-assets/claude-token.svg",
        css_class: "is-codex",
        command_color: "#8fbcff",
        command_border: "rgba(143, 188, 255, 0.4)",
        unit_color: "#8fbcff",
        unit_border: "rgba(143, 188, 255, 0.4)",
        unit_background: "rgba(143, 188, 255, 0.12)"
      },
      pricing: %{
        dimensions: %{
          context_tier: %{allowed: [:short_context, :long_context], default: nil, required: true},
          cache_write_duration: %{allowed: [:not_applicable], default: :not_applicable, required: false}
        },
        component_dimensions: %{
          default: %{context_tier: [:short_context, :long_context], cache_write_duration: [:not_applicable]}
        }
      },
      usage: %{adapters: [Aiur.Usage.Headless.Codex.ThreadUsage, Aiur.Usage.Headless.Codex.TurnUsage]},
      meter_probe: &ProviderMeterProbe.probe_session/3,
      run_telemetry: &Lifecycle.decode_codex_operation/1,
      account_generation: %{
        backends: [:app_server],
        trusted_sources: [:codex_app_server],
        auth_modes: ~w(apikey chatgpt chatgptAuthTokens headers agentIdentity personalAccessToken bedrockApiKey)
      }
    }
  end
end
