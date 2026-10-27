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
    if AiurWeb.EndpointConfig.get(:public_bind, false) and not public_path?(conn) and not supervisor_auth_path?(conn) and not machine_api_path?(conn) do
      if basic_auth_present?(conn) do
        conn |> send_resp(401, "basic authentication is unavailable on a public bind") |> halt()
      else
        AiurWeb.FinancialDataAccess.authenticate_request(conn, browser?: browser_request?(conn), required?: true)
      end
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

  defp machine_api_path?(%Plug.Conn{path_info: ["api", "v1" | _]}), do: true
  defp machine_api_path?(_conn), do: false

  defp basic_auth_present?(conn) do
    conn
    |> get_req_header("authorization")
    |> Enum.any?(&String.starts_with?(String.downcase(&1), "basic "))
  end

  defp browser_request?(%Plug.Conn{path_info: ["api" | _]}), do: false
  defp browser_request?(_conn), do: true
end

defmodule AiurWeb.PublicHealthController do
  use Phoenix.Controller, formats: [:text]

  @spec live(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def live(conn, _params), do: send_resp(conn, :ok, "ok\n")
end
