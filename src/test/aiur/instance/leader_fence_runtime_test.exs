defmodule Aiur.Instance.LeaderFenceRuntimeTest do
  use ExUnit.Case, async: false

  alias Aiur.Instance.LeaderFence

  test "allows primary when the shared lease store is not configured" do
    with_aiur_env(:lease_database_url, nil, fn ->
      assert LeaderFence.allowed?(role: "primary")
    end)
  end

  test "keeps the booted secondary role fenced after a config change" do
    with_aiur_env(:lease_database_url, nil, fn ->
      with_aiur_env(:booted_instance_role, "secondary", fn ->
        refute LeaderFence.allowed?()
      end)
    end)
  end

  test "refuses primary when the configured lease store is unreachable" do
    {:ok, store} = GenServer.start_link(__MODULE__.UnavailableLeaseStore, nil)
    on_exit(fn -> if Process.alive?(store), do: GenServer.stop(store) end)

    with_aiur_env(:lease_database_url, "postgres://unreachable.invalid/aiur", fn ->
      refute LeaderFence.allowed?(role: "primary", store_opts: [server: store])
    end)
  end

  defp with_aiur_env(key, value, fun) do
    previous = Application.get_env(:aiur, key)
    if is_nil(value), do: Application.delete_env(:aiur, key), else: Application.put_env(:aiur, key, value)

    try do
      fun.()
    after
      if is_nil(previous), do: Application.delete_env(:aiur, key), else: Application.put_env(:aiur, key, previous)
    end
  end

  defmodule UnavailableLeaseStore do
    use GenServer

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(_request, _from, state), do: {:reply, {:error, :offline}, state}
  end
end
