defmodule AiurPushRelay.Provider.Apns.Jwt do
  @moduledoc "Owns private signing material and serializes the 40-minute provider token cache."
  use GenServer
  import Bitwise

  @spec load((String.t() -> String.t() | nil)) :: {:ok, map()} | {:error, :unavailable}
  def load(env \\ &System.get_env/1) do
    with team when is_binary(team) and team != "" <- env.("AIUR_RELAY_APNS_TEAM_ID"),
         kid when is_binary(kid) and kid != "" <- env.("AIUR_RELAY_APNS_KEY_ID"),
         path when is_binary(path) <- env.("AIUR_RELAY_APNS_KEY_FILE"),
         {:ok, %{type: :regular, mode: mode}} <- File.stat(path),
         true <- band(mode, 0o777) == 0o600,
         {:ok, pem} <- File.read(path) do
      key = JOSE.JWK.from_pem(pem)
      {_, %{"kty" => "EC", "crv" => "P-256", "d" => _}} = JOSE.JWK.to_map(key)
      config = %{team: team, kid: kid, key: key}
      _ = sign(config, System.system_time(:second))
      {:ok, config}
    else
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @spec token(GenServer.server(), String.t() | nil) :: String.t()
  def token(server, expired \\ nil), do: GenServer.call(server, {:token, expired})

  @impl true
  def init(opts) do
    {:ok,
     %{
       config: Keyword.fetch!(opts, :config),
       clock: Keyword.get(opts, :clock, fn -> System.system_time(:second) end),
       token: nil,
       at: 0
     }}
  end

  @impl true
  def format_status(status), do: %{status | state: :redacted, message: :redacted}

  @impl true
  def handle_call({:token, expired}, _, state) do
    now = state.clock.()

    if is_nil(state.token) or now - state.at >= 2400 or
         (not is_nil(expired) and expired == state.token) do
      token = sign(state.config, now)
      {:reply, token, %{state | token: token, at: now}}
    else
      {:reply, state.token, state}
    end
  end

  defp sign(config, now) do
    {_, token} =
      JOSE.JWT.sign(config.key, %{"alg" => "ES256", "kid" => config.kid}, %{
        "iss" => config.team,
        "iat" => now
      })
      |> JOSE.JWS.compact()

    token
  end
end
