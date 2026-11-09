defmodule AiurWeb.ControlBodyLimit do
  @moduledoc "Rejects oversized control requests before Plug.Parsers decodes JSON."
  @behaviour Plug

  import Plug.Conn

  alias Aiur.ControlCall.Audit

  @limit 65_536
  @body_key :aiur_control_raw_body

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{path_info: ["api", "v1", "control"]} = conn, _opts) do
    case read_body(conn, length: @limit) do
      {:ok, body, conn} -> put_private(conn, @body_key, body)
      {:more, _body, conn} -> too_large(conn)
      {:error, _reason} -> too_large(conn)
    end
  end

  def call(conn, _opts), do: conn

  defp too_large(conn) do
    audit_result =
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

    case audit_result do
      :ok ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(413, ~s({"error":{"code":"body_too_large","limit_bytes":65536}}))
        |> halt()

      {:error, _reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(503, ~s({"error":{"code":"audit_unavailable"}}))
        |> halt()
    end
  end

  @doc false
  @spec cached_body(Plug.Conn.t()) :: {:ok, binary(), Plug.Conn.t()} | :missing
  def cached_body(conn) do
    case Map.fetch(conn.private, @body_key) do
      {:ok, body} -> {:ok, body, %{conn | private: Map.delete(conn.private, @body_key)}}
      :error -> :missing
    end
  end
end
