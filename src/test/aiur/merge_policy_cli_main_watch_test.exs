defmodule Aiur.MergePolicyCLIMainWatchTest do
  use ExUnit.Case, async: true

  test "red status identifies the observed SHA, age, full red date and fixer" do
    time = DateTime.to_unix(~U[2026-10-09 14:02:00Z], :millisecond)
    state = %{status: :red, sha: "deadbeef", completed_at: time, red_since: time, fixer_ticket: 4100}
    assert Aiur.MergePolicyCLI.main_state(state, time + 86_400_000) == "main=red sha=deadbeef age=86400s since 2026-10-09T14:02:00.000Z (#4100)"
  end

  test "green status exposes the age of the observed completed run" do
    state = %{status: :green, sha: "abc123", completed_at: 1_000}
    assert Aiur.MergePolicyCLI.main_state(state, 181_000) == "main=green sha=abc123 age=180s"
    assert Aiur.MergePolicyCLI.main_state(Map.put(state, :event, "push"), 181_000) == "main=green (push) sha=abc123 age=180s"
    assert Aiur.MergePolicyCLI.main_state(Map.put(state, :event, "merge_group"), 181_000) == "main=green (merge_group) sha=abc123 age=180s"
  end

  test "unavailable is primary while last known color, SHA and growing age remain visible" do
    state = %{status: :green, unavailable: true, sha: "abc123", completed_at: 1_000}
    assert Aiur.MergePolicyCLI.main_state(state, 181_000) == "main=unavailable last_known=green sha=abc123 age=180s"
    assert Aiur.MergePolicyCLI.main_state(state, 241_000) == "main=unavailable last_known=green sha=abc123 age=240s"
    red = Map.merge(state, %{status: :red, red_since: 1_000})
    assert Aiur.MergePolicyCLI.main_state(red, 241_000) == "main=unavailable last_known=red sha=abc123 age=240s since 1970-01-01T00:00:01.000Z"
  end

  test "missing observation metadata stays unknown rather than showing a fresh default" do
    assert Aiur.MergePolicyCLI.main_state(%{status: :unknown}, 0) == "main=unknown"
    assert Aiur.MergePolicyCLI.main_state(%{status: :unknown, unavailable: true}, 0) == "main=unavailable last_known=unknown"
    assert Aiur.MergePolicyCLI.main_state(%{status: :green, sha: nil, completed_at: nil}, 0) == "main=green sha=unknown age=unknown"
    assert Aiur.MergePolicyCLI.main_state(%{status: :red, red_since: nil}, 0) == "main=red sha=unknown age=unknown since unknown"
  end

  test "main CI events and canary wake the Executor" do
    for topic <- ["system.main.ci.failed", "system.main.ci.failed.resolved", "system.main.ci.flaked", "system.main.ci.canary", "system.main.ci.unavailable"] do
      assert topic in Aiur.ExecutorBindings.patterns()
    end
  end
end
