defmodule Aiur.GitHub.AppToken do
  @moduledoc """
  GitHub App installation-token acquisition and least-privilege verification.

  The daemon authenticates to GitHub with a short-lived installation token
  obtained by signing a JWT with the App's private key and exchanging it at the
  App installations endpoint (see `docs/security/daemon-token-posture.md` and
  #1375). This module is pure — network access flows through an injectable
  `request_fun` (defaulting to `Transport.default_request_fun/1`) so every
  branch is unit-testable without touching the network.

  No function here ever logs or returns raw secret material on an error path;
  failures are structural error tuples.
  """

  alias Aiur.GitHub.{AppCredentials, Errors, Transport}

  @access_tokens_base_url "https://api.github.com/app/installations"
  @jwt_ttl_seconds 600
  @default_refresh_margin_seconds 300
  @min_refresh_ms 1_000
  @rate_limit_url "https://api.github.com/rate_limit"

  @doc "URL for the App installations access-tokens endpoint for `installation_id`."
  @spec access_tokens_url(String.t()) :: String.t()
  def access_tokens_url(installation_id) when is_binary(installation_id),
    do: "#{@access_tokens_base_url}/#{installation_id}/access_tokens"

  @doc """
  Builds and RS256-signs the GitHub App JWT for `app_id` using `jwk`, with
  `iat` = `now` and `exp` = `now + 10 minutes` (GitHub's maximum JWT lifetime).
  The header is `%{"alg" => "RS256", "typ" => "JWT"}`.
  """
  @spec app_jwt(JOSE.JWK.t(), String.t(), DateTime.t()) :: String.t()
  def app_jwt(jwk, app_id, now \\ DateTime.utc_now()) do
    iat = DateTime.to_unix(now)
    claims = %{"iat" => iat, "exp" => iat + @jwt_ttl_seconds, "iss" => app_id}

    jwk
    |> JOSE.JWT.sign(%{"alg" => "RS256", "typ" => "JWT"}, claims)
    |> JOSE.JWS.compact()
    |> elem(1)
  end

  @doc """
  Exchanges `jwt` for an installation token at the App installations endpoint.

  Returns `{:ok, %{token: ..., expires_at: DateTime.t(), permissions: map()}}`
  on a 2xx response, or a `{:github, classification, detail}` error tuple on an
  HTTP/transport failure, or `{:error, :invalid_installation_token_response}`
  when the 2xx body is missing the token/expiry fields.
  """
  @spec exchange_token(function(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def exchange_token(request_fun, jwt, installation_id) do
    request = %{method: :post, url: access_tokens_url(installation_id), token: jwt, body: %{}}

    case request_fun.(request) do
      {:ok, %{status: status} = response} when status in 200..299 ->
        parse_token_response(response)

      {:ok, %{status: _status} = response} ->
        {:error, Errors.github_status_error(response)}

      {:error, reason} ->
        {:error, Errors.classify_error({:error, reason})}
    end
  end

  @doc """
  The exact least-privilege permission set the App is permitted to hold:
  Contents (write), Issues (read/write), Pull requests (write), plus the
  implicit `metadata: read` GitHub always grants installation tokens.
  """
  @spec allowed_permissions() :: %{optional(String.t()) => String.t()}
  def allowed_permissions do
    %{
      "contents" => "write",
      "issues" => "write",
      "pull_requests" => "write",
      "metadata" => "read"
    }
  end

  @doc """
  Verifies the permission map GitHub granted the installation token against
  `allowed_permissions/0`. Returns `:ok` when every granted permission matches
  the allowed set exactly, or `{:error, %{extra_permissions: map()}}` listing
  the offending permission/level pairs. Any Administration, Actions, Secrets,
  or Workflows grant is therefore reported as a least-privilege violation.
  """
  @spec verify_permissions(map()) :: :ok | {:error, %{extra_permissions: map()}}
  def verify_permissions(granted) when is_map(granted) do
    case extra_permissions(granted) do
      [] -> :ok
      extra -> {:error, %{extra_permissions: Map.new(extra)}}
    end
  end

  @doc false
  @spec extra_permissions(map()) :: [{String.t(), term()}]
  def extra_permissions(granted) when is_map(granted) do
    Enum.reject(granted, fn {permission, level} ->
      Map.get(allowed_permissions(), permission) == level
    end)
  end

  @doc """
  Milliseconds until the installation token should be refreshed: the time left
  before `expires_at` minus a safety margin (default 5 minutes), floored at a
  small positive interval so an already-expired or expiring-soon token refreshes
  promptly without spinning a zero-delay timer.
  """
  @spec refresh_delay_ms(DateTime.t(), DateTime.t(), keyword()) :: pos_integer()
  def refresh_delay_ms(expires_at, now \\ DateTime.utc_now(), opts \\ []) do
    margin_seconds = Keyword.get(opts, :margin_seconds, @default_refresh_margin_seconds)

    remaining_ms =
      (DateTime.to_unix(expires_at) - DateTime.to_unix(now) - margin_seconds) * 1_000

    max(remaining_ms, @min_refresh_ms)
  end

  @doc """
  True when the installation token is rate-limit-usable: a `GET /rate_limit`
  returns 2xx and does not report a fully exhausted quota. Mirrors the daemon's
  existing PAT posture (#678) exactly — only an explicit `x-ratelimit-remaining`
  of 0 is treated as unusable, so a missing header never rejects a good token.
  """
  @spec rate_limit_usable?(String.t(), function()) :: boolean()
  def rate_limit_usable?(token, request_fun) when is_binary(token) and is_function(request_fun, 1) do
    request = %{method: :get, url: @rate_limit_url, token: token}

    case request_fun.(request) do
      {:ok, %{status: status} = response} when status in 200..299 ->
        Errors.rate_limit_remaining(response) != 0

      _ ->
        false
    end
  rescue
    _ -> false
  end

  @doc """
  Full acquisition pipeline used by both the boot path and the refresher:
  parse the App private key, build the JWT, exchange it for an installation
  token, verify the granted permission set, and confirm the token is
  rate-limit-usable.

  Returns `{:ok, %{token: ..., expires_at: ..., permissions: ...,
  permission_violation: nil | map()}}` on success (a permission violation is
  surfaced on the result, never silently dropped, and never prevents use of an
  otherwise valid token), or an error tuple when the key is missing/invalid,
  the exchange fails, or the token is rate-limit-exhausted.
  """
  @spec acquire(keyword()) :: {:ok, map()} | {:error, term()}
  def acquire(opts \\ []) do
    request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
    validate_fun = Keyword.get(opts, :validate_fun, &rate_limit_usable?/2)

    with {:ok, jwk} <- AppCredentials.parse_private_key(),
         {:ok, app_id} <- require_credential(AppCredentials.app_id(), :missing_app_id),
         {:ok, installation_id} <-
           require_credential(AppCredentials.installation_id(), :missing_installation_id) do
      exchange_and_validate(request_fun, validate_fun, app_jwt(jwk, app_id), installation_id)
    end
  end

  # Exchanges the signed JWT for an installation token, verifies the granted
  # permission set, and confirms the token is rate-limit-usable. Split out of
  # `acquire/1` so no function body nests deeper than Credo's limit.
  defp exchange_and_validate(request_fun, validate_fun, jwt, installation_id) do
    with {:ok, %{token: token} = result} <- exchange_token(request_fun, jwt, installation_id),
         true <- validate_fun.(token, request_fun) do
      violation =
        case verify_permissions(result.permissions) do
          :ok -> nil
          {:error, violation} -> violation
        end

      {:ok, Map.put(result, :permission_violation, violation)}
    else
      false -> {:error, :installation_token_rate_limited}
      {:error, _} = error -> error
    end
  end

  @doc false
  @spec require_credential(String.t() | nil, atom()) :: {:ok, String.t()} | {:error, atom()}
  def require_credential(value, _reason) when is_binary(value) and value != "", do: {:ok, value}
  def require_credential(_value, reason), do: {:error, reason}

  defp parse_token_response(%{body: body}) when is_map(body) do
    with token when is_binary(token) and token != "" <- Map.get(body, "token"),
         {:ok, expires_at} <- parse_expires_at(Map.get(body, "expires_at")) do
      {:ok, %{token: token, expires_at: expires_at, permissions: Map.get(body, "permissions") || %{}}}
    else
      _ -> {:error, :invalid_installation_token_response}
    end
  end

  defp parse_token_response(_response), do: {:error, :invalid_installation_token_response}

  @doc false
  @spec parse_expires_at(term()) :: {:ok, DateTime.t()} | {:error, term()}
  def parse_expires_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> {:error, :invalid_expires_at}
    end
  end

  def parse_expires_at(_value), do: {:error, :invalid_expires_at}
end
