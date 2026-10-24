defmodule Aiur.MainWatchRunnerStarvationTest do
  use Aiur.TestSupport

  alias Aiur.MainWatch
  alias Aiur.MainWatch.Persistence

  test "state reports runner starvation from the last-known normalized queue during an outage" do
    parent = self()
    now = DateTime.utc_now()
    now_ms = DateTime.to_unix(now, :millisecond)
    queued = for id <- 1..11, do: %{id: id, name: "run #{id}", status: "queued", started_at: now}
    data = %{Persistence.empty() | merge_groups: queued, unavailable: true}

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

    assert %{unavailable: true, runner_starvation: diagnosis} = MainWatch.state(server)
    assert diagnosis.queued_runs == 11
    assert diagnosis.running_runs == 0
    assert diagnosis.status_url == "https://www.githubstatus.com/#components"

    send(worker, :finish)
  end
end
