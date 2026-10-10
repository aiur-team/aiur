defmodule Aiur.GitHub.TimelineCache do
  @moduledoc false

  alias Aiur.GitHub.ResourceStore

  @table :aiur_github_dispatch_authorization_timelines
  @max_entries 1_000

  @spec clear() :: :ok
  def clear do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end

  @spec get(String.t(), String.t(), String.t(), pos_integer()) :: map() | nil
  def get(owner, repo, id, per_page) do
    case :ets.lookup(table(), id) do
      [{^id, %{repository: {^owner, ^repo}, per_page: ^per_page} = held}] -> held
      _other -> persisted(owner, repo, id, per_page)
    end
  end

  @spec page_sizes(String.t(), String.t(), String.t(), [pos_integer()]) :: [pos_integer()]
  def page_sizes(owner, repo, id, sizes) do
    case :ets.lookup(table(), id) do
      [{^id, %{repository: {^owner, ^repo}}}] -> sizes
      _other -> persisted_page_sizes(owner, repo, id, sizes)
    end
  end

  defp persisted_page_sizes(owner, repo, id, sizes) do
    case Enum.find(sizes, &(not is_nil(get(owner, repo, id, &1)))) do
      nil -> sizes
      saved -> Enum.drop_while(sizes, &(&1 != saved))
    end
  end

  @spec put(String.t(), String.t(), String.t(), String.t() | nil, [map()], boolean(), pos_integer()) :: :ok
  def put(owner, repo, id, etag, events, single_page?, per_page) do
    held = %{etag: etag, events: events, single_page?: single_page?, per_page: per_page, repository: {owner, repo}}
    :ets.insert(table(), {id, held})
    if :ets.info(@table, :size) > @max_entries, do: clear()

    data = %{"events" => events, "single_page" => single_page?, "per_page" => per_page, "stored_at_ms" => System.system_time(:millisecond)}
    ResourceStore.put_resource(key(owner, repo, id), data, etag: etag, source: :fetch)
    bound_persisted(owner, repo)
    :ok
  end

  defp persisted(owner, repo, id, per_page) do
    with {:ok, %{data: %{"events" => events, "single_page" => single_page?, "per_page" => ^per_page}, etag: etag}} <- ResourceStore.fetch(key(owner, repo, id)),
         true <- is_list(events) and Enum.all?(events, &valid_event?/1) and is_boolean(single_page?) do
      %{events: events, single_page?: single_page?, per_page: per_page, etag: etag}
    else
      _other -> nil
    end
  end

  defp valid_event?(event) when is_map(event) do
    Enum.all?(["label", "actor"], fn field ->
      value = Map.get(event, field)
      is_nil(value) or is_map(value)
    end)
  end

  defp valid_event?(_event), do: false

  defp bound_persisted(owner, repo) do
    entries = ResourceStore.list_type(:issue_timeline, owner <> "/" <> repo)

    entries
    |> Enum.sort_by(fn {_key, entry} -> stored_at(entry) end)
    |> Enum.take(max(length(entries) - @max_entries, 0))
    |> Enum.each(fn {key, _entry} -> ResourceStore.drop_data(key) end)
  end

  defp stored_at(entry) when is_map(entry), do: Map.get(entry, "stored_at_ms", 0)
  defp stored_at(_entry), do: 0

  defp key(owner, repo, id), do: ResourceStore.key(:issue_timeline, owner, repo, id)

  defp table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
      _other -> @table
    end
  end
end
