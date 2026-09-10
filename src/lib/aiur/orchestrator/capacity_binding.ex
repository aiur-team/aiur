defmodule Aiur.Orchestrator.CapacityBinding do
  @moduledoc """
  Names *which* constraint is currently binding the agent fleet.

  A cap figure alone under-describes the fleet: `2 cap` is the same string
  whether an AIMD envelope backed off, a session override lowered the ceiling,
  the config cap is simply full, or eight paused reservations are holding
  slots. Each of those wants a different operator response, so every surface
  that renders a cap renders the binding constraint beside it.

  The classification is read ONLY from the daemon's own capacity report
  (`Aiur.Orchestrator.Slots.max_concurrent_agent_status/1`). Nothing here
  re-derives a gate from local state: a reader may not run on the daemon's
  host, and a locally re-derived gate can name a fleet-level cause the daemon
  never decided (#1610).
  """

  @type kind ::
          :admission
          | :ticket_supply
          | :has_not_polled
          | :paused_reservations
          | :envelope
          | :config_cap
          | :session_cap
          | :none
  @type t :: {kind(), term()}

  @doc """
  Classifies the binding constraint from a daemon capacity map.

  `capacity_hold` is the daemon's own persisted admission decision — the only
  source allowed to name an admission signal as the fleet's binding constraint.

  `polling` is the daemon's polling report from the same snapshot. It is threaded
  in for one honest reason: "ticket supply" is only claimable when the daemon
  recently polled and found nothing. While idle backoff is active, or the
  candidate snapshot is not fresh, the fleet has not looked recently enough to
  see work that appeared — so the binding says that instead of blaming ticket
  supply (#2138). A caller with no polling report gets the pre-#2138 behaviour.
  """
  @spec binding(map(), map()) :: t()
  def binding(capacity, polling \\ %{}), do: binding(capacity, polling, DateTime.utc_now())

  @doc false
  @spec binding(map(), map(), DateTime.t()) :: t()
  def binding(capacity, polling, now)

  def binding(%{capacity_hold: %{} = hold}, polling, now),
    do: {:admission, mark_stale_sample(hold, polling, now)}

  def binding(%{max: max, effective: effective, configured: configured, occupied: occupied} = capacity, polling, _now)
      when is_integer(max) and is_integer(effective) and is_integer(configured) and is_integer(occupied) do
    case ticket_supply(capacity, polling) do
      {:ticket_supply, detail} -> {:ticket_supply, detail}
      {:has_not_polled, detail} -> {:has_not_polled, detail}
      :not_ticket_supply -> with_capacity(capacity, max, effective, configured, occupied)
    end
  end

  def binding(_capacity, _polling, _now), do: {:none, nil}

  @doc """
  Whether an admission hold's measurement is old enough to be reported as stale.

  A hold is re-sampled once per poll cycle, so a sample older than two cycles
  was taken on a tick that never ran — the daemon is paused, its tracker fetch
  failed, or the reconciliation was skipped. The bound is floored at a minute so
  a very tight cadence does not flag every reading, and capped at five minutes
  because a figure that old stops describing the host whatever the cadence is:
  #2527 was reported against a `load=24.14` that had been current eight minutes
  earlier. The number is still the last thing the daemon measured; what changes
  is that a reader may no longer read it as current. A hold with no stamp
  predates #2527 and is left unjudged.
  """
  @spec stale_sample?(map(), map(), DateTime.t()) :: boolean()
  def stale_sample?(hold, polling \\ %{}, now \\ DateTime.utc_now()) do
    case sample_age_seconds(hold, now) do
      age when is_integer(age) -> age > div(stale_after_ms(polling), 1_000)
      nil -> false
    end
  end

  @doc """
  How many seconds ago an admission hold's measurement was taken.

  Returns `nil` when the hold carries no usable stamp, so a caller renders no
  age rather than a fabricated one.
  """
  @spec sample_age_seconds(map(), DateTime.t()) :: non_neg_integer() | nil
  def sample_age_seconds(hold, now \\ DateTime.utc_now())

  def sample_age_seconds(%{} = hold, %DateTime{} = now) do
    case measured_at(hold) do
      %DateTime{} = measured_at -> max(DateTime.diff(now, measured_at, :second), 0)
      nil -> nil
    end
  end

  def sample_age_seconds(_hold, _now), do: nil

  @stale_sample_floor_ms 60_000
  @stale_sample_ceiling_ms 300_000
  @stale_sample_default_ms 120_000

  defp stale_after_ms(polling) do
    case poll_interval_ms(polling) do
      interval when is_integer(interval) and interval > 0 ->
        interval |> Kernel.*(2) |> max(@stale_sample_floor_ms) |> min(@stale_sample_ceiling_ms)

      _unknown ->
        @stale_sample_default_ms
    end
  end

  defp poll_interval_ms(%{} = polling) do
    Map.get(polling, :effective_interval_ms) || Map.get(polling, "effective_interval_ms") ||
      Map.get(polling, :poll_interval_ms) || Map.get(polling, "poll_interval_ms")
  end

  defp poll_interval_ms(_polling), do: nil

  # The stamp survives a JSON round trip through the status snapshot, so both
  # the struct and its ISO-8601 rendering are accepted. Anything else is treated
  # as "no stamp" rather than as a fresh sample.
  defp measured_at(%{measured_at: %DateTime{} = measured_at}), do: measured_at
  defp measured_at(%{"measured_at" => %DateTime{} = measured_at}), do: measured_at

  defp measured_at(%{measured_at: measured_at}) when is_binary(measured_at), do: parse_measured_at(measured_at)
  defp measured_at(%{"measured_at" => measured_at}) when is_binary(measured_at), do: parse_measured_at(measured_at)
  defp measured_at(_hold), do: nil

  defp parse_measured_at(measured_at) do
    case DateTime.from_iso8601(measured_at) do
      {:ok, parsed, _offset} -> parsed
      _invalid -> nil
    end
  end

  # The classification stays `:admission` — the daemon really did decide this
  # hold, and dropping it would replace a known cause with a guess. What the
  # marker adds is the one fact the figure alone cannot carry: whether it was
  # measured recently enough to describe the host right now (#2527).
  defp mark_stale_sample(hold, polling, now) do
    if stale_sample?(hold, polling, now) do
      Map.put(hold, :stale_sample?, true)
    else
      hold
    end
  end

  @doc """
  A short binding label for space-constrained surfaces such as a KPI tile.

  Returns `nil` when nothing is binding, so a caller can omit the clause
  entirely rather than render a reassuring "none". The CLI keeps its own longer
  labels, which carry the full admission measurement.
  """
  @spec short_label(t()) :: String.t() | nil
  def short_label({:none, _detail}), do: nil
  def short_label({:paused_reservations, reserved}), do: "paused reservations=#{reserved}"
  def short_label({:envelope, _detail}), do: "AIMD envelope"
  def short_label({:config_cap, _detail}), do: "config max_concurrent_agents"
  def short_label({:session_cap, _detail}), do: "session max_concurrent_agents"
  def short_label({:ticket_supply, _detail}), do: "ticket supply"
  def short_label({:has_not_polled, _detail}), do: "has not polled yet"
  def short_label({:admission, %{signal: signal, stale_sample?: true}}), do: "admission: #{signal} (stale sample)"
  def short_label({:admission, %{signal: signal}}), do: "admission: #{signal}"
  def short_label({:admission, _hold}), do: "admission"

  @doc """
  A slot-free, unconstrained fleet's effective ceiling provenance.

  Says `session max_concurrent_agents` while `set max-agents` (or `--max-agents`
  at launch) is live, and `config max_concurrent_agents` once the session
  override is gone — so a restart that dropped the operator's live cap reads as
  config-sourced rather than as the operator's last command (#2138).
  """
  @spec ceiling_label(map()) :: String.t()
  def ceiling_label(%{session_override?: true}), do: "session max_concurrent_agents"
  def ceiling_label(_capacity), do: "config max_concurrent_agents"

  defp with_capacity(capacity, max, effective, configured, occupied) do
    cond do
      paused_reservation_binding?(capacity) ->
        {:paused_reservations, capacity.reserved_paused}

      effective < max and occupied >= effective ->
        {:envelope, effective}

      occupied >= max and max == configured and not Map.get(capacity, :session_override?, false) ->
        {:config_cap, configured}

      occupied >= max ->
        {:session_cap, max}

      true ->
        # Slots are available and nothing is binding: name where the effective
        # ceiling came from so an operator whose `set max-agents` was silently
        # dropped by a restart can see it (a session cap does not persist;
        # `--max-agents N` and `agent.max_concurrent_agents` are the durable
        # forms, #2138).
        {:none, %{ceiling: ceiling_label(capacity)}}
    end
  end

  defp ticket_supply(%{available: available, queued_demand?: false} = capacity, polling)
       when is_integer(available) and available > 0 do
    case poll_observation(polling) do
      :fresh ->
        # The daemon polled recently and found nothing dispatchable, so "ticket
        # supply" is the honest binding. The ceiling provenance rides along so
        # an operator whose `set max-agents` was silently dropped by a restart
        # can see the effective ceiling came from config, not their last
        # command (#2138).
        {:ticket_supply, %{ceiling: ceiling_label(capacity)}}

      {:backed_off, next_poll_in_ms} ->
        {:has_not_polled, %{next_poll_in_ms: next_poll_in_ms, ceiling: ceiling_label(capacity)}}

      :fetch_failed ->
        {:has_not_polled, %{ceiling: ceiling_label(capacity)}}
    end
  end

  defp ticket_supply(_capacity, _polling), do: :not_ticket_supply

  # Classify how fresh the daemon's most recent tracker observation is. `:fresh`
  # means a recent successful poll found no work — the only state in which
  # "ticket supply" is an honest binding. Idle backoff active means the last
  # successful poll is a full backed-off interval old; a `tracker_snapshot_fresh?
  # == false` means the last fetch failed. Both are "has not polled recently
  # enough to know".
  defp poll_observation(%{idle_backoff: %{active?: true}} = polling),
    do: {:backed_off, Map.get(polling, :next_poll_in_ms)}

  defp poll_observation(%{tracker_snapshot_fresh?: false}), do: :fetch_failed
  defp poll_observation(_polling), do: :fresh

  defp paused_reservation_binding?(%{active: active, effective: effective, available: 0, reserved_paused: reserved_paused})
       when reserved_paused > 0 and effective > active,
       do: true

  defp paused_reservation_binding?(_capacity), do: false
end
