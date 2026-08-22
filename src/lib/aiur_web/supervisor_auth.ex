defmodule AiurWeb.SupervisorAuth do
  @moduledoc """
  Dedicated bearer authentication boundary for the Decision API.

  The secret is read from `AIUR_SUPERVISOR_TOKEN` on every request so an
  Executor can rotate it without restarting Aiur. Successful authentication
  assigns one fixed supervising-agent identity; request content is never used
  to derive that actor.
  """

  @behaviour Plug

  import Plug.Conn

  alias Aiur.SupervisorToken

  @token_env "AIUR_SUPERVISOR_TOKEN"
  @actor %{kind: :supervisor, id: "supervising-agent"}
  @realm "Bearer realm=\"Aiur Supervisor\""
  @unconfigured_body ~s({"error":{"code":"supervisor_auth_unconfigured","message":"No supervisor credential is configured on this instance"}})
  @required_body ~s({"error":{"code":"supervisor_auth_required","message":"Supervisor authentication required"}})
  @invalid_body ~s({"error":{"code":"supervisor_auth_invalid","message":"Supervisor credential did not match"}})

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case SupervisorToken.classify(System.get_env(@token_env)) do
      {:ok, configured_token} -> authenticate(conn, configured_token)
      :missing -> unauthorized(conn, @unconfigured_body)
      :invalid -> unauthorized(conn, @unconfigured_body)
    end
  end

  @doc "The only actor identity this authentication boundary may inject."
  @spec actor() :: %{kind: :supervisor, id: String.t()}
  def actor, do: @actor

  defp authenticate(conn, configured_token) do
    case presented_token(conn) do
      {:ok, presented_token} ->
        if token_matches?(presented_token, configured_token) do
          assign(conn, :decision_actor, @actor)
        else
          unauthorized(conn, @invalid_body)
        end

      :error ->
        unauthorized(conn, @required_body)
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
        if String.downcase(scheme) == "bearer", do: normalize_token(token), else: :error

      _malformed ->
        :error
    end
  end

  defp normalize_token(token) do
    case SupervisorToken.classify(token) do
      {:ok, valid_token} -> {:ok, valid_token}
      _missing_or_invalid -> :error
    end
  end

  defp token_matches?(presented_token, configured_token) do
    presented_digest = :crypto.hash(:sha256, presented_token)
    configured_digest = :crypto.hash(:sha256, configured_token)
    Plug.Crypto.secure_compare(presented_digest, configured_digest)
  end

  defp unauthorized(conn, body) do
    conn
    |> put_resp_header("www-authenticate", @realm)
    |> put_resp_content_type("application/json")
    |> send_resp(401, body)
    |> halt()
  end
end
