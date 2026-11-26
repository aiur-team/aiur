defmodule AiurWeb.CommandsScopeAuth do
  @moduledoc """
  Bearer authentication boundary for the ticket-scoped Commands API.

  The presented credential is a grant minted by `Aiur.Commands.Scope`, not the
  instance's supervisor credential: an embedding host exchanges its own
  service credential for a short-lived grant naming the tickets one of its
  users may see. Verification is fail-closed, and the plug assigns only the
  verified scope — request content never widens it.

  The signing secret is derived from the instance's endpoint
  `secret_key_base`, so no additional operator configuration is required and
  the grant cannot be minted by a caller that only holds the host credential.
  """

  @behaviour Plug

  import Plug.Conn

  alias Aiur.Commands.Scope
  alias AiurWeb.EndpointConfig

  @realm "Bearer realm=\"Aiur Commands\""
  @unconfigured_body ~s({"error":{"code":"commands_scope_unconfigured","message":"This instance cannot issue Command scopes"}})
  @required_body ~s({"error":{"code":"commands_scope_required","message":"A Command scope token is required"}})
  @invalid_body ~s({"error":{"code":"commands_scope_invalid","message":"Command scope token is invalid"}})
  @expired_body ~s({"error":{"code":"commands_scope_expired","message":"Command scope token has expired"}})

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case signing_secret(conn) do
      {:ok, secret} -> authenticate(conn, secret)
      :error -> unauthorized(conn, @unconfigured_body)
    end
  end

  @doc """
  The signing secret for scope grants.

  `conn.private[:command_scope_secret]` is an explicit per-request override used
  by tests. Otherwise the secret is derived from the instance endpoint
  `secret_key_base`, so the grant can only be minted on this instance and needs
  no operator configuration.
  """
  @spec signing_secret(Plug.Conn.t() | nil) :: {:ok, String.t()} | :error
  def signing_secret(conn \\ nil) do
    case conn && conn.private[:command_scope_secret] do
      nil -> derived_secret()
      secret when is_binary(secret) and byte_size(secret) >= 32 -> {:ok, secret}
      _unusable -> :error
    end
  rescue
    _error -> :error
  catch
    :exit, _reason -> :error
  end

  defp derived_secret do
    case EndpointConfig.get(:secret_key_base) do
      secret when is_binary(secret) and byte_size(secret) >= 32 ->
        {:ok, :crypto.hash(:sha256, secret <> ":aiur-command-scope") |> Base.encode16(case: :lower)}

      _missing ->
        :error
    end
  rescue
    _error -> :error
  catch
    :exit, _reason -> :error
  end

  defp authenticate(conn, secret) do
    case presented_token(conn) do
      {:ok, token} ->
        case verify(token, secret, conn) do
          {:ok, scope} -> assign(conn, :command_scope, scope)
          {:error, :expired} -> unauthorized(conn, @expired_body)
          {:error, _reason} -> unauthorized(conn, @invalid_body)
        end

      {:error, :missing} ->
        unauthorized(conn, @required_body)
    end
  end

  defp verify(token, secret, conn) do
    Scope.verify(token, secret: secret, now: conn.private[:command_scope_now] || DateTime.utc_now())
  end

  defp presented_token(conn) do
    case get_req_header(conn, "authorization") do
      [header] -> parse_bearer(header)
      _missing_or_ambiguous -> {:error, :missing}
    end
  end

  defp parse_bearer(header) do
    case String.split(header, ~r/\s+/, parts: 2, trim: true) do
      [scheme, token] ->
        if String.downcase(scheme) == "bearer" and String.trim(token) != "", do: {:ok, token}, else: {:error, :missing}

      _malformed ->
        {:error, :missing}
    end
  end

  defp unauthorized(conn, body) do
    conn
    |> put_resp_header("www-authenticate", @realm)
    |> put_resp_content_type("application/json")
    |> send_resp(401, body)
    |> halt()
  end
end
