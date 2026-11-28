defmodule AiurPushRelay.Provider.Router do
  @moduledoc "Routes delivery to the provider registered for each handle platform."
  use GenServer
  @behaviour AiurPushRelay.Provider

  alias AiurPushRelay.Provider.Disabled

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def provider, do: GenServer.call(__MODULE__, :provider)
  def set_provider(provider), do: GenServer.call(__MODULE__, {:set_provider, provider})
  def available?(platform), do: GenServer.call(__MODULE__, {:available?, platform})
  def health, do: GenServer.call(__MODULE__, :health)
  def new(providers, health), do: %{providers: Map.new(providers), health: health}
  def health(%{health: health}), do: health

  @impl true
  def init(_opts) do
    apns_provider =
      Application.get_env(
        :aiur_push_relay,
        :provider,
        if(Process.whereis(AiurPushRelay.ApnsJwt),
          do: AiurPushRelay.Provider.Apns,
          else: Disabled
        )
      )

    {fcm_provider, fcm_health} = configure_fcm()

    {:ok,
     %{
       provider: new(%{"apns" => apns_provider, "fcm" => fcm_provider}, fcm_health),
       fcm_health: fcm_health
     }}
  end

  def deliver(%{platform: platform} = row, envelope, state) do
    case Map.get(state.providers, platform) do
      nil ->
        {:error, :provider_unavailable}

      AiurPushRelay.Provider.Fake when platform == "fcm" ->
        AiurPushRelay.Provider.Fake.deliver(row, envelope)

      {AiurPushRelay.Provider.Fcm, account, auth_pid, request_fun} when platform == "fcm" ->
        if AiurPushRelay.Provider.Fcm.ready?(auth_pid),
          do:
            AiurPushRelay.Provider.Fcm.deliver_with(row, envelope, account, auth_pid, request_fun),
          else: {:retry, 60_000}

      _provider when platform == "fcm" ->
        {:error, :provider_unavailable}

      provider ->
        provider.deliver(row, envelope)
    end
  end

  @impl true
  def deliver(row, envelope), do: GenServer.call(__MODULE__, {:deliver, row, envelope})

  @impl true
  def handle_call({:set_provider, provider}, _from, state),
    do: {:reply, :ok, Map.put(state, :provider, provider)}

  def handle_call(:provider, _from, state),
    do: {:reply, state.provider.providers["fcm"], state}

  def handle_call({:available?, "apns"}, _from, state) do
    available =
      state.provider.providers["apns"] != Disabled and
        not is_nil(Process.whereis(AiurPushRelay.ApnsJwt))

    {:reply, available, state}
  end

  def handle_call({:available?, "fcm"}, _from, state) do
    allow_test = Application.get_env(:aiur_push_relay, :allow_test_fcm, false)
    {:reply, state.fcm_health == "ok" or (state.fcm_health == "test" and allow_test), state}
  end

  def handle_call({:available?, _platform}, _from, state), do: {:reply, false, state}

  def handle_call(:health, _from, state) do
    health = %{
      apns: if(available_in_state?(state, "apns"), do: "available", else: "unavailable"),
      fcm: state.fcm_health
    }

    {:reply, health, state}
  end

  def handle_call({:deliver, row, envelope}, _from, %{provider: provider} = state) do
    {:reply, deliver(row, envelope, provider), state}
  end

  defp configure_fcm do
    case Application.get_env(:aiur_push_relay, :fcm_provider) do
      nil ->
        case AiurPushRelay.Provider.Fcm.configure() do
          {:ok, account, auth_pid} ->
            {{AiurPushRelay.Provider.Fcm, account, auth_pid,
              Application.get_env(:aiur_push_relay, :fcm_request_fun, &Req.post/1)}, "ok"}

          result ->
            result
        end

      provider ->
        {provider, "test"}
    end
  end

  defp available_in_state?(state, "apns"),
    do:
      state.provider.providers["apns"] != Disabled and
        not is_nil(Process.whereis(AiurPushRelay.ApnsJwt))
end
