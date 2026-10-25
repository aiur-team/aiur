defmodule Aiur.GitHub.RunnerStarvationTest do
  use ExUnit.Case, async: true

  alias Aiur.GitHub.RunnerStarvation

  test "does not call one old queued run starvation while runners are busy" do
    now = DateTime.utc_now()
    now_ms = DateTime.to_unix(now, :millisecond)
    queued = %{status: "queued", started_at: DateTime.add(now, -16, :minute)}
    running = for id <- 1..2, do: %{id: id, status: "in_progress", started_at: now}

    assert RunnerStarvation.diagnose([queued | running], now_ms, 15) == nil
  end

  test "calls one old queued run starvation when no runners are available" do
    now = DateTime.utc_now()
    now_ms = DateTime.to_unix(now, :millisecond)
    queued = %{status: "queued", started_at: DateTime.add(now, -16, :minute)}

    assert %{queued_runs: 1, running_runs: 0, age_ms: 960_000, status_url: url} =
             RunnerStarvation.diagnose([queued], now_ms, 15)

    assert url == "https://www.githubstatus.com/#components"
  end

  test "calls a large queue starvation even before the age threshold" do
    now = DateTime.utc_now()
    now_ms = DateTime.to_unix(now, :millisecond)
    queued = for id <- 1..11, do: %{id: id, status: "queued", started_at: now}

    assert %{queued_runs: 11, running_runs: 0, age_ms: 0} =
             RunnerStarvation.diagnose(queued, now_ms, 15)
  end
end
