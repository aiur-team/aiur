defmodule Aiur.BuildQueue.PlannerFixture do
  @moduledoc false
  alias Aiur.BuildQueue.Model.{Edge, Intent, Item, Latch, Observation, Queue}
  alias Aiur.BuildQueue.Planner.Input
  @time ~U[2026-10-08 00:00:00Z]

  def input do
    %Input{
      now_ms: 10_000,
      opts: [label_prefix: "agent", observation_max_age_ms: 1_000],
      queues: [%Queue{id: "q", name: "queue", kind: :list, root: nil, held: false, generation: 0, created_at: @time}],
      items: [item("1")],
      observations: %{"1" => observation("1")}
    }
  end

  def item(id), do: %Item{issue_id: id, queue_id: "q", position: 0, hold: nil, override: nil, promoted_at: nil, added_at: @time}
  def observation(id), do: %Observation{issue_id: id, open?: true, labels: ["agent:queued"], state_reason: nil, pr: nil, observed_at_ms: 10_000}
  def edge, do: %Edge{prerequisite: "2", dependent: "1", source: :native}
  def waiting(input), do: %{input | edges: [edge()], observations: Map.put(input.observations, "2", observation("2"))}
  def update_observation(input, changes), do: %{input | observations: Map.update!(input.observations, "1", &struct!(&1, changes))}
  def update_item(input, changes), do: %{input | items: Enum.map(input.items, &struct!(&1, changes))}

  def intent(input, action, changes \\ []) do
    record = %Intent{id: "intent", issue_id: "1", action: action, target_labels: input.observations["1"].labels, recorded_at_ms: 9_999, outcome: :ok}
    %{input | intents: [struct!(record, changes)]}
  end

  def promoted(input), do: input |> update_observation(labels: ~w(agent:queued agent:todo)) |> update_item(promoted_at: @time)

  def generator do
    StreamData.tuple(
      {StreamData.member_of([:ready, :waiting, :failed, :unknown]), StreamData.member_of([:queued, :manual, :promoted, :removed, :closed, :claimed, :external]), StreamData.boolean(),
       StreamData.boolean(), StreamData.member_of([:unavailable, :claimed, {:declined, :unauthorized}])}
    )
    |> StreamData.map(fn {verdict, labels, held, stale, claim} ->
      input = input() |> prerequisite(verdict) |> provenance(labels)
      input = %{input | claims: %{"1" => claim}}
      input = if held, do: update_item(input, hold: :operator), else: input
      if stale, do: update_observation(input, observed_at_ms: 0), else: input
    end)
  end

  def apply_actions(input, actions), do: Enum.reduce(actions, input, &apply_action/2)
  defp prerequisite(input, :ready), do: input
  defp prerequisite(input, :waiting), do: waiting(input)
  defp prerequisite(input, :unknown), do: %{input | edges: [edge()]}

  defp prerequisite(input, :failed) do
    input = waiting(input)
    %{input | observations: Map.update!(input.observations, "2", &%{&1 | labels: ["agent:error"]})}
  end

  defp provenance(input, :queued), do: input
  defp provenance(input, :manual), do: update_observation(input, labels: ~w(agent:queued agent:todo))
  defp provenance(input, :promoted), do: promoted(input)
  defp provenance(input, :removed), do: update_observation(input, labels: [])
  defp provenance(input, :closed), do: update_observation(input, open?: false, state_reason: "completed")
  defp provenance(input, :claimed), do: update_observation(input, labels: ~w(agent:queued agent:in-progress))
  defp provenance(input, :external), do: update_item(input, promoted_at: @time)
  defp apply_action({:dequeue, id}, input), do: %{input | items: Enum.reject(input.items, &(&1.issue_id == id))}
  defp apply_action({:mark_override, _id}, input), do: update_item(input, override: :manual_promotion)
  defp apply_action({:mark_external_hold, _id}, input), do: update_item(input, hold: :external)
  defp apply_action({:promote, _id}, input), do: input |> promoted() |> intent(:promote)
  defp apply_action({:withdraw, _id}, input), do: input |> update_observation(labels: ["agent:queued"]) |> update_item(promoted_at: nil) |> intent(:withdraw)

  defp apply_action({:begin_withdraw, id}, input) do
    holds = Keyword.get(input.opts, :withdrawal_holds, MapSet.new()) |> MapSet.put(id)
    %{input | opts: Keyword.put(input.opts, :withdrawal_holds, holds)}
  end

  defp apply_action({:hold_release, id}, input), do: %{input | opts: Keyword.update!(input.opts, :withdrawal_holds, &MapSet.delete(&1, id))}
  defp apply_action({:attention_open, key}, input), do: %{input | latches: [%Latch{key: key, opened_at_ms: input.now_ms, emitted?: true} | input.latches]}
  defp apply_action({:attention_resolve, key}, input), do: %{input | latches: Enum.reject(input.latches, &(&1.key == key))}
end
