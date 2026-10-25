defmodule Aiur.GitHub.TimelineCache do
  @moduledoc false

  alias Aiur.GitHub.ResourceStore

  @table :aiur_github_dispatch_authorization_timelines
  @index :aiur_github_dispatch_authorization_timeline_index
  @max_entries 1_000

  @spec clear() :: :ok
  def clear do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    if :ets.whereis(@index) != :undefined, do: :ets.delete_all_objects(@index)
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

    now = System.system_time(:millisecond)
    data = %{"events" => events, "single_page" => single_page?, "per_page" => per_page, "stored_at_ms" => now}
    ResourceStore.put_resource(key(owner, repo, id), data, etag: etag, source: :fetch)
    bound_persisted(owner, repo, id, now)
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

  # A {key, stored_at} index keeps put from copying persisted bodies; the store
  # is listed once per repository to seed it after a restart.
  defp bound_persisted(owner, repo, id, now) do
    index = index_table()
    repo_id = {owner, repo}
    if :ets.insert_new(index, {{:seeded, repo_id}, true}), do: seed_index(index, owner, repo)
    :ets.insert(index, {{repo_id, id}, now})

    excess = :ets.select_count(index, [{{{repo_id, :_}, :_}, [], [true]}]) - @max_entries

    if excess > 0 do
      index
      |> :ets.select([{{{repo_id, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}])
      |> Enum.sort_by(&elem(&1, 1))
      |> Enum.take(excess)
      |> Enum.each(fn {old_id, _at} ->
        :ets.delete(index, {repo_id, old_id})
        ResourceStore.drop_data(key(owner, repo, old_id))
      end)
    end
  end

  defp seed_index(index, owner, repo) do
    for {{_type, _owner, _repo, id}, entry} <- ResourceStore.list_type(:issue_timeline, owner <> "/" <> repo) do
      :ets.insert_new(index, {{{owner, repo}, id}, stored_at(entry)})
    end
  end

  defp index_table do
    case :ets.whereis(@index) do
      :undefined -> :ets.new(@index, [:named_table, :public, :set])
      _other -> @index
    end
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
