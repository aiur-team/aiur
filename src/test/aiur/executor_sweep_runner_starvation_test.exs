defmodule Aiur.ExecutorSweepRunnerStarvationTest do
  use ExUnit.Case, async: true

  alias Aiur.ExecutorSweep.Checks

  test "names starvation for a large queue with no running jobs" do
    now = DateTime.utc_now()
    queued = for id <- 1..11, do: group(id, "queued", now)

    assert [%{kind: "runner_starvation", queued_runs: 11, running_runs: 0}] =
             Checks.all(%{merge_groups: queued}, now)
             |> Enum.filter(&(&1.kind == "runner_starvation"))
  end

  test "keeps stale running-group findings alongside starvation" do
    now = DateTime.utc_now()
    old = DateTime.add(now, -30 * 60, :second)
    queued = for id <- 1..11, do: group(id, "queued", now)
    running = group(12, "in_progress", old)
    findings = Checks.all(%{merge_groups: queued ++ [running]}, now)

    assert Enum.any?(findings, &(&1.kind == "runner_starvation"))

    assert [%{kind: "stale_merge_group", merge_group: "run 12"}] =
             Enum.filter(findings, &(&1.kind == "stale_merge_group"))
  end

  test "does not call one old queued job starvation while runners are busy" do
    now = DateTime.utc_now()
    old = DateTime.add(now, -30 * 60, :second)
    groups = [group(13, "queued", old), group(14, "in_progress", old)]
    findings = Checks.all(%{merge_groups: groups}, now)

    refute Enum.any?(findings, &(&1.kind == "runner_starvation"))
    assert Enum.sort(Enum.map(findings, & &1.merge_group)) == ["run 13", "run 14"]
  end

  defp group(id, state, started_at),
    do: %{id: id, name: "run #{id}", state: state, started_at: started_at}
end
