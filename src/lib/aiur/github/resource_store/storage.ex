defmodule Aiur.GitHub.ResourceStore.Storage do
  @moduledoc """
  Internal storage operations for `Aiur.GitHub.ResourceStore`.
  """

  alias Aiur.GitHub.MembershipAccess

  @spec lookup(:ets.table(), term()) :: map() | nil
  def lookup(table, key), do: MembershipAccess.run(key, nil, fn -> lookup_entry(table, key) end)

  defp lookup_entry(table, key) do
    with_table(table, nil, fn table ->
      case :ets.lookup(table, key) do
        [{^key, entry}] -> entry
        _other -> nil
      end
    end)
  end

  # Every read and write funnels through here so a missing table — no store
  # started, a store that crashed, a test that never booted one — is answered
  # with the caller's storeless default instead of raising into a poll task.
  @spec with_table(:ets.table(), term(), (:ets.table() -> term())) :: term()
  def with_table(table, default, fun) do
    case :ets.whereis(table) do
      :undefined -> default
      table -> fun.(table)
    end
  rescue
    ArgumentError -> default
  end

  @spec now_ms() :: integer()
  def now_ms, do: System.system_time(:millisecond)
end
