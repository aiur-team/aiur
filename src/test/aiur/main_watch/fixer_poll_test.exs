defmodule Aiur.MainWatch.FixerPollTest do
  use Aiur.TestSupport
  alias Aiur.CI.FailureDigest
  alias Aiur.MainWatch
  alias Aiur.MainWatch.Persistence

  test "background main-watch files a real red observation and retries write failures" do
    parent = self()
    unless Process.whereis(Aiur.TaskSupervisor), do: start_supervised!({Task.Supervisor, name: Aiur.TaskSupervisor})
    calls = start_supervised!({Agent, fn -> 0 end})

    red = %{
      sha: String.duplicate("a", 40),
      completed_at: 1,
      run_fingerprint: [{"ci", 1, 2, 1, "completed", "failure", 1}],
      run_urls: ["run"],
      checks: [%{name: "test", conclusion: "failure"}],
      digest: %FailureDigest{signature: String.duplicate("b", 64), tests: :unknown}
    }

    result = %{observations: [red], runs: [], commits: [red.sha], actions_write: false}

    options = [
      name: nil,
      subscribe: false,
      config: %{on_red: "dispatch_fixer", fixer_label: "main-fix", workflows: [], canary_minutes: 0},
      repo: "owner/repo",
      branch: "main",
      actions_write: false,
      debounce_ms: 0,
      interval_ms: 60_000,
      load_fun: fn _, _ -> Persistence.empty() end,
      poll_fun: fn _, _, _ ->
        send(parent, {:polling, self()})

        receive do
          :continue -> {:ok, result}
        end
      end,
      suspects_fun: fn _, _, _, _, _ -> [] end,
      save_fun: fn _, _, data ->
        send(parent, {:saved, data})
        :ok
      end,
      emit_fun: fn topic, payload ->
        send(parent, {:emitted, topic, payload})
        :ok
      end,
      fixer_open: fn _, _ -> {:ok, []} end,
      fixer_app?: true,
      fixer_refresh: fn -> :ok end,
      fixer_create: fn body, _ ->
        count = Agent.get_and_update(calls, &{&1, &1 + 1})
        send(parent, {:created, body})
        if count == 0, do: {:error, :github_unavailable}, else: {:ok, %{"number" => 7}}
      end,
      fixer_alert: fn topic, payload ->
        send(parent, {:alert, topic, payload})
        :ok
      end,
      fixer_snapshot: fn -> %{running: []} end
    ]

    server = start_supervised!({MainWatch, options})
    receive_barrier({:polling, worker})
    assert MainWatch.state(server).status == :unknown
    send(worker, :continue)
    receive_barrier({:saved, failed})
    refute failed.unavailable
    assert failed.state.status == :red
    assert_received {:alert, "system.main.fixer.failed", %{reason: ":github_unavailable"}}
    MainWatch.state(server)
    flush_saved()
    GenServer.cast(server, :reconcile)
    receive_barrier({:polling, worker})
    send(worker, :continue)
    receive_barrier({:saved, successful})
    assert successful.state.status == :red
    assert MainWatch.state(server).status == :red
    assert_received {:created, %{"labels" => ["agent:todo", "priority:1", "complexity:1", "main-fix"]}}
    assert_received {:emitted, "system.main.ci.failed", %{sha: sha}}
    assert sha == red.sha
    assert Agent.get(calls, & &1) == 2
  end

  test "compatibility guard: unavailable poll files nothing" do
    parent = self()
    unless Process.whereis(Aiur.TaskSupervisor), do: start_supervised!({Task.Supervisor, name: Aiur.TaskSupervisor})

    server =
      start_supervised!(
        {MainWatch,
         [
           name: nil,
           subscribe: false,
           config: %{on_red: "dispatch_fixer", fixer_label: "main-fix", workflows: [], canary_minutes: 0},
           repo: "owner/repo",
           branch: "main",
           actions_write: false,
           debounce_ms: 0,
           interval_ms: 60_000,
           load_fun: fn _, _ -> Persistence.empty() end,
           poll_fun: fn _, _, _ -> {:error, :github_unavailable} end,
           save_fun: fn _, _, data ->
             send(parent, {:saved_unavailable, data})
             :ok
           end,
           emit_fun: fn _, _ -> :ok end,
           fixer_open: fn _, _ -> flunk("unavailable poll must not reconcile fixers") end
         ]}
      )

    receive_barrier({:saved_unavailable, data})
    assert data.unavailable == true
    assert MainWatch.state(server).status == :unknown
  end

  test "merge-group-only main SHA does not dispatch a fixer" do
    parent = self()
    unless Process.whereis(Aiur.TaskSupervisor), do: start_supervised!({Task.Supervisor, name: Aiur.TaskSupervisor})

    server =
      start_supervised!(
        {MainWatch,
         [
           name: nil,
           subscribe: false,
           config: %{on_red: "dispatch_fixer", fixer_label: "main-fix", workflows: ["ci"], canary_minutes: 0},
           repo: "owner/repo",
           branch: "main",
           actions_write: false,
           debounce_ms: 0,
           interval_ms: 60_000,
           load_fun: fn _, _ -> Persistence.empty() end,
           poll_fun: fn _, _, _ -> {:ok, %{observations: [], runs: [], commits: ["landed"], merge_groups: [], actions_write: false}} end,
           save_fun: fn _, _, data ->
             send(parent, {:saved_queue_only, data})
             :ok
           end,
           emit_fun: fn topic, payload ->
             send(parent, {:emitted_queue_only, topic, payload})
             :ok
           end,
           fixer_open: fn _, _ -> flunk("queue-only SHA must not dispatch a fixer") end
         ]}
      )

    receive_barrier({:saved_queue_only, data})
    assert data.state.status == :unknown
    assert MainWatch.state(server).status == :unknown
    refute_received {:emitted_queue_only, "system.main.ci.failed", _}
  end

  defp flush_saved do
    receive do
      {:saved, _} -> flush_saved()
    after
      0 -> :ok
    end
  end
end
