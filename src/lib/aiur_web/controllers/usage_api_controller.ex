defmodule AiurWeb.UsageApiController do
  @moduledoc "Authenticated provider usage read API sharing the CLI envelope."
  use Phoenix.Controller, formats: [:json]
  alias Aiur.Usage.CLI

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    conn |> Plug.Conn.put_resp_header("cache-control", "no-store") |> json(Aiur.Usage.json_snapshot(usage_opts()))
  end

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"provider" => provider}) do
    case CLI.payload(provider, usage_opts()) do
      {:ok, payload} -> conn |> Plug.Conn.put_resp_header("cache-control", "no-store") |> json(payload)
      {:error, :unknown_provider} -> conn |> put_status(:not_found) |> json(%{error: %{code: "unknown_provider", message: "Unknown usage provider"}})
    end
  end

  @spec method_not_allowed(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def method_not_allowed(conn, _params) do
    conn |> Plug.Conn.put_resp_header("allow", "GET") |> put_status(:method_not_allowed) |> json(%{error: "method_not_allowed"})
  end

  defp usage_opts, do: Application.get_env(:aiur, :usage_read_opts, [])
end
