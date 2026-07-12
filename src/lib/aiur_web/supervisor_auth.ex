defmodule AiurWeb.SupervisorAuth do
  @moduledoc """
  Dedicated bearer authentication boundary for the Decision API.

  The secret is read from `AIUR_SUPERVISOR_TOKEN` on every request so an
  operator can rotate it without restarting Aiur. Successful authentication
  assigns one fixed supervising-agent identity; request content is never used
  to derive that actor.
  """

  @behaviour Plug

  import Plug.Conn

  @token_env "AIUR_SUPERVISOR_TOKEN"
  @minimum_token_bytes 32
  @bearer_token ~r/\A[A-Za-z0-9\-._~+\/]+=*\z/
  @actor %{kind: :supervisor, id: "supervising-agent"}
  @realm "Bearer realm=\"Aiur Supervisor\""
  @unauthorized_body ~s({"error":{"code":"supervisor_auth_required","message":"Supervisor authentication required"}})

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    with {:ok, configured_token} <- configured_token(),
         {:ok, presented_token} <- presented_token(conn),
         true <- token_matches?(presented_token, configured_token) do
      assign(conn, :decision_actor, @actor)
    else
      _error -> unauthorized(conn)
    end
  end

  @doc "The only actor identity this authentication boundary may inject."
  @spec actor() :: %{kind: :supervisor, id: String.t()}
  def actor, do: @actor

  defp configured_token do
    case System.get_env(@token_env) do
      token when is_binary(token) -> if valid_token?(token), do: {:ok, token}, else: :error
      _missing -> :error
    end
  end

  defp presented_token(conn) do
    case get_req_header(conn, "authorization") do
      [header] -> parse_bearer(header)
      _missing_or_ambiguous -> :error
    end
  end

  defp parse_bearer(header) when is_binary(header) do
    case String.split(header, ~r/\s+/, parts: 2, trim: true) do
      [scheme, token] ->
        if String.downcase(scheme) == "bearer" and valid_token?(token), do: {:ok, token}, else: :error

      _malformed ->
        :error
    end
  end

  defp valid_token?(token) do
    byte_size(token) >= @minimum_token_bytes and token == String.trim(token) and
      Regex.match?(@bearer_token, token)
  end

  defp token_matches?(presented_token, configured_token) do
    presented_digest = :crypto.hash(:sha256, presented_token)
    configured_digest = :crypto.hash(:sha256, configured_token)
    Plug.Crypto.secure_compare(presented_digest, configured_digest)
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_header("www-authenticate", @realm)
    |> put_resp_content_type("application/json")
    |> send_resp(401, @unauthorized_body)
    |> halt()
  end
end
