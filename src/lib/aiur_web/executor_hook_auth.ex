defmodule AiurWeb.ExecutorHookAuth do
  @moduledoc "Loopback-only bearer boundary for external Executor lifecycle hooks."
  @behaviour Plug
  import Plug.Conn
  alias Aiur.Executor.HookToken

  @impl true
  def init(opts), do: opts
  @impl true
  def call(conn, _opts) do
    case HookToken.read() do
      {:ok, token} -> authenticate(conn, token)
      {:error, _} -> unauthorized(conn, "executor_hook_unconfigured")
    end
  end

  defp authenticate(conn, token) do
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
