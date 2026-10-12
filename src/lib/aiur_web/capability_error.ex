defmodule AiurWeb.CapabilityError do
  @moduledoc "Shared capability refusal encoder; endpoints opt in through their own gates."

  @spec render(Plug.Conn.t(), %{optional(:depends_on) => [String.t()] | nil, id: String.t(), state: atom(), reason: atom()}) :: Plug.Conn.t()
  def render(conn, entry) do
    report = Aiur.Capabilities.report([])

    body = %{
      error: "capability_unavailable",
      capability: entry.id,
      state: entry.state,
      reason: entry.reason,
      depends_on: entry[:depends_on],
      revision: report.revision,
      boot_id: report.boot_id
    }

    conn
    |> Plug.Conn.put_resp_header("cache-control", "no-store")
    |> Plug.Conn.put_status(if(entry.reason == :not_running, do: 503, else: 409))
    |> Phoenix.Controller.json(body)
  end
end
