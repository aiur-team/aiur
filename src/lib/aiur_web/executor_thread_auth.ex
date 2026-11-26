defmodule AiurWeb.ExecutorThreadAuth do
  @moduledoc """
  Authentication for the operator↔Executor thread API.

  A bearer thread grant (`Aiur.Executor.ThreadGrant`) is verified here and
  reaches only this API. Any other credential goes through
  `AiurWeb.ClientTokenAuth`: a client token or the dashboard session. A write
  that relies on the dashboard session must also carry `X-Aiur-Request: 1`, as
  the dashboard's other write routes do.
  """

  @behaviour Plug

  import Plug.Conn

  alias Aiur.Executor.ThreadGrant
  alias AiurWeb.EndpointConfig

  @realm "Bearer realm=\"Aiur Executor thread\""

  @impl Plug
  def init(opts), do: Keyword.put_new(opts, :write?, false)

  @impl Plug
  def call(conn, opts) do
    case bearer(conn) do
      {:ok, token} -> if ThreadGrant.grant?(token), do: grant(conn, token), else: client_token(conn, opts)
      :none -> conn |> client_token(opts) |> require_session_header(opts)
    end
  end

  @doc "The grant signing secret, derived from the endpoint `secret_key_base`; `conn.private[:executor_thread_secret]` overrides it in tests."
  @spec signing_secret(Plug.Conn.t() | nil) :: {:ok, String.t()} | :error
  def signing_secret(conn \\ nil) do
    case conn && conn.private[:executor_thread_secret] do
      secret when is_binary(secret) and byte_size(secret) >= 32 -> {:ok, secret}
      nil -> derived_secret()
      _unusable -> :error
    end
  end

  defp derived_secret do
    case EndpointConfig.get(:secret_key_base) do
      base when is_binary(base) and byte_size(base) >= 32 -> {:ok, :crypto.hash(:sha256, base <> ":aiur-executor-thread") |> Base.encode16(case: :lower)}
      _missing -> :error
    end
  rescue
    _error -> :error
  catch
    :exit, _reason -> :error
  end

  defp grant(conn, token) do
    with {:ok, secret} <- signing_secret(conn),
         {:ok, grant} <- ThreadGrant.verify(token, secret: secret, now: conn.private[:executor_thread_now] || DateTime.utc_now()) do
      assign(conn, :executor_thread_grant, grant)
    else
      {:error, :expired} -> unauthorized(conn, "executor_thread_grant_expired", "Executor thread grant has expired")
      _invalid -> unauthorized(conn, "executor_thread_grant_invalid", "Executor thread grant is invalid")
    end
  end

  defp client_token(conn, opts), do: AiurWeb.ClientTokenAuth.call(conn, AiurWeb.ClientTokenAuth.init(write?: opts[:write?]))

  defp require_session_header(%Plug.Conn{halted: true} = conn, _opts), do: conn

  defp require_session_header(conn, opts) do
    if opts[:write?] and get_req_header(conn, "x-aiur-request") != ["1"] do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(403, ~s({"error":{"code":"missing_request_header","message":"X-Aiur-Request: 1 is required"}}))
      |> halt()
    else
      conn
    end
  end

  defp bearer(conn) do
    with [header] <- get_req_header(conn, "authorization"),
         [scheme, token] <- String.split(header, ~r/\s+/, parts: 2, trim: true),
         "bearer" <- String.downcase(scheme) do
      {:ok, String.trim(token)}
    else
      _ -> :none
    end
  end

  defp unauthorized(conn, code, message) do
    conn
    |> put_resp_header("www-authenticate", @realm)
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: %{code: code, message: message}}))
    |> halt()
  end
end
