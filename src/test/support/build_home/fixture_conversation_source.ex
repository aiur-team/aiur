defmodule Aiur.TestSupport.BuildHome.FixtureConversationSource do
  @moduledoc "Design-exported conversations with deterministic 100-entry pages."
  @behaviour AiurWeb.Build.ConversationSource

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
    path = Path.join(Keyword.get(opts, :dir, @dir), if(scenario, do: "states.json", else: dataset <> ".json"))

    with {:ok, text} <- File.read(path), {:ok, data} <- Jason.decode(text) do
      assemble(if(scenario, do: data[scenario], else: data[ref.id]), ref)
    else
      _ -> {:error, :unavailable}
    end
  end

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
