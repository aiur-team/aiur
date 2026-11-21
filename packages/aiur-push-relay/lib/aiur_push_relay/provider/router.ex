defmodule AiurPushRelay.Provider.Router do
  @moduledoc "Routes delivery to the provider registered for each handle platform."
  use GenServer
  @behaviour AiurPushRelay.Provider

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def new(providers, health), do: %{providers: Map.new(providers), health: health}

  def health(%{health: health}), do: health
  def provider, do: GenServer.call(__MODULE__, :provider)
  def set_provider(provider), do: GenServer.call(__MODULE__, {:set_provider, provider})

  @impl true
  def init(_opts), do: {:ok, %{provider: new([], "unconfigured")}}

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

  @impl true
  def handle_call(:provider, _from, state), do: {:reply, state.provider.providers["fcm"], state}

  @impl true
  def handle_call({:deliver, row, envelope}, _from, %{provider: provider} = state) do
    {:reply, deliver(row, envelope, provider), state}
  end
end
