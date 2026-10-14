defmodule Aiur.MainWatch.StateTest do
  use ExUnit.Case, async: true
  alias Aiur.CI.FailureDigest
  alias Aiur.MainWatch.State

  test "new failure carries tests, last green and suspect early merges" do
    {state, []} = observe(State.new(), "green", 1, "success")
    observation = observation("red", 2, "failure") |> Map.put(:suspect_merges, [%{pr: 42, early: true}])
    {state, [{"system.main.ci.failed", payload}]} = State.observe(state, observation, 2)
    assert state.status == :red
    assert state.red_since == 2
    assert payload.last_green_sha == "green"
    assert payload.failing_checks == [%{name: "test", conclusion: "failure"}]
    assert payload.failing_tests == [%{identity: "ExampleTest :: broken", classification: :new_failure}]
    assert payload.suspect_merges == [%{pr: 42, early: true}]
    assert payload.run_urls == ["https://github.example/runs/red"]
  end

  test "same signature across SHAs and serialized restart does not emit again" do
    {state, [_]} = observe(State.new(), "a", 1, "failure")
    state = state |> :erlang.term_to_binary() |> :erlang.binary_to_term([:safe])
    {state, []} = observe(state, "b", 2, "failure")
    assert state.sha == "b"
    assert state.red_since == 1
    changed = observation("c", 3, "failure") |> Map.update!(:digest, &%{&1 | signature: "new"})
    assert {_, [{"system.main.ci.failed", %{sha: "c"}}]} = State.observe(state, changed, 3)
  end

  test "known flakes emit informational event while unknown or truncated evidence stays red" do
    known = %FailureDigest{signature: "known", flake_only: true, tests: [%{identity: "flaky", classification: :known_flake}]}
    observation = %{observation("a", 1, "failure") | digest: known}
    assert {_, [{"system.main.ci.flaked", %{failing_tests: [%{classification: :known_flake}]}}]} = State.observe(State.new(), observation, 1)

    for digest <- [%{known | tests: :unknown}, %{known | truncated: true}] do
      assert {state, [{"system.main.ci.failed", _}]} = State.observe(State.new(), %{observation | digest: digest}, 1)
      assert state.status == :red
    end
  end

  test "recovery emits once and pending or cancelled runs cannot replace completed state" do
    {state, [_]} = observe(State.new(), "a", 1, "failure")
    {state, [{"system.main.ci.failed.resolved", %{sha: "b"}}]} = observe(state, "b", 2, "success")
    assert state.last_green_sha == "b"
    assert state.red_since == nil
    {state, []} = observe(state, "b", 2, "success")
    for conclusion <- [nil, "cancelled"], do: assert({^state, []} = observe(state, "c", 3, conclusion))
  end

  test "history does not emit old red before newest completed green" do
    state = State.record_history(State.new(), observation("a", 1, "failure"), 3)
    assert state.status == :unknown
    assert state.emitted_signatures == []
    {state, []} = observe(state, "b", 2, "success")
    assert state.status == :green
    assert Enum.map(state.history, & &1.sha) == ["a", "b"]
  end

  test "inherited evidence needs failure before base and first later pass after it" do
    {state, []} = observe(State.new(), "before", 1, "success")
    {state, [_]} = observe(state, "failed", 2, "failure")
    {state, [_]} = observe(state, "fixed", 4, "success")
    {state, []} = observe(state, "after", 5, "success")
    assert State.inherited?(state, "test", "failed") == :inherited
    assert State.inherited?(state, "test", "before") == :not_inherited
    assert State.inherited?(state, "test", "fixed") == :not_inherited
    assert State.inherited?(state, "test", "after") == :not_inherited
    assert State.inherited?(state, "test", "absent") == :unknown
    assert State.inherited?(state, "lint", "failed") == :unknown
    assert State.inherited?(state, "test", "pending", ~w(after fixed pending failed before)) == :inherited
  end

  test "seven-day expiry removes inherited evidence" do
    {state, [_]} = observe(State.new(), "a", 1, "failure")
    {state, [_]} = observe(state, "b", 2, "success")
    now = 7 * 24 * 60 * 60 * 1_000 + 3
    {state, []} = State.observe(state, observation("c", now, "success"), now)
    assert Enum.map(state.history, & &1.sha) == ["c"]
    assert State.inherited?(state, "test", "a") == :unknown
    assert {_, [{"system.main.ci.failed", _}]} = observe(state, "again", now + 1, "failure")
  end

  test "fail-fast cancelled children of completed failed workflow still emit failure" do
    observation = observation("fail-fast", 1, "failure")
    observation = Map.merge(observation, %{checks: observation.checks ++ [%{name: "cancelled partition", conclusion: "cancelled"}], failed_workflow: true})
    assert {state, [{"system.main.ci.failed", payload}]} = State.observe(State.new(), observation, 1)
    assert state.status == :red
    assert payload.failing_checks == [%{name: "test", conclusion: "failure"}, %{name: "cancelled partition", conclusion: "cancelled"}]
    assert payload.failing_tests == [%{identity: "ExampleTest :: broken", classification: :new_failure}]
  end

  defp observe(state, sha, at, conclusion), do: State.observe(state, observation(sha, at, conclusion), at)

  defp observation(sha, at, conclusion) do
    %{
      sha: sha,
      completed_at: at,
      checks: [%{name: "test", conclusion: conclusion}],
      digest: %FailureDigest{signature: "broken", tests: [%{identity: "ExampleTest :: broken", classification: :new_failure}]},
      run_urls: ["https://github.example/runs/" <> sha],
      suspect_merges: []
    }
  end
end
