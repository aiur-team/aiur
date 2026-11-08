defmodule AiurWeb.GatewayPauseController do
  @moduledoc """
  Pause or resume this gateway (`gateway/*`) or the whole fleet from the dashboard (`fleet/*`).

  `fleet/*` writes the shared `fleet.pause` intent first and reports whether it was stored, so a
  gateway the browser could not reach still applies the pause when it next syncs. Both pairs are
  absolute sets, so a retried request is harmless. `request_id` is echoed for the caller.
  """
  use Phoenix.Controller, formats: [:json]

  alias Aiur.ControlCLI.FleetPause
  alias Aiur.Intent.Registers
  alias Aiur.Orchestrator.{Client, GlobalPause}

  @source "dashboard gateway pause"

  @spec pause(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def pause(conn, params), do: local(conn, params, true)
  @spec resume(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def resume(conn, params), do: local(conn, params, false)
  @spec fleet_pause(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def fleet_pause(conn, params), do: fleet(conn, params, true)
  @spec fleet_resume(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def fleet_resume(conn, params), do: fleet(conn, params, false)

  @spec method_not_allowed(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def method_not_allowed(conn, _params) do
    conn |> put_resp_header("allow", "POST") |> put_status(:method_not_allowed) |> json(%{error: "method_not_allowed"})
  end

  defp local(conn, params, on?) do
    case Client.set_global_pause(on?, @source) do
      {:ok, _} -> reply(conn, params)
      {:error, reason} -> failed(conn, reason)
    end
  end

  defp fleet(conn, params, on?) do
    case Registers.write_fleet_pause(on?, reason: @source) do
      {:ok, change} ->
        stored = FleetPause.push(change) == :stored
        _ = GlobalPause.sync_fleet_pause()
        reply(conn, params, intent_written: stored)

      {:error, _reason} ->
        # No intent could be recorded: still act on this gateway so the human's click is not lost.
        case Client.set_global_pause(on?, @source) do
          {:ok, _} -> reply(conn, params, intent_written: false)
          {:error, reason} -> failed(conn, reason)
        end
    end
  end

  defp reply(conn, params, extra \\ []) do
    paused =
      case Client.global_pause_status() do
        {:ok, %{globally_paused: value}} -> value
        _ -> nil
      end

    conn
    |> put_resp_header("cache-control", "no-store")
    |> json(Map.merge(%{ok: true, globally_paused: paused, request_id: params["request_id"]}, Map.new(extra)))
  end

  defp failed(conn, reason), do: conn |> put_status(503) |> json(%{ok: false, error: "control_failed", detail: inspect(reason)})
end
