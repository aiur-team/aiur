defmodule Aiur.Config.CapacitySettings do
  @moduledoc false

  alias Aiur.Config.Schema.AgentValidation

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = Aiur.Config.settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      AgentValidation.normalize_issue_state(state_name),
      max_concurrent_agents()
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: max_concurrent_agents()

  @doc false
  @spec usage_ledger_durability_timeout() :: timeout()
  def usage_ledger_durability_timeout do
    case Application.get_env(:aiur, :usage_ledger_durability_timeout, :infinity) do
      :infinity -> :infinity
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _other -> :infinity
    end
  end

  @doc """
  Ceiling for new fleet admissions, derived from measured host capacity when the
  workflow omits `max_concurrent_agents`. Explicit config always wins; see
  `default_max_concurrent_agents/1` for the calibration.
  """
  @spec max_concurrent_agents() :: pos_integer()
  def max_concurrent_agents do
    case Aiur.Config.settings!().agent.max_concurrent_agents do
      n when is_integer(n) and n > 0 -> n
      _other -> default_max_concurrent_agents()
    end
  end

  @doc """
  Default fleet admission ceiling calibrated from measured host capacity rather
  than a hard-coded global agent count.

  The 2026-07-31 capacity run found a 16-core host saturates near ~19-20
  concurrent agents (load ~14 of 16), so the calibration is
  `schedulers + schedulers / 4` (16 → 20), floored at 2. This is a ceiling the
  load envelope adaptively backs off from under pressure, not a guaranteed
  concurrency target.
  """
  @spec default_max_concurrent_agents() :: pos_integer()
  @spec default_max_concurrent_agents(pos_integer()) :: pos_integer()
  def default_max_concurrent_agents(schedulers \\ System.schedulers_online())

  def default_max_concurrent_agents(schedulers)
      when is_integer(schedulers) and schedulers > 0 do
    max(schedulers + div(schedulers, 4), 2)
  end

  def default_max_concurrent_agents(_schedulers), do: 2

  @doc """
  Per-scheduler runnable-process ceiling for the instantaneous run-queue
  dispatch gate (#1430). `nil` disables the gate; a positive value holds new
  dispatch while `procs_running` strictly exceeds it times the scheduler count.
  """
  @spec run_queue_threshold() :: float() | nil
  def run_queue_threshold do
    Aiur.Config.settings!().agent.run_queue_threshold
  end

  @doc """
  Maximum number of agent-launched Mix compile/test commands allowed across the
  local workspace fleet. `0` disables the build gate intentionally.
  """
  @spec max_concurrent_builds() :: non_neg_integer()
  def max_concurrent_builds do
    Aiur.Config.settings!().agent.max_concurrent_builds
  end

  @doc "Minimum whole-second spacing between concurrent local Mix compile/test starts."
  @spec build_start_stagger_seconds() :: non_neg_integer()
  def build_start_stagger_seconds do
    Aiur.Config.settings!().agent.build_start_stagger_seconds || 0
  end

  @doc """
  Minimum Linux `MemAvailable` headroom required for normal dispatch and local
  agent Mix verification. `nil` disables memory admission.
  """
  @spec min_free_memory_mb() :: pos_integer() | nil
  def min_free_memory_mb do
    Aiur.Config.settings!().agent.min_free_memory_mb
  end

  @doc """
  Absolute wall-clock cap (seconds) on how long any one build-gate slot may be
  held before the detached lease holder releases it (#2349). `0` disables the
  backstop.
  """
  @spec build_gate_max_hold_seconds() :: non_neg_integer()
  def build_gate_max_hold_seconds do
    Aiur.Config.settings!().agent.build_gate_max_hold_seconds || 0
  end

  @doc """
  Maximum post-command courtesy window (seconds) the detached lease holder
  keeps a slot after the wrapped command exits, gated on a descendant still
  consuming CPU (#2398). The holder releases the moment the retained tree goes
  idle, so this bounds only genuinely-busy descendants. `0` disables the
  courtesy.
  """
  @spec build_gate_retain_seconds() :: non_neg_integer()
  def build_gate_retain_seconds do
    Aiur.Config.settings!().agent.build_gate_retain_seconds || 0
  end

  @doc "Scheduler count enforced for every Mix VM launched by an agent."
  @spec mix_scheduler_cap() :: pos_integer()
  def mix_scheduler_cap do
    Aiur.Config.settings!().agent.mix_scheduler_cap || 4
  end

  @doc """
  Whether the saturation sentinel recorder is enabled. The sentinel appends
  VM-internal + host diagnostics to `saturation.log` when 1-min load crosses
  the escalation threshold, so a crash under saturation is interpretable.
  """
  @spec saturation_log_enabled?() :: boolean()
  def saturation_log_enabled? do
    Aiur.Config.settings!().agent.saturation_log_enabled
  end

  @doc """
  Number of opencode-serve instances to pre-warm at boot. Each pre-
  warmed slot binds to a different active ticket as its leadoff so
  the user's first click on that ticket opens its chat pane in
  <100 ms. Defaults to 3 when absent from `.aiur/config`. `0` is valid
  and disables pre-warm entirely (all opens go through the cold
  placeholder path).
  """
  @spec pre_warmed_sessions() :: non_neg_integer()
  def pre_warmed_sessions do
    Aiur.Config.settings!().pre_warmed_sessions
  end

  @doc "Whether the repo-agnostic warm-base pre-warm is enabled (opt-in)."
  @spec prewarm_enabled?() :: boolean()
  def prewarm_enabled? do
    Aiur.Config.settings!().prewarm.enabled
  end

  @doc """
  The one-time base build command for the warm base, or nil when unset.
  Populated by `aiur init`'s toolchain detection; runs in the base checkout.
  """
  @spec prewarm_base_build() :: String.t() | nil
  def prewarm_base_build do
    Aiur.Config.settings!().prewarm.base_build
  end

  @doc "Background warm-base refresh interval in seconds; 0 disables polling."
  @spec prewarm_poll_seconds() :: non_neg_integer()
  def prewarm_poll_seconds do
    Aiur.Config.settings!().prewarm.poll_seconds
  end

  @doc """
  Maximum known synthetic load-generator descendants allowed per agent process
  tree. `nil` in config derives from available schedulers; `0` disables the
  guard for Executors that prefer manual containment.
  """
  @spec synthetic_load_process_cap() :: non_neg_integer()
  def synthetic_load_process_cap do
    case Aiur.Config.settings!().agent.synthetic_load_process_cap do
      cap when is_integer(cap) and cap >= 0 -> cap
      _ -> default_synthetic_load_process_cap()
    end
  end

  @spec default_synthetic_load_process_cap() :: pos_integer()
  @spec default_synthetic_load_process_cap(integer()) :: pos_integer()
  def default_synthetic_load_process_cap(schedulers \\ System.schedulers_online())

  def default_synthetic_load_process_cap(schedulers)
      when is_integer(schedulers) and schedulers > 0 do
    max(1, div(schedulers, 4))
  end

  def default_synthetic_load_process_cap(_schedulers), do: 1

  @doc "Linux CPU PSI some avg60 ceiling, in percent; null disables it."
  @spec max_cpu_pressure() :: float() | nil
  def max_cpu_pressure, do: Aiur.Config.settings!().agent.max_cpu_pressure

  @doc "Linux CPU PSI some avg60 AIMD target, in percent; null disables it."
  @spec target_cpu_pressure() :: float() | nil
  def target_cpu_pressure, do: Aiur.Config.settings!().agent.target_cpu_pressure

  @doc "Per-scheduler load ceiling used only when CPU PSI is unavailable."
  @spec max_load_average() :: float() | nil
  def max_load_average, do: Aiur.Config.settings!().agent.max_load_average

  @doc "Per-scheduler AIMD load target used only when CPU PSI is unavailable."
  @spec target_load_average() :: float() | nil
  def target_load_average do
    Aiur.Config.settings!().agent.target_load_average
  end

  @doc """
  Slots added below 80% of the PSI target, or at/below the load fallback target.
  """
  @spec load_ramp_step() :: pos_integer()
  def load_ramp_step, do: Aiur.Config.settings!().agent.load_ramp_step

  @spec load_resume_max_age_seconds() :: non_neg_integer()
  def load_resume_max_age_seconds, do: Aiur.Config.settings!().agent.load_resume_max_age_seconds

  @doc """
  Minimum number of seconds between above-target envelope decreases.
  """
  @spec load_cooldown_seconds() :: non_neg_integer()
  def load_cooldown_seconds, do: Aiur.Config.settings!().agent.load_cooldown_seconds

  @doc """
  Minimum seconds a ready-work capacity-starvation condition must persist before
  `system.dispatch.capacity_starved` / `system.fleet.capacity.starved` raise
  (#2447). The dwell is data, not a magic number, so the below-target ramp
  (which clears itself within a few poll cycles) can be filtered without
  hard-coding the bound in the alert path.
  """
  @spec capacity_starvation_alert_after_seconds() :: pos_integer()
  def capacity_starvation_alert_after_seconds do
    Aiur.Config.settings!().agent.capacity_starvation_alert_after_seconds
  end

  @doc """
  The sliding window over which budget-broker-timeout retries are counted for
  the retry-rate signal (#2464). Data, not magic, so the rate can be measured
  against whatever window a quiet-period baseline was taken over.
  """
  @spec budget_broker_rate_window_seconds() :: pos_integer()
  def budget_broker_rate_window_seconds do
    Aiur.Config.settings!().agent.budget_broker_rate_window_seconds
  end

  @doc """
  The retry count within the window above which the budget broker counts as
  degraded (#2464). Set from a measured baseline — if the normal rate is zero,
  almost any sustained rate is worth surfacing.
  """
  @spec budget_broker_degraded_retry_threshold() :: pos_integer()
  def budget_broker_degraded_retry_threshold do
    Aiur.Config.settings!().agent.budget_broker_degraded_retry_threshold
  end

  @doc """
  How long the degraded budget-broker retry rate must persist before the single
  `system.github.budget_broker_degraded` alert raises (#2464, dwell per
  #2434/#2449).
  """
  @spec budget_broker_degraded_alert_after_seconds() :: pos_integer()
  def budget_broker_degraded_alert_after_seconds do
    Aiur.Config.settings!().agent.budget_broker_degraded_alert_after_seconds
  end
end
