defmodule Aiur.ProviderAccountGeneration.Continuity do
  @moduledoc false

  @key {__MODULE__, :active_bindings}

  @spec service_id(GenServer.server()) :: atom() | nil
  def service_id(server) when is_atom(server), do: server
  def service_id(_server), do: nil

  @spec issue(GenServer.server(), atom(), atom()) :: map()
  def issue(server, provider, backend) do
    binding = make_ref()
    authority = make_ref()
    topic = mint_topic()
    entry_key = {provider, backend, binding}

    retain(service_id(server), entry_key, authority, topic, self())
    %{binding: binding, authority: authority, topic: topic}
  end

  @spec retain(atom() | nil, tuple(), reference(), String.t(), pid()) :: :ok
  def retain(nil, _entry_key, _authority, _topic, _holder), do: :ok

  def retain(service_id, entry_key, authority, topic, holder) when is_pid(holder) do
    update(service_id, &Map.put(&1, entry_key, %{authority: authority, topic: topic, holder: holder}))
  end

  @spec recover?(atom() | nil, tuple(), reference(), String.t()) :: boolean()
  def recover?(nil, _entry_key, _authority, _topic), do: false

  def recover?(service_id, entry_key, authority, topic) do
    case entries(service_id)[entry_key] do
      %{authority: ^authority, topic: ^topic, holder: holder} when is_pid(holder) ->
        if Process.alive?(holder) do
          true
        else
          :ok = forget(service_id, entry_key)
          false
        end

      _ ->
        false
    end
  end

  @spec forget(atom() | nil, tuple()) :: :ok
  def forget(nil, _entry_key), do: :ok
  def forget(service_id, entry_key), do: update(service_id, &Map.delete(&1, entry_key))

  defp entries(service_id), do: @key |> :persistent_term.get(%{}) |> Map.get(service_id, %{})

  defp update(service_id, change) do
    :global.trans({__MODULE__, service_id}, fn ->
      stores = :persistent_term.get(@key, %{})

      entries =
        stores
        |> Map.get(service_id, %{})
        |> Enum.reject(fn
          {_key, %{holder: holder}} when is_pid(holder) -> not Process.alive?(holder)
          _ -> true
        end)
        |> Map.new()
        |> change.()

      :persistent_term.put(@key, Map.put(stores, service_id, entries))
      :ok
    end)
  end

  defp mint_topic, do: "provider-account-generation:" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
end
