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
    if AiurWeb.EndpointConfig.get(:public_bind, false) and not public_path?(conn) do
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

  defp browser_request?(%Plug.Conn{path_info: ["api" | _]}), do: false
  defp browser_request?(_conn), do: true
end

defmodule AiurWeb.PublicHealthController do
  use Phoenix.Controller, formats: [:text]

  @spec live(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def live(conn, _params), do: send_resp(conn, :ok, "ok\n")
end
