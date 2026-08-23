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
  def binding(capacity, polling \\ %{})

  def binding(%{capacity_hold: %{} = hold}, _polling), do: {:admission, hold}

  def binding(%{max: max, effective: effective, configured: configured, occupied: occupied} = capacity, polling)
      when is_integer(max) and is_integer(effective) and is_integer(configured) and is_integer(occupied) do
    case ticket_supply(capacity, polling) do
      {:ticket_supply, detail} -> {:ticket_supply, detail}
      {:has_not_polled, detail} -> {:has_not_polled, detail}
      :not_ticket_supply -> with_capacity(capacity, max, effective, configured, occupied)
    end
  end

  def binding(_capacity, _polling), do: {:none, nil}

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
