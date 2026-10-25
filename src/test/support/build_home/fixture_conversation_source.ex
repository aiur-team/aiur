defmodule Aiur.TestSupport.BuildHome.FixtureConversationSource do
  @moduledoc "Design-exported conversations with deterministic 100-entry pages."
  @behaviour AiurWeb.Build.ConversationSource
  alias Aiur.TestSupport.BuildHome.{FixtureSource, Scale}

  @dir Path.expand("../../fixtures/build_home/conversations", __DIR__)
  @states ~w(live ended known_empty stale unavailable restart_unknown not_retained)a
  @keys ~w(id k at text name arg res bad file lines add del ev label sub go pct)a

  @impl true
  def tail(ref, after_cursor, opts) do
    with {:ok, view} <- view(ref, opts) do
      entries = view.entries
      start = max(0, length(entries) - Keyword.get(opts, :limit, 100))
      chosen = if after_cursor == "fx:#{length(entries)}", do: [], else: Enum.drop(entries, start)
      {:ok, Map.merge(view, %{entries: chosen, before: cursor(start), more?: start > 0, last: cursor(length(entries))})}
    end
  end

  @impl true
  def page(ref, before, opts) do
    with {:ok, view} <- view(ref, opts),
         {index, ""} <- parse_cursor(before),
         true <- index >= 0 and index <= length(view.entries) do
      start = max(0, index - Keyword.get(opts, :limit, 100))
      {:ok, Map.merge(view, %{entries: Enum.slice(view.entries, start, index - start), before: cursor(start), more?: start > 0})}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  @impl true
  def subscribe(_ref, _opts), do: :ok
  @impl true
  def unsubscribe(_ref, _opts), do: :ok

  defp view(ref, opts) do
    dataset = Keyword.get(opts, :dataset, Application.get_env(:aiur, :build_fixture_dataset, "live"))
    scenario = Keyword.get(opts, :scenario)
    # Scale sets are derived from dense, so they read dense conversations.
    file = if dataset in FixtureSource.scaled(), do: "dense", else: dataset
    path = Path.join(Keyword.get(opts, :dir, @dir), if(scenario, do: "states.json", else: file <> ".json"))

    case decode(path, dataset in FixtureSource.scaled() and scenario == nil) do
      {:ok, data} -> assemble(if(scenario, do: data[scenario], else: entries(dataset, data, ref.id)), ref)
      _ -> {:error, :unavailable}
    end
  end

  # dense.json is 11 MB; scale sets decode it once per VM so C8 measures the page, not the decode.
  defp decode(path, true) do
    key = {__MODULE__, :decoded, path}

    case :persistent_term.get(key, nil) do
      nil -> tap(decode(path, false), &cache(key, &1))
      data -> {:ok, data}
    end
  end

  defp decode(path, false) do
    with {:ok, text} <- File.read(path), do: Jason.decode(text)
  end

  defp cache(key, {:ok, data}), do: :persistent_term.put(key, data)
  defp cache(_key, _error), do: :ok

  # The perf ticket of scale10k carries a 5,000-entry transcript (MP-E8-C12-T06).
  defp entries("scale10k", data, id) do
    {:ok, dense} = FixtureSource.full(dataset: "dense")

    if id == Scale.perf_ticket_id(dense) do
      key = {__MODULE__, :perf_transcript, id}
      :persistent_term.get(key, nil) || tap(Scale.conversation(data[id], 5_000), &:persistent_term.put(key, &1))
    else
      data[id]
    end
  end

  defp entries(_dataset, data, id), do: data[id]

  defp assemble(nil, _ref), do: {:error, :unavailable}

  defp assemble(entries, ref) when is_list(entries) do
    assemble(%{"entries" => entries, "state" => if(Map.get(ref, :closed?, false), do: "ended", else: "live")}, ref)
  end

  defp assemble(data, _ref) do
    state = Enum.find(@states, &(Atom.to_string(&1) == data["state"])) || :unavailable

    {:ok,
     %{
       state: state,
       entries: Enum.map(data["entries"], &entry/1),
       live?: Map.get(data, "live", state == :live),
       observed_at: DateTime.from_unix!(Map.get(data, "observed_at", 1_791_408_000_000), :millisecond),
       reason: nil,
       note: nil,
       evicted: 0
     }}
  end

  defp entry(raw), do: Map.new(@keys, &{&1, raw[Atom.to_string(&1)]}) |> Map.reject(fn {_key, value} -> is_nil(value) end) |> Map.put(:at, raw["at"])
  defp cursor(index), do: "fx:#{index}"
  defp parse_cursor("fx:" <> rest), do: Integer.parse(rest)
  defp parse_cursor("d:" <> rest), do: Integer.parse(rest)
  defp parse_cursor(_), do: :error
end
