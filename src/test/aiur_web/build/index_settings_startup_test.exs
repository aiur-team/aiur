defmodule AiurWeb.Build.IndexSettingsStartupTest do
  use ExUnit.Case, async: false

  import Aiur.TestSupport, only: [receive_barrier: 1]
  import Aiur.TestSupport.BuildHome.IndexParts, only: [now: 0, parts: 0]

  alias AiurWeb.Build.Index

  test "settings loading retries with backoff and recovers without another signal" do
    parent = self()
    loading = %{parts() | settings: {:error, :workflow_not_loaded}}

    pid =
      start_supervised!(
        {Index,
         name: nil,
         subscribe: fn -> :ok end,
         read: fn
           :all, _previous, _opts ->
             loading

           dirty, _previous, _opts ->
             send(parent, {:settings_retry, self(), dirty})
             receive(do: ({:return, value} -> value))
         end,
         timer: fn server, message, ms ->
           send(parent, {:settings_timer, server, message, ms})
           make_ref()
         end,
         daemon_timer: fn _, _, _ -> make_ref() end,
         daemon_read: fn _ -> %{state: "live", heartbeat_at: 1, observed_at: 2} end,
         clock: &now/0},
        id: :settings_loading_index
      )

    assert {:error, :settings_loading} = Index.window(pid, "Etc/UTC")
    assert_receive {:settings_timer, ^pid, :flush, 500}, 1_000
    send(pid, :flush)
    receive_barrier({:settings_retry, worker, dirty})
    assert dirty == MapSet.new([:settings])
    send(worker, {:return, loading})
    assert_receive {:settings_timer, ^pid, :flush, 1_000}, 1_000
    send(pid, :flush)
    receive_barrier({:settings_retry, worker, dirty})
    assert dirty == MapSet.new([:settings])
    send(worker, {:return, %{loading | now: {:error, :read_failed}}})
    assert_receive {:settings_timer, ^pid, :flush, 2_000}, 1_000
    send(pid, :flush)
    receive_barrier({:settings_retry, worker, dirty})
    assert dirty == MapSet.new([:now, :settings])
    send(worker, {:return, parts()})
    assert await_ready(pid, 100)
    refute_received {:settings_timer, ^pid, :flush, _delay}
  end

  test "a now timeout leaves unread settings loading only until its startup deadline" do
    parent = self()
    now_ms = start_supervised!({Agent, fn -> 0 end})

    pid =
      start_supervised!(
        {Index,
         name: nil,
         subscribe: fn -> :ok end,
         read: fn
           :all, _previous, _opts ->
             Process.put(:aiur_build_index_read_part, :now)
             receive(do: (:continue -> :ok))

           dirty, _previous, _opts ->
             send(parent, {:settings_retry, self(), dirty})
             receive(do: ({:return, value} -> value))
         end,
         timer: fn server, message, ms ->
           send(parent, {:settings_timer, server, message, ms})
           make_ref()
         end,
         daemon_timer: fn _, _, _ -> make_ref() end,
         daemon_read: fn _ -> %{state: "live", heartbeat_at: 1, observed_at: 2} end,
         clock: fn -> Agent.get(now_ms, & &1) end,
         read_timeout: 10,
         settings_startup_timeout_ms: 100},
        id: :settings_timeout_index
      )

    assert_receive {:settings_timer, ^pid, :flush, 500}, 1_000
    assert {:error, :settings_loading} = Index.window(pid, "Etc/UTC")
    send(pid, :flush)
    receive_barrier({:settings_retry, worker, dirty})
    assert MapSet.member?(dirty, :settings)
    Agent.update(now_ms, &(&1 + 101))
    send(worker, {:return, :sys.get_state(pid).parts})
    assert await_unavailable(pid, 100)
    assert MapSet.member?(:sys.get_state(pid).dirty, :now)
    refute MapSet.member?(:sys.get_state(pid).dirty, :settings)
  end

  defp await_ready(_pid, 0), do: false

  defp await_ready(pid, attempts) do
    case Index.window(pid, "Etc/UTC") do
      {:ok, _snapshot} ->
        true

      {:error, :settings_loading} ->
        Process.sleep(5)
        await_ready(pid, attempts - 1)
    end
  end

  defp await_unavailable(_pid, 0), do: false

  defp await_unavailable(pid, attempts) do
    case Index.window(pid, "Etc/UTC") do
      {:error, :epic_config_unavailable} ->
        true

      _loading ->
        Process.sleep(5)
        await_unavailable(pid, attempts - 1)
    end
  end
end
