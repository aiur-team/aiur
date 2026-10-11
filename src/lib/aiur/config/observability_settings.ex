defmodule Aiur.Config.ObservabilitySettings do
  @moduledoc false

  alias Aiur.Workflow

  @default_prompt_template """
  You are working on a Linear issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """

  @default_telemetry_retention_max_bytes 64 * 1024 * 1024
  @default_telemetry_retention_max_age_days 30
  @minimum_telemetry_retention_prune_interval_bytes 1 * 1024 * 1024

  @doc """
  ElevenLabs speech-to-text credential for Stream Deck voice input, or `nil` when
  unconfigured. Resolved from `elevenlabs.api_key` (which may be a
  `$ELEVENLABS_API_KEY` reference) with the `ELEVENLABS_API_KEY` env var as the
  fallback. It is a secret: never log the returned value.
  """
  @spec elevenlabs_api_key() :: String.t() | nil
  def elevenlabs_api_key, do: Aiur.Config.settings!().elevenlabs.api_key

  @doc "ISO-639-3 transcription language for Stream Deck voice input."
  @spec elevenlabs_language_code() :: String.t()
  def elevenlabs_language_code, do: Aiur.Config.settings!().elevenlabs.language_code || "eng"

  @doc "ElevenLabs voice used for dashboard interactive conversation replies."
  @spec elevenlabs_voice_id() :: String.t() | nil
  def elevenlabs_voice_id do
    case Aiur.Config.settings!().elevenlabs.voice_id do
      voice_id when is_binary(voice_id) -> if String.trim(voice_id) == "", do: nil, else: voice_id
      _absent -> nil
    end
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case Workflow.current() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:aiur, :server_port_override) do
      port when is_integer(port) and port >= 0 -> port
      _ -> Aiur.Config.settings!().server.port
    end
  end

  @spec server_host() :: String.t()
  def server_host do
    case Application.get_env(:aiur, :server_host_override) do
      host when is_binary(host) and host != "" -> host
      _ -> Aiur.Config.settings!().server.host
    end
  end

  @spec server_tailscale_funnel?() :: boolean()
  def server_tailscale_funnel? do
    Aiur.Config.settings!().server.tailscale_funnel == true
  end

  @spec observability_enabled?() :: boolean()
  def observability_enabled? do
    Aiur.Config.settings!().observability.dashboard_enabled
  end

  @doc "Whether run telemetry recording is active. True by default; set `observability.telemetry_enabled: false` to opt out."
  @spec telemetry_enabled?() :: boolean()
  @spec telemetry_enabled?(term()) :: boolean()
  def telemetry_enabled?(settings \\ Aiur.Config.settings_uncached()) do
    case settings do
      {:ok, %{observability: observability}} -> observability.telemetry_enabled
      _other -> true
    end
  end

  @doc "Whether startup should verify the persisted Tailscale Funnel target."
  @spec build_order_funnel_health_check_enabled?(term()) :: boolean()
  def build_order_funnel_health_check_enabled?(settings \\ Aiur.Config.settings_uncached()) do
    case settings do
      {:ok, %{observability: %{build_order_funnel_health_check: enabled?}}} -> enabled?
      _other -> false
    end
  end

  @doc """
  Whether the `aiur run` upgrade-version notice is enabled. True by default;
  set `upgrade.check_enabled: false` to suppress the registry check entirely.
  Fails open (returns true) when the config cannot be read, so a config error
  never silently disables the notice.
  """
  @spec upgrade_check_enabled?() :: boolean()
  @spec upgrade_check_enabled?(term()) :: boolean()
  def upgrade_check_enabled?(settings \\ Aiur.Config.settings_uncached()) do
    case settings do
      {:ok, %{upgrade: upgrade}} -> upgrade.check_enabled
      _other -> true
    end
  end

  # Whether the dashboard may drive agents (Executor chat, pause). Writes are
  # enabled by default; set observability.dashboard_writable: false to disable.
  @spec dashboard_writable?() :: boolean()
  def dashboard_writable? do
    Aiur.Config.settings!().observability.dashboard_writable
  end

  @spec supervisor_decision_policy() :: %{
          allowed_kinds: [String.t()],
          allow_non_reversible: boolean()
        }
  def supervisor_decision_policy do
    decisions = Aiur.Config.settings!().decisions

    %{
      allowed_kinds: decisions.supervisor_allowed_kinds,
      allow_non_reversible: decisions.supervisor_allow_non_reversible
    }
  end

  @spec observability_refresh_ms() :: pos_integer()
  def observability_refresh_ms do
    Aiur.Config.settings!().observability.refresh_ms
  end

  @spec observability_render_interval_ms() :: pos_integer()
  def observability_render_interval_ms do
    Aiur.Config.settings!().observability.render_interval_ms
  end

  @doc """
  Heartbeat staleness threshold in milliseconds for daemon downtime detection.
  Defaults to 3,600,000 (1 hour).
  """
  @spec daemon_heartbeat_stale_ms() :: pos_integer()
  def daemon_heartbeat_stale_ms do
    Aiur.Config.settings!().monitoring.daemon_heartbeat_stale_ms
  end

  @doc """
  Retention limits for the durable run-telemetry stream.

  - `:max_bytes` — maximum file size in bytes. Whole boot groups are pruned
    from oldest to newest until the file fits. Defaults to 64 MiB.
  - `:max_age_days` — maximum age of a retained boot in days. Defaults to 30.
  - `:prune_interval_bytes` — periodic in-writer pruning fires after this many
    bytes have been written since the last prune. Defaults to `max(max_bytes/8, 1 MiB)`
    and can be overridden with `observability.telemetry_retention_prune_interval_bytes`.
  """
  @spec telemetry_retention() :: [
          max_bytes: pos_integer(),
          max_age_days: pos_integer(),
          prune_interval_bytes: pos_integer()
        ]
  def telemetry_retention do
    case Aiur.Config.settings() do
      {:ok, %{observability: observability}} ->
        max_bytes = Map.get(observability, :telemetry_retention_max_bytes, @default_telemetry_retention_max_bytes)

        [
          max_bytes: max_bytes,
          max_age_days: Map.get(observability, :telemetry_retention_max_age_days, @default_telemetry_retention_max_age_days),
          prune_interval_bytes: Map.get(observability, :telemetry_retention_prune_interval_bytes) || default_prune_interval(max_bytes)
        ]

      _other ->
        [
          max_bytes: @default_telemetry_retention_max_bytes,
          max_age_days: @default_telemetry_retention_max_age_days,
          prune_interval_bytes: default_prune_interval(@default_telemetry_retention_max_bytes)
        ]
    end
  end

  defp default_prune_interval(max_bytes) when is_integer(max_bytes) and max_bytes > 0,
    do: max(div(max_bytes, 8), @minimum_telemetry_retention_prune_interval_bytes)
end
