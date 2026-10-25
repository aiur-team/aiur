defmodule AiurWeb.HealthController do
  @moduledoc false
  use Phoenix.Controller, formats: [:json]

  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.TrackerHealth

  @spec live(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def live(conn, _params), do: send_resp(conn, 200, "ok\n")

  @spec ready(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def ready(conn, _params) do
    if ready?() do
      send_resp(conn, 200, "ready\n")
    else
      send_resp(conn, 503, "not ready\n")
    end
  end

  defp ready? do
    case Application.get_env(:aiur, :health_ready_fun) do
      fun when is_function(fun, 0) -> fun.() == :ok
      _ -> is_pid(Process.whereis(Orchestrator)) and TrackerHealth.tracker_preflight() == :ok
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end
end
