defmodule AiurWeb.ControlTokenAuth do
  @moduledoc "Bearer-only authentication for the remote control endpoint."
  @behaviour Plug

  alias Aiur.ControlCall.Audit

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn = AiurWeb.ClientTokenAuth.call(conn, bearer_only?: true)
    if conn.halted, do: audit_refusal(conn)
    conn
  end

  defp audit_refusal(conn) do
    Audit.append(%{
      at: DateTime.utc_now() |> DateTime.to_iso8601(),
      token: "unknown",
      scope: "unknown",
      call: "unparsed",
      expression_sha256: nil,
      outcome: "refused",
      exit_code: nil,
      elapsed_ms: 0,
      remote_ip: conn.remote_ip |> :inet.ntoa() |> to_string()
    })
  end
end
