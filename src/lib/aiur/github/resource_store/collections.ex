defmodule Aiur.GitHub.ResourceStore.Collections do
  @moduledoc """
  Internal collections operations for `Aiur.GitHub.ResourceStore`.
  """

  alias Aiur.GitHub.{MembershipAccess, ResourceEvents}
  alias Aiur.GitHub.ResourceStore.{Checkpoint, Types}
  import Aiur.GitHub.ResourceStore.Deposit, only: [deposit: 5]
  import Aiur.GitHub.ResourceStore.Storage, only: [with_table: 3, now_ms: 0]
  @resource_types Types.resource_types()

  @type key :: Aiur.GitHub.ResourceStore.key()
  @type resource_type :: Aiur.GitHub.ResourceStore.resource_type()
  @type entry :: Aiur.GitHub.ResourceStore.entry()

  @spec clear(:ets.table(), resource_type(), String.t(), String.t()) :: :ok
  def clear(table, resource_type, owner, repo)
      when is_atom(resource_type) and is_binary(owner) and is_binary(repo),
      do:
        MembershipAccess.run(resource_type, :ok, fn ->
          clear_entries(table, resource_type, owner, repo)
        end)

  def clear(_table, _resource_type, _owner, _repo), do: :ok

  defp clear_entries(table, resource_type, owner, repo) do
    if resource_type in @resource_types do
      owner = String.downcase(owner)
      repo = String.downcase(repo)

      with_table(table, :ok, fn table ->
        keys = :ets.match_object(table, {{resource_type, owner, repo, :_}, :_}) |> Enum.map(&elem(&1, 0))
        :ets.match_delete(table, {{resource_type, owner, repo, :_}, :_})
        Checkpoint.remove_entries(keys)
        ResourceEvents.publish_cleared(resource_type, owner, repo)
        :ok
      end)
    else
      :ok
    end
  end

  @spec membership_snapshot(:ets.table(), String.t(), String.t()) :: {:ok, list()} | {:error, :unavailable}
  def membership_snapshot(table, owner, repo) do
    MembershipAccess.run(:sub_issue, {:error, :unavailable}, fn ->
      {:ok, list(table, :sub_issue, owner, repo) |> Enum.sort()}
    end)
  end

  @spec replace_membership(:ets.table(), String.t(), String.t(), list(), list()) :: :ok | {:error, atom()}
  def replace_membership(table, owner, repo, expected, edges) do
    MembershipAccess.run(:sub_issue, {:error, :unavailable}, fn ->
      if Enum.sort(list(table, :sub_issue, owner, repo)) == expected do
        replace_membership_entries(table, String.downcase(owner), String.downcase(repo), expected, edges)
      else
        {:error, :membership_changed}
      end
    end)
  end

  defp replace_membership_entries(table, owner, repo, previous, edges) do
    version = DateTime.to_iso8601(DateTime.utc_now())
    held = Map.new(previous)

    entries =
      Enum.map(edges, fn {id, data} ->
        key = {:sub_issue, owner, repo, id}

        entry =
          deposit(Map.get(held, key, %{}), {:ok, data}, :reconciliation, version, etag: :derive)

        {key, Map.put(entry, :recorded_at_ms, now_ms())}
      end)

    with_table(table, {:error, :unavailable}, fn table ->
      # All preparation precedes mutation; readers, writers, checkpoint and
      # expiry run on this same owner for membership, so none see a partial set.
      old_keys = :ets.match_object(table, {{:sub_issue, owner, repo, :_}, :_}) |> Enum.map(&elem(&1, 0))
      :ets.match_delete(table, {{:sub_issue, owner, repo, :_}, :_})
      :ets.insert(table, entries)
      new_keys = Enum.map(entries, &elem(&1, 0))
      Checkpoint.remove_entries(old_keys -- new_keys)
      Checkpoint.mark_entries_dirty(new_keys)
      ResourceEvents.publish_replaced(:sub_issue, owner, repo)
      :ok
    end)
  end

  @spec list(:ets.table(), resource_type(), String.t(), String.t()) :: [{key(), entry()}]
  def list(table, resource_type, owner, repo)
      when is_atom(resource_type) and is_binary(owner) and is_binary(repo),
      do: MembershipAccess.run(resource_type, [], fn -> list_entries(table, resource_type, owner, repo) end)

  def list(_table, _resource_type, _owner, _repo), do: []

  defp list_entries(table, resource_type, owner, repo) do
    if resource_type in @resource_types do
      owner = String.downcase(owner)
      repo = String.downcase(repo)

      with_table(table, [], fn table ->
        :ets.match_object(table, {{resource_type, owner, repo, :_}, :_})
      end)
    else
      []
    end
  end

  @spec reset(:ets.table()) :: :ok
  def reset(table), do: MembershipAccess.run(:sub_issue, :ok, fn -> reset_entries(table) end)

  defp reset_entries(table) do
    with_table(table, :ok, fn table ->
      keys = :ets.tab2list(table) |> Enum.map(&elem(&1, 0))
      :ets.delete_all_objects(table)
      Checkpoint.remove_entries(keys)
      :ok
    end)
  end

  @spec forget(:ets.table(), key() | nil) :: :ok
  def forget(_table, nil), do: :ok

  def forget(table, key), do: MembershipAccess.run(key, :ok, fn -> forget_entry(table, key) end)

  defp forget_entry(table, key) do
    with_table(table, :ok, fn table ->
      :ets.delete(table, key)
      Checkpoint.remove_entries([key])
      :ok
    end)
  end
end
