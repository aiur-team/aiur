defmodule Aiur.Orchestrator.StatusCLI.Capacity do
  @moduledoc false
  alias Aiur.Config
  alias Aiur.Orchestrator.CapacityBinding
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.EnvelopeResume
  alias Aiur.Orchestrator.OptimisticSlots
  alias Aiur.SystemLoad

  @doc false
  @spec print_capacity_status(term(), term()) :: term()
  def print_capacity_status(
        %{occupied: occupied, max: max, effective: effective, configured: configured} = capacity,
        polling
      )
      when is_integer(occupied) and is_integer(max) and is_integer(effective) and
             is_integer(configured) do
    binding = capacity_binding(capacity, polling)
    resume = if is_integer(capacity[:resume_level]) and elem(binding, 0) != :envelope, do: "; #{EnvelopeResume.label(capacity)}", else: ""
    IO.puts("AGENTS #{occupied}/#{max} (binding: #{capacity_binding_label(binding)})#{resume}#{OptimisticSlots.label(capacity)}")
  end

  def print_capacity_status(_capacity, _polling), do: :ok

  @doc false
  @spec local_load_sample() :: term()
  def local_load_sample do
    threshold = Config.max_load_average()

    %{
      load: SystemLoad.avg1(),
      load_threshold: threshold,
      schedulers: System.schedulers_online()
    }
  rescue
    _error -> %{load: :unavailable, load_threshold: nil, schedulers: nil}
  end

  defp capacity_binding_label({:tracker_preflight, hold}), do: "tracker preflight, reason=#{hold.detail} held=#{hold.held_for_seconds}s"

  defp capacity_binding_label({:dispatch_selection, hold}),
    do: "dispatch selection, reasons=#{inspect(hold.reasons)} candidates=#{hold.candidates}" <> admission_sample_age(hold)

  defp capacity_binding_label({:stale_poll, %{age_seconds: age}}), do: "dispatch poll stale (#{age}s ago)"

  defp capacity_binding_label({:dispatch_cycle_stalled, detail}), do: CapacityBinding.dispatch_cycle_stalled_label(detail)
  defp capacity_binding_label({:awaiting_dispatch, %{ceiling: ceiling}}), do: "awaiting dispatch; ceiling: #{ceiling}"
  defp capacity_binding_label({:config_cap, _detail}), do: "config max_concurrent_agents"
  defp capacity_binding_label({:envelope, %{} = detail}), do: EnvelopeResume.label(detail)
  defp capacity_binding_label({:envelope, detail}), do: "AIMD envelope, effective cap=#{detail}"
  defp capacity_binding_label({:paused_reservations, detail}), do: "paused reservations=#{detail}"

  defp capacity_binding_label({:ticket_supply, %{ceiling: ceiling}}),
    do: "ticket supply; ceiling: #{ceiling}"

  defp capacity_binding_label({:ticket_supply, _detail}), do: "ticket supply"
  defp capacity_binding_label({:session_cap, _detail}), do: "session max_concurrent_agents"

  # Include sample age so old admission readings do not look current (#2527).
  defp capacity_binding_label({:admission, hold}),
    do: admission_detail(hold) <> admission_sample_age(hold)

  defp capacity_binding_label({:none, %{ceiling: ceiling}}), do: "none; ceiling: #{ceiling}"
  defp capacity_binding_label({:none, _detail}), do: "none"

  # The status line may only blame "ticket supply" when the daemon recently
  # polled and found no work. Idle backoff active or a failed candidate fetch
  # both mean the fleet has not looked recently enough to see work that
  # appeared — and blaming ticket supply there is the false explanation #2138
  # is about. Say what is actually true instead, and keep the ceiling source
  # visible so a restart that dropped a live `set max-agents` reads as
  # config-sourced rather than as the operator's last command (#2138).
  #
  # An idle backoff is a designed state, not a fault, so the label says why the
  # daemon is waiting and which knob set the width; a bare "backed off, next
  # poll in 599s" against a 120s config reads as a bug (#2640).
  defp capacity_binding_label({:idle_backoff, %{ceiling: ceiling} = detail}),
    do: "idle backoff active (#{idle_backoff_cause(detail)}#{idle_backoff_countdown(detail)}; ceiling: #{ceiling})"

  defp capacity_binding_label({:idle_backoff, detail}),
    do: "idle backoff active (#{idle_backoff_cause(detail)}#{idle_backoff_countdown(detail)})"

  defp capacity_binding_label({:has_not_polled, %{ceiling: ceiling}}),
    do: "has not polled yet (ceiling: #{ceiling})"

  defp capacity_binding_label({:has_not_polled, _detail}), do: "has not polled yet"

  defp idle_backoff_cause(%{factor: factor}) when is_number(factor),
    do: "no dispatchable demand at last poll; polling.idle_widen_factor=#{factor}"

  defp idle_backoff_cause(_detail), do: "no dispatchable demand at last poll"

  defp idle_backoff_countdown(%{next_poll_in_ms: next_ms}) when is_integer(next_ms),
    do: ", next poll in #{poll_seconds(next_ms)}s"

  defp idle_backoff_countdown(_detail), do: ""

  defp admission_detail(%{signal: :cpu_pressure, measured: pressure, threshold: threshold}),
    do: "CPU PSI some avg60=#{pressure}% threshold=#{threshold}%"

  defp admission_detail(%{signal: :memory, measured: memory, threshold: threshold}),
    do: "free memory=#{memory}MB threshold=#{threshold}MB"

  defp admission_detail(%{
         signal: :load,
         measured: load,
         threshold: threshold,
         reclaimable_cpu_percent: reclaimable,
         reclaimable_cpu_threshold: reclaimable_threshold
       }),
       do:
         "load+cpu contention, load=#{load} threshold=#{threshold} " <>
           "reclaimable_cpu=#{reclaimable}% threshold=#{reclaimable_threshold}%"

  defp admission_detail(%{signal: :load, measured: load, threshold: threshold}),
    do: "load, load=#{load} threshold=#{threshold}"

  defp admission_detail(%{
         signal: :run_queue,
         measured: runnable,
         threshold: threshold,
         reclaimable_cpu_percent: reclaimable,
         reclaimable_cpu_threshold: reclaimable_threshold
       }),
       do:
         "run_queue+cpu contention, runnable=#{runnable} threshold=#{threshold} " <>
           "reclaimable_cpu=#{reclaimable}% threshold=#{reclaimable_threshold}%"

  defp admission_detail(%{signal: :run_queue, measured: runnable, threshold: threshold}),
    do: "run_queue, runnable=#{runnable} threshold=#{threshold}"

  defp admission_detail(%{signal: :github_quota, measured: measured}) do
    case github_quota_measurement(measured) do
      {:current, detail} -> "github_quota, #{detail}"
      {:stale, detail} -> "github_quota stale, #{detail}"
      :unavailable -> "github_quota, measurement unavailable"
    end
  end

  defp admission_detail(%{signal: :provider, detail: detail}) when is_binary(detail),
    do: "provider, #{detail}"

  defp admission_detail(%{signal: signal}), do: to_string(signal)
  defp admission_detail(_hold), do: "admission"

  # A hold carrying no stamp predates #2527 and gets no age clause: an invented
  # "0s" would be the very false reassurance this line exists to remove.
  defp admission_sample_age(%{stale_sample?: true} = hold), do: sample_age_clause(hold, " STALE")
  defp admission_sample_age(hold), do: sample_age_clause(hold, "")

  defp sample_age_clause(hold, suffix) do
    case CapacityBinding.sample_age_seconds(hold) do
      age when is_integer(age) -> " sampled=#{age}s ago#{suffix}"
      nil -> ""
    end
  end

  defp github_quota_measurement(%{resource: resource, remaining: remaining, limit: limit, observed_at: observed_at}) do
    if stale_github_quota_measurement?(observed_at) do
      {:stale, "last_resource=#{resource} last_remaining=#{remaining}/#{limit} last_measured_at=#{format_observed_at(observed_at)}"}
    else
      {:current, "resource=#{resource} remaining=#{remaining}/#{limit} measured_at=#{format_observed_at(observed_at)}"}
    end
  end

  defp github_quota_measurement(_measured), do: :unavailable

  # The authority probes once a minute. Two missed intervals make a retained
  # capacity verdict historical evidence, not a claim about the live quota.
  defp stale_github_quota_measurement?(%DateTime{} = observed_at),
    do: DateTime.diff(DateTime.utc_now(), observed_at, :second) > 120

  defp stale_github_quota_measurement?(observed_at) when is_binary(observed_at) do
    case DateTime.from_iso8601(observed_at) do
      {:ok, parsed, _offset} -> stale_github_quota_measurement?(parsed)
      _invalid -> true
    end
  end

  defp stale_github_quota_measurement?(_observed_at), do: true

  defp format_observed_at(%DateTime{} = observed_at), do: DateTime.to_iso8601(observed_at)
  defp format_observed_at(observed_at) when is_binary(observed_at), do: observed_at
  defp format_observed_at(_observed_at), do: "unknown"

  # The classification lives in `Aiur.Orchestrator.CapacityBinding` so the CLI
  # and the dashboards name the same constraint from the same rules. Only the
  # label text below is CLI-specific — it carries the full admission
  # measurement, which does not fit a KPI tile.
  defp capacity_binding(capacity, polling), do: CapacityBinding.binding(capacity, polling)

  # A LOCAL host-pressure reading, taken before the control RPC so the
  # saturation signal survives an RPC timeout (the timeout is most likely
  # precisely when the box is loaded). It is explicitly not a fleet decision:
  # the daemon may run on another host, with another config, and may not be
  # holding at all. So the line says "local host sample" and, when the local
  # reading is over the local threshold, explains that the daemon still needs a
  # short-window CPU sample before it can identify real contention.
  @doc false
  @spec print_load_status(term()) :: term()
  def print_load_status(%{load: load, load_threshold: threshold, schedulers: schedulers})
      when is_number(load) and is_number(threshold) and is_integer(schedulers) and schedulers > 0 do
    # The bare threshold check, deliberately: this line reports whether the
    # LOCAL sample is over the local ceiling. It must not call the admission
    # reason, which needs the daemon's short-window CPU measurement and
    # dispatches without one (#2089).
    suffix =
      case DispatchPolicy.load_gate(load, threshold, schedulers) do
        :hold ->
          " (local host sample; over fallback load threshold, PSI governs dispatch when available)"

        :dispatch ->
          " (local host sample)"
      end

    IO.puts("LOAD (local fallback diagnostic) #{load} threshold=#{threshold * schedulers} schedulers=#{schedulers}#{suffix}")
  end

  def print_load_status(_capacity), do: :ok
  @doc false
  @spec poll_seconds(term()) :: non_neg_integer()
  def poll_seconds(milliseconds) when is_integer(milliseconds) and milliseconds >= 0,
    do: div(milliseconds, 1_000)

  def poll_seconds(_milliseconds), do: 0
end
