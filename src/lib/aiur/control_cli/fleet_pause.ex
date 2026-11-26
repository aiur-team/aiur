defmodule Aiur.ControlCLI.FleetPause do
  @moduledoc """
  `aiur pause|resume --all-gateways`: records one `fleet.pause` change, pushes it to the shared
  store, applies it here, and hands the engine the change so it can deliver it directly to each
  reachable peer (`apply_remote_change/1`). The register is the durable path: an unreachable
  gateway applies it when it next syncs, before dispatching.

  The engine prints the per-gateway label (`paused now`, `will pause on reconnect`, `unknown`)
  from the `AIUR_FLEET_CHANGE <stored|outbox_only> <base64 change>` line this module prints.
  """

  import Aiur.ControlCLI.Protocol, only: [control_error: 1, exit_marker: 1]

  alias Aiur.Intent.{Change, Publish, Registers, Sync}
  alias Aiur.Orchestrator.GlobalPause

  @spec pause_all(keyword()) :: :ok
  def pause_all(opts \\ []), do: deliver(true, opts)

  @spec resume_all(keyword()) :: :ok
  def resume_all(opts \\ []), do: deliver(false, opts)

  defp deliver(value, opts) do
    case Registers.write_fleet_pause(value, as: opts[:as], reason: opts[:reason]) do
      {:ok, change} ->
        store = Publish.push(change)
        _ = GlobalPause.sync_fleet_pause()
        report(value, change, store)
        exit_marker(0)

      {:error, reason} ->
        control_error("aiur: could not record the fleet pause (#{reason})")
        exit_marker(1)
    end
  end

  defp report(value, change, store) do
    IO.puts("this gateway: #{if value, do: "paused now", else: "resumed now"}")

    if not value and match?({:paused, _, _, _}, Registers.fleet_pause()),
      do: IO.puts("still paused: a human pause is set")

    encoded = change |> Change.to_json() |> Jason.encode!() |> Base.encode64()
    IO.puts("AIUR_FLEET_CHANGE #{store} #{encoded}")
  end

  @doc """
  Direct delivery of one change from another gateway's `--all-gateways` command. Idempotent by
  `change_id`; never queued for publishing. Deliberately not a general apply endpoint: only a
  `fleet.pause` change is accepted, and a remote `human` slot may only pause (the safe direction).
  """
  @spec apply_remote_change(String.t(), keyword()) :: :ok
  def apply_remote_change(json, opts \\ []) when is_binary(json) do
    with {:ok, map} <- Jason.decode(json),
         {:ok, change} <- Change.from_json(map),
         :ok <- allowed(change),
         {:ok, result} <- Sync.apply_remote(change, Keyword.take(opts, [:store, :table, :own_gateway, :now_fun])) do
      _ = GlobalPause.sync_fleet_pause()
      IO.puts(result)
      exit_marker(0)
    else
      error ->
        control_error("aiur: fleet pause change refused (#{inspect(error)})")
        exit_marker(1)
    end
  end

  defp allowed(%Change{entity_kind: "fleet", field: "pause", value_json: v, slot: slot, force: false}) when is_boolean(v) do
    cond do
      slot == "executor" -> :ok
      slot == "human" and v -> :ok
      true -> {:error, :slot_not_accepted}
    end
  end

  defp allowed(_change), do: {:error, :not_a_fleet_pause}
end
