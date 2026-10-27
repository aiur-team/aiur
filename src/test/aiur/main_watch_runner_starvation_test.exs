defmodule Aiur.MainWatchRunnerStarvationTest do
  use Aiur.TestSupport

  alias Aiur.MainWatch
  alias Aiur.MainWatch.Persistence

  test "state reports runner starvation from the last-known normalized queue during an outage" do
    now = DateTime.utc_now()
    now_ms = DateTime.to_unix(now, :millisecond)
    queued = for id <- 1..11, do: %{id: id, name: "run #{id}", status: "queued", started_at: now}
    server = start_watch(queued, now_ms, unavailable: true)

    assert %{unavailable: true, runner_starvation: diagnosis} = MainWatch.state(server)
    assert diagnosis.queued_runs == 11
    assert diagnosis.running_runs == 0
    assert diagnosis.status_url == "https://www.githubstatus.com/#components"
  end

  test "one old queued run with active runners is not runner starvation" do
    now = DateTime.utc_now()
    now_ms = DateTime.to_unix(now, :millisecond)
    old = DateTime.add(now, -16 * 60, :second)
    groups = [%{id: 1, name: "queued", status: "queued", started_at: old}] ++ running_groups(2, now)

    server = start_watch(groups, now_ms)

    assert %{runner_starvation: nil} = MainWatch.state(server)
  end

  test "one old queued run with no runners is runner starvation" do
    now = DateTime.utc_now()
    now_ms = DateTime.to_unix(now, :millisecond)
    old = DateTime.add(now, -16 * 60, :second)

    server = start_watch([%{id: 1, name: "queued", status: "queued", started_at: old}], now_ms)

    assert %{runner_starvation: %{queued_runs: 1, running_runs: 0}} = MainWatch.state(server)
  end

  defp running_groups(count, now) do
    for id <- 1..count, do: %{id: id + 1, name: "running #{id}", status: "in_progress", started_at: now}
  end

  defp start_watch(groups, now_ms, extra \\ []) do
    parent = self()
    data = %{Persistence.empty() | merge_groups: groups, unavailable: Keyword.get(extra, :unavailable, false)}

    server =
      start_supervised!(
        {MainWatch,
         [
           name: nil,
           subscribe: false,
           config: %{on_red: "none", fixer_label: "", workflows: [], canary_minutes: 0},
           repo: "owner/repo",
           branch: "main",
           interval_ms: 60_000,
           now_fun: fn -> now_ms end,
           load_fun: fn _, _ -> data end,
           poll_fun: fn _, _, _ ->
             send(parent, {:polling, self()})

             receive do
               :finish -> {:error, :test_finished}
             end
           end,
           save_fun: fn _, _, _ -> :ok end,
           emit_fun: fn _, _ -> :ok end
         ]}
      )

    assert_receive {:polling, worker}, 1_000
    send(worker, :finish)
    server
  end
end
