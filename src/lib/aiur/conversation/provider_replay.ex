defmodule Aiur.Conversation.ProviderReplay do
  @moduledoc false

  alias Aiur.Conversation.{Entry, JournalSessions}

  # Provider files replay from the beginning after a new daemon run. Their
  # stable record IDs must survive the writer's per-session dedup boundary.
  @spec filter(map(), list()) :: {:ok, map(), list()} | {:error, term()}
  def filter(state, [{:entry, %{transcript_source: %{kind: :provider_file}} = source, _, _} | _] = inputs) do
    key = {source.harness, source.provider_session_id}

    with {:ok, keys} <- historical_keys(state, key) do
      inputs = Enum.reject(inputs, fn {:entry, _, entry, _} -> MapSet.member?(keys.dedup, Entry.dedup_key(entry)) end)
      {:ok, Map.put(state, :provider_replay, {key, keys}), inputs}
    end
  end

  def filter(state, inputs), do: {:ok, Map.delete(state, :provider_replay), inputs}

  @spec remember(map(), list()) :: map()
  def remember(%{provider_replay: {key, keys}} = state, entries) do
    keys = Enum.reduce(entries, keys, &remember_entry/2)
    Map.put(state, :provider_replay, {key, keys})
  end

  def remember(state, _entries), do: state

  defp remember_entry(entry, keys) do
    if to_string(Map.get(entry, :kind) || Map.get(entry, "kind")) == "gap",
      do: keys,
      else: JournalSessions.remember(keys, Entry.dedup_key(entry))
  end

  defp historical_keys(%{provider_replay: {key, keys}}, key), do: {:ok, keys}

  defp historical_keys(state, {harness, provider}) do
    with {:ok, bytes} <- File.read(Path.join(state.dir, "sessions.jsonl")),
         {:ok, entries} <- state.store.stream_entries(state.dir, 1, :infinity) do
      sequences =
        bytes
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["type"] == "start" and &1["harness"] == harness and &1["provider_session_id"] == provider))
        |> MapSet.new(& &1["session_seq"])

      keys =
        entries
        |> Stream.filter(&(MapSet.member?(sequences, &1["session_seq"]) and &1["kind"] != "gap"))
        |> Enum.reduce(%{dedup: MapSet.new(), dedup_order: :queue.new()}, &remember_entry/2)

      {:ok, keys}
    end
  end
end
