defmodule AiurWeb.ExecutorHookAuth do
  @moduledoc "Loopback-only bearer boundary for external Executor lifecycle hooks."
  @behaviour Plug
  import Plug.Conn
  alias Aiur.Executor.HookToken

  @impl true
  def init(opts), do: opts
  @impl true
  def call(conn, opts) do
    case HookToken.read() do
      {:ok, token} -> authenticate(conn, token, opts)
      {:error, _} -> unauthorized(conn, "executor_hook_unconfigured")
    end
  end

  defp authenticate(conn, token, opts) do
    if conn.remote_ip not in [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}] and opts[:delivery] do
      conn |> send_resp(403, "") |> halt()
    else
      authenticate_loopback(conn, token)
    end
  end

  defp authenticate_loopback(conn, token) do
    if conn.remote_ip in [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}] and matches?(conn, token),
      do: assign(conn, :executor_hook_actor, %{kind: :executor_hook}),
      else: unauthorized(conn, "executor_hook_unauthorized")
  end

  defp matches?(conn, token) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> presented] -> Plug.Crypto.secure_compare(:crypto.hash(:sha256, presented), :crypto.hash(:sha256, token))
      _ -> false
    end
  end

  defp unauthorized(conn, code) do
    conn |> put_resp_content_type("application/json") |> send_resp(401, Jason.encode!(%{error: %{code: code}})) |> halt()
  end
end
