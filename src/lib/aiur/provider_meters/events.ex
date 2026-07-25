defmodule Aiur.ProviderMeters.Events do
  @moduledoc false

  @pubsub Aiur.PubSub

  @spec topic(:codex | :claude, :app_server, String.t()) :: String.t()
  def topic(provider, backend, generation), do: "provider_meters:#{provider}:#{backend}:#{generation}"

  @spec subscribe(:codex | :claude, :app_server, String.t()) :: :ok | {:error, :subscription_unavailable}
  def subscribe(provider, backend, generation) do
    case Process.whereis(@pubsub) do
      pid when is_pid(pid) -> Phoenix.PubSub.subscribe(@pubsub, topic(provider, backend, generation))
      _ -> {:error, :subscription_unavailable}
    end
  end

  @spec broadcast(Aiur.ProviderMeterSnapshot.t()) :: :ok
  def broadcast(snapshot) do
    case Process.whereis(@pubsub) do
      pid when is_pid(pid) ->
        Phoenix.PubSub.broadcast(
          @pubsub,
          topic(snapshot.provider, snapshot.backend, snapshot.provider_account_generation),
          {:provider_meter_changed, snapshot}
        )

      _ ->
        :ok
    end
  end
end
