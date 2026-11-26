defmodule AiurPushRelay.Provider.Fcm.Auth do
  @moduledoc "Loads a protected Firebase service account and exchanges RS256 JWTs for OAuth access tokens."
  use GenServer

  @scope "https://www.googleapis.com/auth/firebase.messaging"
  @refresh_margin 300

  def child_spec(opts),
    do: %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

  def token(server), do: GenServer.call(server, :token, 30_000)

  @impl true
  def init(opts) do
    {:ok,
     %{
       account: Keyword.fetch!(opts, :account),
       request_fun: Keyword.get(opts, :request_fun, &Req.post/1),
       clock: Keyword.get(opts, :clock, fn -> System.system_time(:second) end),
       cached: nil
     }}
  end

  @impl true
  def handle_call(:token, _from, state) do
    case state.cached do
      %{token: token, expires_at: expiry} when expiry > 0 ->
        if expiry - state.clock.() > @refresh_margin do
          {:reply, {:ok, token}, state}
        else
          refresh(state)
        end

      _ ->
        refresh(state)
    end
  end

  defp refresh(state) do
    case exchange(state) do
      {:ok, token, expires_at} ->
        {:reply, {:ok, token}, %{state | cached: %{token: token, expires_at: expires_at}}}

      {:error, _} = error ->
        {:reply, error, %{state | cached: nil}}
    end
  end

  def load(path) do
    with {:ok, %{mode: mode}} <- File.stat(path),
         true <- Bitwise.band(mode, 0o077) == 0,
         {:ok, json} <- File.read(path),
         {:ok, account} <- Jason.decode(json),
         true <-
           is_binary(account["project_id"]) and is_binary(account["client_email"]) and
             is_binary(account["private_key"]) and is_binary(account["token_uri"]),
         true <- https_url?(account["token_uri"]),
         {:ok, jwk} <- parse_key(account["private_key"]) do
      {:ok, Map.put(account, "jwk", jwk)}
    else
      _ -> {:error, :invalid_service_account}
    end
  rescue
    _ -> {:error, :invalid_service_account}
  end

  defp exchange(state) do
    now = state.clock.()

    claims = %{
      "iss" => state.account["client_email"],
      "scope" => @scope,
      "aud" => state.account["token_uri"],
      "iat" => now,
      "exp" => now + 3600
    }

    jwt =
      JOSE.JWT.sign(state.account["jwk"], %{"alg" => "RS256", "typ" => "JWT"}, claims)
      |> JOSE.JWS.compact()
      |> elem(1)

    body =
      URI.encode_query(%{
        "grant_type" => "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion" => jwt
      })

    case state.request_fun.(
           url: state.account["token_uri"],
           body: body,
           headers: [{"content-type", "application/x-www-form-urlencoded"}],
           retry: false
         ) do
      {:ok, %{status: status, body: %{"access_token" => token, "expires_in" => ttl}}}
      when status in 200..299 and is_binary(token) and is_integer(ttl) and ttl > 0 ->
        {:ok, token, now + ttl}

      _ ->
        {:error, :token_exchange_failed}
    end
  rescue
    _ -> {:error, :token_exchange_failed}
  end

  defp parse_key(private_key) do
    {:ok, JOSE.JWK.from_pem(private_key)}
  rescue
    _ -> {:error, :invalid_key}
  end

  defp https_url?(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> true
      _ -> false
    end
  end
end
