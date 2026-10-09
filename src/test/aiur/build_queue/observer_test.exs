defmodule Aiur.BuildQueue.ObserverTest do
  use ExUnit.Case, async: true
  alias Aiur.BuildQueue.{Model.Edge, Observer, Readiness}
  alias Aiur.Config.Schema

  defmodule Tracker do
    def open_issue_labels(_age), do: Process.get(:snapshot)

    def issue_closure(id) do
      Process.put(:reads, [id | Process.get(:reads, [])])
      Process.get(:closure)
    end
  end

  setup do
    Process.put(:snapshot, {:ok, %{}, 1_000})
    Process.put(:closure, {:ok, %{open?: false, state_reason: "completed"}})

    {:ok,
     state: %{
       settings: %Schema{build_queue: %Schema.BuildQueue{}, polling: %Schema.Polling{}},
       tracker: Tracker,
       closure_cache: %{},
       document: %{edges: [%Edge{prerequisite: "1", dependent: "2", source: :native}]}
     }}
  end

  test "newly closed prerequisite is read once across ten reconciles beyond max age", %{state: state} do
    Enum.reduce(1..10, state, fn n, state ->
      Process.put(:snapshot, {:ok, %{}, n * 100_000})
      {observations, cache} = Observer.observe(state)
      assert verdict(observations["1"], n * 100_000) == :satisfied
      %{state | closure_cache: cache}
    end)

    assert Process.get(:reads) == ["1"]
  end

  test "closure reasons produce completed, failed and unknown verdicts", %{state: state} do
    for {reason, expected} <- [{"completed", :satisfied}, {"not_planned", {:failed, :not_planned}}, {"duplicate", {:unknown, :duplicate}}, {nil, {:unknown, :closed_reason}}] do
      Process.put(:closure, {:ok, %{open?: false, state_reason: reason}})
      {observations, _cache} = Observer.observe(state)
      assert verdict(observations["1"]) == expected
    end
  end

  test "reopen clears cache and later close reads again", %{state: state} do
    {_observations, cache} = Observer.observe(state)
    Process.put(:snapshot, {:ok, %{"1" => %{labels: ["agent:queued"]}}, 1_000})
    {observations, cache} = Observer.observe(%{state | closure_cache: cache})
    assert observations["1"].open?
    assert cache == %{}
    Process.put(:snapshot, {:ok, %{}, 1_000})
    Process.put(:closure, {:ok, %{open?: false, state_reason: "not_planned"}})
    {observations, _cache} = Observer.observe(%{state | closure_cache: cache})
    assert verdict(observations["1"]) == {:failed, :not_planned}
    assert Process.get(:reads) == ["1", "1"]
  end

  test "read errors retry and unavailable listing withholds cached evidence", %{state: state} do
    Process.put(:closure, {:error, :timeout})
    {observations, cache} = Observer.observe(state)
    assert verdict(observations["1"]) == {:unknown, :closed_reason}
    assert cache == %{}
    Process.put(:closure, {:ok, %{open?: false, state_reason: "completed"}})
    {observations, cache} = Observer.observe(%{state | closure_cache: cache})
    assert verdict(observations["1"]) == :satisfied
    assert Process.get(:reads) == ["1", "1"]
    Process.put(:snapshot, :none)
    assert {%{}, ^cache} = Observer.observe(%{state | closure_cache: cache})
  end

  test "open closure response is not terminal", %{state: state} do
    Process.put(:closure, {:ok, %{open?: true, state_reason: nil}})

    for _ <- 1..2 do
      {observations, cache} = Observer.observe(state)
      assert verdict(observations["1"]) == :pending
      assert cache == %{}
    end

    assert Process.get(:reads) == ["1", "1"]
  end

  defp verdict(observation, now \\ 1_000), do: Readiness.edge_verdict(observation, now_ms: now, max_age_ms: 100, label_prefix: "agent")
end
