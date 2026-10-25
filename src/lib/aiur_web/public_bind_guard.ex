defmodule AiurWeb.PublicBindGuard do
  @moduledoc false
  @behaviour Plug
  import Plug.Conn

  @public_auth_paths MapSet.new([
                       {"GET", ["auth", "login"]},
                       {"GET", ["auth", "google"]},
                       {"GET", ["auth", "google", "callback"]},
                       {"POST", ["auth", "passkeys", "authentication", "challenge"]},
                       {"POST", ["auth", "passkeys", "authentication", "finish"]},
                       {"POST", ["auth", "passkeys", "registration", "challenge"]},
                       {"POST", ["auth", "passkeys", "registration", "finish"]}
                     ])

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if AiurWeb.EndpointConfig.get(:public_bind, false) and not public_path?(conn) and not supervisor_auth_path?(conn) do
      AiurWeb.FinancialDataAccess.authenticate_request(conn, browser?: browser_request?(conn), required?: true)
    else
      conn
    end
  end

  @doc false
  @spec public_path?(Plug.Conn.t()) :: boolean()
  def public_path?(%Plug.Conn{method: method, path_info: ["healthz"]}) when method in ["GET", "HEAD"], do: true
  def public_path?(%Plug.Conn{method: method, path_info: ["readyz"]}) when method in ["GET", "HEAD"], do: true
  def public_path?(%Plug.Conn{method: "POST", path_info: ["api", "v1", "github", "webhook"]}), do: true
  def public_path?(%Plug.Conn{method: method, path_info: path}), do: MapSet.member?(@public_auth_paths, {method, path})

  defp supervisor_auth_path?(%Plug.Conn{path_info: ["api", "v1", "decisions" | _]}), do: true
  defp supervisor_auth_path?(_conn), do: false

  defp browser_request?(%Plug.Conn{path_info: ["api" | _]}), do: false
  defp browser_request?(_conn), do: true
end

defmodule AiurWeb.PublicHealthController do
  use Phoenix.Controller, formats: [:text]

  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.TrackerHealth

  @spec live(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def live(conn, _params), do: send_resp(conn, :ok, "ok\n")

  @spec ready(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def ready(conn, _params) do
    if ready?(), do: send_resp(conn, :ok, "ready\n"), else: send_resp(conn, :service_unavailable, "not ready\n")
  end

  defp ready? do
    case Application.get_env(:aiur, :health_ready_fun) do
      fun when is_function(fun, 0) -> fun.() == :ok
      _ -> is_pid(orchestrator_pid()) and tracker_preflight() == :ok
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp orchestrator_pid do
    case Application.get_env(:aiur, :health_orchestrator_pid_fun) do
      fun when is_function(fun, 0) -> fun.()
      _ -> Process.whereis(Orchestrator)
    end
  end

  defp tracker_preflight do
    case Application.get_env(:aiur, :health_tracker_preflight_fun) do
      fun when is_function(fun, 0) -> fun.()
      _ -> TrackerHealth.tracker_preflight()
    end
  end
end
