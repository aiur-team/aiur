defmodule Aiur.CodingAgent.Providers.Claude do
  @moduledoc "Registry definitions for Claude's app-server and REPL transports."

  alias Aiur.ModelCatalog
  alias Aiur.ProviderMeterProbe
  alias Aiur.RunTelemetry.Lifecycle

  @spec headless() :: Aiur.CodingAgent.Backend.capabilities()
  def headless do
    %{
      adapter: Aiur.Claude.CodingAgent,
      transcript: Aiur.Claude.Transcript,
      family: "claude",
      config_default: true,
      rate_limit_fallback_target: true,
      skill_install: %{path: ".claude/skills"},
      configurable: true,
      accounts: %{kind: :profile, multi: :available, usage: :claude_api, supported: true},
      init_order: 0,
      default_command: "aiur-claude",
      model_catalog: &ModelCatalog.extract_claude/1,
      install_hint: "install it with: npm install -g aiur-claude",
      can_interrupt: true,
      safe_checkpoints: [:notification],
      control_application_confirmation: :confirmed,
      remote_control: true,
      # Remote control physically runs on the persistent-REPL transport,
      # so an RC-promoted claude issue dispatches claude-repl (carrying
      # the resolved model). Declared here so dispatch code never
      # hard-codes the swap.
      remote_transport: "claude-repl",
      # The headless `bash -c` wrapper does not exec; report its os pid so
      # brutal-kill teardown can tree-reap the reparented claude/node children.
      runtime_report: :headless_wrapper,
      # aiur-claude's thread/resume restores the wrapper around the durable
      # Claude CLI transcript under the selected CLAUDE_CONFIG_DIR.
      resumable: true,
      models: ["opus", "sonnet", "haiku", "opus-4-8", "sonnet-4-6", "haiku-4-5"],
      # `claude --model` resolves `opus`/`sonnet`/`haiku` to the newest
      # version in that family itself, so the generic tags above are passed
      # through untouched rather than pinned to a version aiur happens to
      # know about.
      model_aliases: :native,
      efforts: [],
      presentation: %{
        order: 1,
        label: "Claude",
        logo: "/provider-assets/claude-symbol.svg",
        token_icon: "/provider-assets/codex-token.svg",
        css_class: "is-claude",
        command_color: "#f2a76b",
        command_border: "rgba(242, 167, 107, 0.4)",
        unit_color: "#f0a878",
        unit_border: "rgba(240, 168, 120, 0.4)",
        unit_background: "rgba(240, 168, 120, 0.12)"
      },
      pricing: %{
        dimensions: %{
          context_tier: %{allowed: [:not_applicable], default: :not_applicable, required: false},
          cache_write_duration: %{allowed: [:five_minutes, :one_hour, :not_applicable], default: nil, required: true}
        },
        component_dimensions: %{
          default: %{context_tier: [:not_applicable], cache_write_duration: [:not_applicable]},
          cache_creation_input: %{context_tier: [:not_applicable], cache_write_duration: [:five_minutes, :one_hour]}
        }
      },
      usage: %{adapters: [Aiur.Usage.Headless.Claude.RequestUsage]},
      meter_probe: &ProviderMeterProbe.probe_usage_api/3,
      run_telemetry: &Lifecycle.decode_claude_operation/1,
      account_generation: %{
        backends: [:app_server],
        trusted_sources: [:claude_app_server],
        auth_modes: ~w(subscription api_key)
      }
    }
  end

  @spec repl() :: Aiur.CodingAgent.Backend.capabilities()
  def repl do
    %{
      adapter: Aiur.Claude.ReplAgent,
      transcript: Aiur.Claude.Transcript,
      family: "claude",
      accounts: %{kind: :profile, multi: :available, usage: :claude_api, supported: true},
      # A persistent REPL carries the primary session handle. It must never
      # be selected as a usage-limit replacement for a different session.
      rate_limit_fallback_target: false,
      # The REPL is launched by its adapter rather than the init wizard, but
      # rate-limit fallback still needs a registry-owned readiness command.
      default_command: "claude",
      model_catalog: &ModelCatalog.extract_claude/1,
      model_catalog_backend: "claude",
      # Executor messages are typed straight into the live pane and the
      # agent's native input queue folds them in, so there is no
      # checkpoint to hold at — `safe_checkpoints` stays empty and
      # delivery is immediate. Interrupt is the explicit out-of-band
      # action: `ReplAgent.interrupt/1` sends Ctrl+C to the pane, cutting
      # the active turn so a queued message drains right away.
      can_interrupt: true,
      safe_checkpoints: [],
      immediate_delivery: true,
      control_application_confirmation: :confirmed,
      remote_control: true,
      # A tmux/RC start failure must never strand an issue: a failed
      # claude-repl spawn falls back once to the headless claude
      # backend. Declared here so the fallback never lives in a
      # dispatch `case`.
      fallback_backend: "claude",
      run_telemetry: &Lifecycle.decode_claude_operation/1,
      # Only the hook-driven RC REPL needs the pane display tailer; every
      # other backend streams its own rich transcript.
      rc_display_tail: true,
      # The persistent pane + REPL os pid are what an abort path must reap.
      runtime_report: :repl_pane,
      # The REPL spawns the `claude` CLI directly, so a respawn after an aiur
      # restart can `--resume <session-id>` against the on-disk transcript
      # jsonl (the session id is the transcript filename). The runner injects
      # the persisted handle's id and `ReplAgent` degrades to a clean start
      # when that transcript is gone (issue #613, follow-up to #378).
      resumable: true,
      models: ["opus", "sonnet", "haiku", "opus-4-8", "sonnet-4-6", "haiku-4-5"],
      model_aliases: :native,
      efforts: ["low", "medium", "high", "xhigh", "max"]
    }
  end
end
