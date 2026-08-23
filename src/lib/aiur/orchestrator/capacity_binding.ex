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

  @type kind :: :admission | :ticket_supply | :paused_reservations | :envelope | :config_cap | :session_cap | :none
  @type t :: {kind(), term()}

  @doc """
  Classifies the binding constraint from a daemon capacity map.

  `capacity_hold` is the daemon's own persisted admission decision — the only
  source allowed to name an admission signal as the fleet's binding constraint.
  """
  @spec binding(map()) :: t()
  def binding(%{capacity_hold: %{} = hold}), do: {:admission, hold}

  def binding(%{max: max, effective: effective, configured: configured, occupied: occupied} = capacity)
      when is_integer(max) and is_integer(effective) and is_integer(configured) and is_integer(occupied) do
    if ticket_supply?(capacity) do
      {:ticket_supply, 0}
    else
      with_capacity(capacity, max, effective, configured, occupied)
    end
  end

  def binding(_capacity), do: {:none, nil}

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
  def short_label({:admission, %{signal: signal}}), do: "admission: #{signal}"
  def short_label({:admission, _hold}), do: "admission"

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
        {:none, nil}
    end
  end

  defp ticket_supply?(%{available: available, queued_demand?: false}) when is_integer(available) and available > 0, do: true
  defp ticket_supply?(_capacity), do: false

  defp paused_reservation_binding?(%{active: active, effective: effective, available: 0, reserved_paused: reserved_paused})
       when reserved_paused > 0 and effective > active,
       do: true

  defp paused_reservation_binding?(_capacity), do: false
end
