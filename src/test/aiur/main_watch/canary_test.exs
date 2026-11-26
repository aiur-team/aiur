defmodule Aiur.MainWatch.CanaryTest do
  use ExUnit.Case, async: true
  alias Aiur.MainWatch.Canary

  test "stale canary reruns newest cancelled run or requests attention" do
    runs = [%{id: 3, status: "completed", conclusion: "success", attempt: 1}, %{id: 2, status: "completed", conclusion: "cancelled", attempt: 1}]
    assert {:rerun, 2} = Canary.decide(0, runs, 45, true, 46 * 60_000)
    assert {:attention, :actions_write_unavailable} = Canary.decide(0, runs, 45, false, 46 * 60_000)
    assert :noop = Canary.decide(0, [], 45, true, 46 * 60_000)
  end

  test "idle green latest commit ignores older cancelled runs even without write permission" do
    runs = [
      %{id: 3, sha: "latest", status: "completed", conclusion: "success", attempt: 1},
      %{id: 2, sha: "older", status: "completed", conclusion: "cancelled", attempt: 1}
    ]

    assert :noop = Canary.decide(0, runs, 45, true, 46 * 60_000, "latest")
    assert :noop = Canary.decide(0, runs, 45, false, 46 * 60_000, "latest")
  end

  test "completed latest workflow suppresses a cancelled sibling workflow" do
    runs = [
      %{id: 3, sha: "latest", status: "completed", conclusion: "success", attempt: 1},
      %{id: 2, sha: "latest", status: "completed", conclusion: "cancelled", attempt: 1}
    ]

    assert :noop = Canary.decide(0, runs, 45, true, 46 * 60_000, "latest")
    assert :noop = Canary.decide(0, runs, 45, false, 46 * 60_000, "latest")
  end

  test "queued or running first attempts suppress the canary" do
    cancelled = %{id: 2, sha: "latest", status: "completed", conclusion: "cancelled", attempt: 1}

    for status <- ["queued", "in_progress"] do
      active = %{id: 3, sha: "latest", status: status, conclusion: nil, attempt: 1}
      assert :noop = Canary.decide(0, [active, cancelled], 45, true, 46 * 60_000, "latest")
    end
  end

  test "no cancelled candidate is quiet without write permission" do
    assert :noop = Canary.decide(0, [], 45, false, 46 * 60_000)
    runs = [%{id: 2, sha: "older", status: "completed", conclusion: "cancelled", attempt: 1}]
    assert :noop = Canary.decide(0, runs, 45, false, 46 * 60_000, "latest")
  end

  test "cancelled latest commit remains eligible" do
    runs = [%{id: 2, sha: "latest", status: "completed", conclusion: "cancelled", attempt: 1}]
    assert {:rerun, 2} = Canary.decide(0, runs, 45, true, 46 * 60_000, "latest")
    assert {:attention, :actions_write_unavailable} = Canary.decide(0, runs, 45, false, 46 * 60_000, "latest")
  end

  test "disabled, fresh and active rerun canaries do nothing" do
    runs = [%{id: 2, status: "in_progress", conclusion: nil, attempt: 2}]
    assert :noop = Canary.decide(0, [], 0, true, 46 * 60_000)
    assert :noop = Canary.decide(0, [], 45, true, 44 * 60_000)
    assert :noop = Canary.decide(0, runs, 45, true, 46 * 60_000)
  end
end
