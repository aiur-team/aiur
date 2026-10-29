defmodule Aiur.ResourceFetchTestSupport do
  @moduledoc false
  import ExUnit.Assertions
  import ExUnit.Callbacks
  alias Aiur.GitHub.ResourceStore

  def key(id), do: ResourceStore.key(:pull_request, "aiur-team", "aiur", 90_000 + id)

  def recorder(result) do
    {:ok, calls} = Agent.start_link(fn -> %{count: 0, opts: []} end)

    fetcher = fn opts ->
      Agent.update(calls, fn state -> %{count: state.count + 1, opts: state.opts ++ [opts]} end)
      result
    end

    {fetcher, calls}
  end

  def count(calls), do: Agent.get(calls, & &1.count)

  # Backdates the body's own recorded fetch time. The entry is otherwise
  # untouched, so this exercises the same path a real ageing entry takes.
  def age_body!(key, by_ms) do
    table = Aiur.GitHub.ResourceStore.Table
    [{^key, entry}] = :ets.lookup(table, key)
    :ets.insert(table, {key, Map.update!(entry, :fetched_at_ms, &(&1 - by_ms))})
    :ok
  end

  def stop_store! do
    case Process.whereis(ResourceStore) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        :ok = Supervisor.terminate_child(Aiur.Supervisor, ResourceStore)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          5_000 -> flunk("ResourceStore did not stop")
        end
    end

    on_exit(fn ->
      if is_nil(Process.whereis(ResourceStore)), do: Supervisor.restart_child(Aiur.Supervisor, ResourceStore)
    end)
  end
end
