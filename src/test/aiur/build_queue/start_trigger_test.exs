Code.require_file("../../support/build_queue_planner_fixture.exs", __DIR__)

defmodule Aiur.BuildQueue.StartTriggerTest do
  use ExUnit.Case, async: true
  alias Aiur.BuildQueue.{Model, Planner, PlannerFixture, ReadModel, Settings}
  alias Aiur.Config.Schema

  test "optimistic queue promotes and projections use its trigger" do
    input = input(:pr_opened, labels: ["agent:ci-wait"])
    {[projection], actions} = Planner.plan(input)
    assert projection.state == :ready
    assert {:promote, "1"} in actions
    state = %{status: :running, clock: fn -> input.now_ms end, document: Map.from_struct(input), projections: [projection], observations: input.observations, settings: settings()}
    [queue] = ReadModel.build(state).queues
    assert queue.start_trigger == :pr_opened
    assert queue.start_trigger_override == :pr_opened
    assert [%{trigger: :pr_opened, stage: :pr_opened, verdict: :satisfied}] = hd(queue.items).prerequisites
    {[waiting], actions} = Planner.plan(input(:pr_opened, labels: ["agent:in-progress"]))
    assert waiting.state == :waiting
    refute {:promote, "1"} in actions
  end

  test "default merge releases while strict queue keeps the merged-open attention" do
    input = input(nil, pr: :merged, merged_at_ms: 1)
    input = %{input | opts: Keyword.put(input.opts, :merged_open_grace_ms, 1)}
    {[ready], actions} = Planner.plan(input)
    assert ready.state == :ready
    assert {:promote, "1"} in actions
    refute {:attention_open, {:merged_issue_open, "2"}} in actions
    strict = %{input | queues: [%{hd(input.queues) | start_trigger: :issue_closed}]}
    {[waiting], actions} = Planner.plan(strict)
    assert waiting.state == :waiting
    assert {:attention_open, {:merged_issue_open, "2"}} in actions
    latch = %Model.Latch{key: {:merged_issue_open, "2"}, opened_at_ms: 1, emitted?: true}
    {_, actions} = Planner.plan(%{input | latches: [latch]})
    assert {:attention_resolve, latch.key} in actions
  end

  test "queues sharing a blocker resolve independently and tightening withdraws unclaimed work" do
    input = input(:pr_opened, labels: ["agent:ci-wait"])
    second = %{hd(input.queues) | id: "other", name: "strict", start_trigger: :pr_merged}
    member = %{PlannerFixture.item("3") | queue_id: second.id}

    input = %{
      input
      | queues: input.queues ++ [second],
        items: input.items ++ [member],
        edges: input.edges ++ [%{PlannerFixture.edge() | dependent: "3"}],
        observations: Map.put(input.observations, "3", PlannerFixture.observation("3"))
    }

    {states, actions} = Planner.plan(input)
    assert Enum.find(states, &(&1.issue_id == "1")).state == :ready
    assert Enum.find(states, &(&1.issue_id == "3")).state == :waiting
    assert {:promote, "1"} in actions
    refute {:promote, "3"} in actions
    tightened = input(:pr_merged, labels: ["agent:ci-wait"]) |> PlannerFixture.promoted()
    {_, actions} = Planner.plan(%{tightened | claims: %{"1" => :unclaimed}})
    assert {:begin_withdraw, "1"} in actions
  end

  test "config default overrides and finite validation reach queue settings" do
    assert Settings.start_trigger(settings()) == :pr_merged
    assert {:ok, configured} = Schema.parse(%{"build_queue" => %{"start_trigger" => "pr_opened"}})
    assert Settings.start_trigger(configured) == :pr_opened
    assert {:error, {:invalid_workflow_config, message}} = Schema.parse(%{"build_queue" => %{"start_trigger" => "soon"}})
    for trigger <- Aiur.StartTrigger.triggers(), do: assert(message =~ Atom.to_string(trigger))
    assert {:ok, omitted} = Schema.parse(%{"build_queue" => %{"start_trigger" => nil}})
    assert Settings.start_trigger(omitted) == :pr_merged
    input = input(nil, labels: ["agent:ci-wait"])
    {[ready], _} = Planner.plan(%{input | opts: Keyword.put(input.opts, :start_trigger, Settings.start_trigger(configured))})
    assert ready.state == :ready
  end

  test "old store documents decode while explicit triggers round-trip and invalid values fail" do
    fixture = PlannerFixture.input()
    document = Map.take(Map.from_struct(fixture), [:queues, :items, :edges, :intents, :latches])
    document = %{document | queues: [%{hd(document.queues) | id: "q-abcd"}], items: [%{hd(document.items) | queue_id: "q-abcd"}]}
    encoded = Model.encode(document)
    old = Map.update!(encoded, "queues", &Enum.map(&1, fn q -> Map.delete(q, "start_trigger") end))
    assert {:ok, decoded} = Model.decode(old)
    assert hd(decoded.queues).start_trigger == nil
    explicit = %{document | queues: [%{hd(document.queues) | start_trigger: :pr_ci_green}]}
    assert {:ok, ^explicit} = explicit |> Model.encode() |> Jason.encode!() |> Jason.decode!() |> Model.decode()
    invalid = Map.update!(encoded, "queues", &Enum.map(&1, fn q -> Map.put(q, "start_trigger", "soon") end))
    assert Model.decode(invalid) == {:error, {:invalid, ["queues", 0, "start_trigger"]}}
  end

  defp settings, do: %Schema{build_queue: %Schema.BuildQueue{}, tracker: %Schema.Tracker{}, polling: %Schema.Polling{}}

  defp input(trigger, changes) do
    input = PlannerFixture.input() |> PlannerFixture.waiting()
    %{input | queues: [%{hd(input.queues) | start_trigger: trigger}], observations: Map.update!(input.observations, "2", &struct!(&1, changes))}
  end
end
