defmodule Aiur.Config.AgentSettings do
  @moduledoc false

  alias Aiur.Config.RoutingValue
  alias Aiur.Config.Schema

  @doc """
  Ordered dispatch preference, as **routes** — each entry is a
  `Aiur.Config.RoutingValue` (`backend[:model[:effort]][+remote]`), so
  `"openrouter:anthropic/claude-sonnet-5"` and a bare `"claude"` are both
  valid members and one model reachable two ways may appear twice. Empty means
  the deprecated `agent.kind`/`agent.switch_model_on_ratelimit` fields apply.

  Callers that need only the backend must map through
  `agent_priority_backends/0` (or `RoutingValue.routing_backend/1`); anything
  comparing a member against `known_backends()` directly will silently drop
  every route that names a model.
  """
  @spec agent_priority() :: [String.t()]
  def agent_priority, do: Aiur.Config.settings!().agent.priority || []

  @doc """
  Whether dispatch should route away from a route that is currently inside a
  provider's peak-pricing window, falling through to the next `agent.priority`
  entry. Defaults to `true`.

  When the window cannot be determined, routing never reroutes (it fails toward
  not rerouting). `false` means "ignore pricing windows entirely and use
  `agent.priority` exactly as written"; it never changes how spend is
  *reported*. See `Aiur.Config.Schema.PricingPolicy`.
  """
  @spec avoid_peak_pricing?() :: boolean()
  def avoid_peak_pricing? do
    avoid_peak_pricing_value(Aiur.Config.settings!())
  end

  @doc """
  The effective `avoid_peak_pricing` value for already-parsed settings.

  Defaults to `true` when the pricing policy is absent: the knob is opt-out,
  not opt-in, so an operator who never touches it gets the conservative
  peak-avoiding behaviour. The pure form is what the routing policy reads
  through, so the default is asserted directly rather than only through a live
  config read.
  """
  @spec avoid_peak_pricing_value(term()) :: boolean()
  def avoid_peak_pricing_value(settings) do
    case settings do
      %{agent: %{pricing_policy: %{avoid_peak_pricing: value}}} when is_boolean(value) -> value
      _ -> true
    end
  end

  @doc "The backends named by `agent_priority/0`, in order, with the model segment stripped and duplicates collapsed."
  @spec agent_priority_backends() :: [String.t()]
  def agent_priority_backends do
    agent_priority() |> Enum.map(&RoutingValue.routing_backend/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end

  @doc "Default backend: the backend of the first `agent.priority` route when present, else the deprecated `agent.kind` field."
  @spec agent_kind() :: String.t()
  def agent_kind do
    case agent_priority_backends() do
      [primary | _] -> primary
      [] -> Aiur.Config.settings!().agent.kind || Aiur.CodingAgent.default_backend()
    end
  end

  @doc "Raw settings for a registry-named backend, or an empty map when absent."
  @spec backend_config(String.t()) :: map()
  def backend_config(backend) when is_binary(backend) do
    agent_backend_configs()
    |> Map.get(backend, %{})
  end

  @doc """
  Raw settings for all registry-named backends, with the backend of each
  `agent.priority` route marked enabled so naming a route makes its backend
  dispatchable. Keyed by backend, never by route: several routes may share one
  backend (`openrouter:a` and `openrouter:b`) and they configure one transport.
  """
  @spec agent_backend_configs() :: map()
  def agent_backend_configs do
    Enum.reduce(agent_priority_backends(), Aiur.Config.settings!().agent.backend_configs || %{}, fn backend, acc ->
      Map.update(acc, backend, %{"enabled" => true}, &Map.put(&1, "enabled", true))
    end)
  end

  @spec agent_routing() :: %{pos_integer() => String.t()}
  def agent_routing do
    Aiur.Config.settings!().agent.routing || %{}
  end

  @doc """
  Claim-time fallback order: `agent.priority` when present, else the deprecated
  `agent.switch_model_on_ratelimit` field. Returns **routes**, not backends —
  selection consumes the model segment, so stripping it here would collapse
  `[claude, "openrouter:anthropic/claude-sonnet-5"]` into one candidate and
  erase the fallback the operator wrote.
  """
  @spec switch_model_on_ratelimit() :: [String.t()]
  def switch_model_on_ratelimit do
    case agent_priority() do
      [] -> Aiur.Config.settings!().agent.switch_model_on_ratelimit || []
      priority -> priority
    end
  end

  @doc """
  The registered backend the automatic usage-limit fallback reroutes *to*
  (`Aiur.Orchestrator.RateLimitFallback`) when an already-running agent on
  `rate_limit_primary_backend/0` hits `usage_limit_exhausted`, or `nil` when
  disabled. When `agent.priority` is set, this is the first eligible fallback
  target after the primary; otherwise it reads the deprecated
  `agent.rate_limit_fallback` field (`""` disables).
  """
  @spec rate_limit_fallback_backend() :: String.t() | nil
  def rate_limit_fallback_backend do
    case agent_priority_backends() do
      [_primary | rest] -> Enum.find(rest, &(&1 in Aiur.CodingAgent.rate_limit_fallback_targets()))
      [] -> legacy_rate_limit_fallback()
    end
  end

  defp legacy_rate_limit_fallback do
    case Aiur.Config.settings!().agent.rate_limit_fallback do
      backend when is_binary(backend) and backend != "" -> backend
      _ -> nil
    end
  end

  @doc """
  The registered backend the usage-limit fallback reroutes *from* — the pair's
  primary. Only an already-running agent on this backend that hits
  `usage_limit_exhausted` is eligible for the reroute to
  `rate_limit_fallback_backend/0`. When `agent.priority` is set this is its
  first entry; otherwise it reads the deprecated `agent.rate_limit_primary`.
  """
  @spec rate_limit_primary_backend() :: String.t()
  def rate_limit_primary_backend do
    case agent_priority_backends() do
      [primary | _] -> primary
      [] -> Aiur.Config.settings!().agent.rate_limit_primary
    end
  end

  @doc """
  Setting #2: whether dispatched agents attach a `claude remote-control`
  session. Orthogonal to `agent_kind/0` and only meaningful for an
  RC-capable backend. The default lives in `Config.Schema` so flipping to
  always-remote is a one-line change there.
  """
  @spec agent_remote_control?() :: boolean()
  def agent_remote_control? do
    Aiur.Config.settings!().agent.remote_control || false
  end

  @doc """
  Lifetime cap on (re)dispatches for a single ticket, or 0 when disabled.
  """
  @spec agent_max_dispatches_per_ticket() :: non_neg_integer()
  def agent_max_dispatches_per_ticket do
    case Aiur.Config.settings() do
      {:ok, settings} -> Map.get(settings.agent, :max_dispatches_per_ticket) || 0
      _ -> 0
    end
  end

  @doc """
  Whether a recycled re-dispatch that could not resume its thread gets
  continuation guidance instead of the cold-start prompt. Defaults to true so
  a non-resumable backend switch picks up the shared workspace without claiming
  cross-backend conversation continuity.
  """
  @spec agent_prior_work_continuation?() :: boolean()
  def agent_prior_work_continuation? do
    case Aiur.Config.settings() do
      # Map.get, not dot access, so a config cached before this field existed
      # uses the current default rather than raising after a schema upgrade.
      {:ok, settings} -> Map.get(settings.agent, :prior_work_continuation, true)
      _ -> true
    end
  end

  @doc """
  Per-complexity-level guidance strings, keyed by complexity level.
  Appended to the end of the rendered prompt for an issue carrying the
  matching `complexity:<n>` label. Returns `%{}` when unset or the config
  cannot be loaded, so prompt building never fails on this lookup.
  """
  @spec agent_complexity_prompts() :: %{pos_integer() => String.t()}
  def agent_complexity_prompts do
    case Aiur.Config.settings() do
      {:ok, settings} -> settings.agent.complexity_prompts || %{}
      _ -> %{}
    end
  end

  @doc """
  Per-complexity turn-cap map, keyed by complexity level. `%{}` when unset.
  """
  @spec agent_max_turns_by_complexity() :: %{pos_integer() => pos_integer()}
  def agent_max_turns_by_complexity do
    case Aiur.Config.settings() do
      # Map.get (not dot access) so a config cached before this field existed
      # returns %{} rather than raising KeyError after a schema upgrade.
      {:ok, settings} -> Map.get(settings.agent, :max_turns_by_complexity) || %{}
      _ -> %{}
    end
  end

  @doc """
  Resolved alert sound settings (`enabled`, `use_os_default_sounds`,
  `sound_dir`, `alerts_file`). Returns the non-raising `{:ok, _} | {:error, _}`
  so `Aiur.Alerts` can fall back to safe defaults rather than crashing a turn
  when no workflow config is loaded (early boot, tests).
  """
  @spec alerts_settings() :: {:ok, Schema.Alerts.t()} | {:error, term()}
  def alerts_settings do
    with {:ok, settings} <- Aiur.Config.settings(), do: {:ok, settings.alerts}
  end

  @doc """
  First Executor takeover advisory threshold in hours, or `0` when disabled.
  A nonterminal ticket first emits an advisory alert once its convergence age
  reaches this value.
  """
  @spec executor_takeover_first_alert_hours() :: non_neg_integer()
  def executor_takeover_first_alert_hours do
    Aiur.Config.settings!().executor_takeover_first_alert_hours
  end

  @doc """
  Repeated Executor takeover advisory cadence in hours, or `0` when disabled.
  After the first advisory, the monitor re-alerts at most this often while the
  ticket remains nonterminal and unresolved.
  """
  @spec executor_takeover_continuous_alert_hours() :: non_neg_integer()
  def executor_takeover_continuous_alert_hours do
    Aiur.Config.settings!().executor_takeover_continuous_alert_hours
  end

  @spec max_retry_attempts() :: pos_integer()
  def max_retry_attempts do
    Aiur.Config.settings!().agent.max_retry_attempts
  end

  @spec max_retry_backoff_ms() :: pos_integer()
  def max_retry_backoff_ms do
    Aiur.Config.settings!().agent.max_retry_backoff_ms
  end

  @spec codex_thrash_max_per_window() :: pos_integer()
  def codex_thrash_max_per_window do
    Aiur.Config.settings!().agent.codex.thrash_max_per_window
  end

  @spec codex_thrash_window_seconds() :: pos_integer()
  def codex_thrash_window_seconds do
    Aiur.Config.settings!().agent.codex.thrash_window_seconds
  end

  @spec agent_max_turns() :: pos_integer() | nil
  def agent_max_turns do
    Aiur.Config.settings!().agent.max_turns
  end

  @doc """
  How many consecutive no-op continuation turns a run may take before
  `Aiur.AgentRunner.TurnLoop` stops it and raises a needs-attention alert
  (#2806). `nil` / 0 disables the bound. Reads as uncapped when the settings
  cannot be loaded at all, so a config fault cannot invent a cap.
  """
  @spec agent_max_consecutive_noop_turns() :: pos_integer() | nil
  def agent_max_consecutive_noop_turns do
    case Aiur.Config.settings() do
      {:ok, settings} -> Map.get(settings.agent, :max_consecutive_noop_turns)
      _unavailable -> nil
    end
  end

  @spec agent_turn_timeout_ms() :: pos_integer()
  def agent_turn_timeout_ms do
    Aiur.Config.settings!().agent.turn_timeout_ms
  end

  @spec agent_read_timeout_ms() :: pos_integer()
  def agent_read_timeout_ms do
    Aiur.Config.settings!().agent.codex.read_timeout_ms
  end

  @spec agent_stall_timeout_ms() :: non_neg_integer()
  def agent_stall_timeout_ms do
    Aiur.Config.settings!().agent.stall_timeout_ms
  end

  @spec max_agent_duration_minutes() :: non_neg_integer()
  def max_agent_duration_minutes do
    Aiur.Config.settings!().agent.max_agent_duration_minutes
  end

  @doc "Minutes before a CI-wait agent is re-woken for one recovery check."
  @spec ci_wait_rewake_minutes() :: pos_integer()
  def ci_wait_rewake_minutes do
    Aiur.Config.settings!().agent.ci_wait_rewake_minutes
  end
end
