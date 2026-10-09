defmodule Aiur.BuildQueue.ProgressTest do
  use ExUnit.Case, async: false
  alias Aiur.BuildProgress
  alias Aiur.BuildQueue.{Model, Progress, Server}
  alias Aiur.Config.Schema

  defmodule Boundary do
    def open_issue_labels(_age), do: {:ok, %{"1" => %{labels: ["agent:queued", "agent:in-progress"]}}, 1_000}

    def load do
      queue = %Model.Queue{id: "q-progress", name: "Progress", kind: :list, root: nil, held: false, generation: 0, created_at: ~U[2026-10-08 00:00:00Z]}
      item = %Model.Item{issue_id: "1", queue_id: queue.id, position: 0, hold: nil, override: nil, promoted_at: nil, added_at: queue.created_at}
      {:ok, %{queues: [queue], items: [item], edges: [], intents: [], latches: []}}
    end

    def blocked_by(_), do: {:ok, []}
    def status(_), do: :unavailable
    def save(_), do: :ok
  end

  setup do
    path = Path.join(Aiur.TestSupport.tmp_root!("queue-progress"), "progress.json")
    start_supervised!({BuildProgress, state_file: path})
    %{path: path}
  end

  test "2 of 3 completed floors progress to 66" do
    assert Progress.summary(items([:completed, :completed, :ready])) == %{completed: 2, resolved: 3, total: 3, percent: 66, resolution: :resolved}
  end

  test "removed items leave the denominator and cancelled items remain" do
    assert Progress.summary(items([:completed, :completed, :removed])).percent == 100
    assert Progress.summary(items([:completed, :cancelled])).percent == 50
  end

  test "empty and all-removed queues produce no fact" do
    assert Progress.fact(queue(), [], source()) == nil
    assert Progress.fact(queue(), items([:removed]), source()) == nil
  end

  test "Build Order queues produce no queue fact" do
    assert Progress.fact(%{queue() | kind: :build_order}, items([:completed]), source()) == nil
  end

  test "partial and unresolved lifecycles preserve uncertainty" do
    assert Progress.summary(items([:completed, :unknown])) == %{completed: 1, resolved: 1, total: 2, percent: 50, resolution: :partial}
    assert Progress.summary(items([:unknown])) == %{completed: nil, resolved: 0, total: 1, percent: nil, resolution: :unresolved}
  end

  test "facts preserve queue generation and stale source evidence" do
    fact = Progress.fact(queue(), items([:completed, :unknown]), %{source() | freshness: :stale})
    assert fact == %{scope: {:queue, "q-progress"}, generation: 0, completed: 1, resolved: 1, total: 2, percent: 50, resolution: :partial, freshness: :stale, observed_at: source().observed_at}
    assert :ok = BuildProgress.put_fact(fact)
    assert BuildProgress.facts(fact.scope) == [fact]
  end

  test "generation zero milestone latches survive restart", %{path: path} do
    fact = Progress.fact(queue(), items([:completed]), source())
    assert :ok = BuildProgress.put_fact(fact)
    assert :ok = stop_supervised(BuildProgress)
    pid = start_supervised!({BuildProgress, state_file: path})
    assert :sys.get_state(pid).latches == %{Jason.encode!([:queue, "q-progress", 0]) => 100}
  end

  test "absent BuildProgress skips publication and reports unknown" do
    assert :ok = stop_supervised(BuildProgress)
    assert Progress.summary(items([:completed])) == %{completed: nil, resolved: nil, total: nil, percent: nil, resolution: :unknown}
    assert Progress.publish(%{}) == :ok
  end

  test "real server reconciliation publishes the same progress as the read model" do
    owner = self()
    clock = start_supervised!({Agent, fn -> 1_000 end})
    settings = %Schema{build_queue: %Schema.BuildQueue{enabled: true}, tracker: %Schema.Tracker{}, polling: %Schema.Polling{}}

    pid =
      start_supervised!(
        {Server,
         name: nil,
         settings: {:ok, settings},
         tracker: Boundary,
         store: Boundary,
         claim_probe: Boundary,
         clock: fn -> Agent.get(clock, & &1) end,
         exchange: :absent_progress_exchange,
         schedule: fn _, message, _ ->
           send(owner, message)
           make_ref()
         end}
      )

    assert_received {:reconcile, _} = message
    send(pid, message)
    model = GenServer.call(pid, :read_model)
    assert [%{progress: progress}] = model.queues
    assert [%{scope: {:queue, "q-progress"}, generation: 0, percent: 0, freshness: :current} = fact] = BuildProgress.facts({:queue, "q-progress"})
    assert Map.take(fact, Map.keys(progress)) == progress
    assert fact.observed_at == DateTime.from_unix!(1_000, :millisecond)

    Agent.update(clock, fn _ -> 200_000 end)
    send(pid, :tick)
    GenServer.call(pid, :status)
    assert_received {:reconcile, _} = next
    send(pid, next)
    stale_model = GenServer.call(pid, :read_model)
    assert [%{progress: stale_progress}] = stale_model.queues
    assert [%{percent: nil, freshness: :unknown, resolution: :unresolved} = unavailable] = BuildProgress.facts({:queue, "q-progress"})
    assert Map.take(unavailable, Map.keys(stale_progress)) == stale_progress
  end

  defp items(states), do: Enum.map(states, &%{state: &1})
  defp queue, do: %{id: "q-progress", kind: :list, generation: 0}
  defp source, do: %{freshness: :current, observed_at: ~U[2026-10-08 00:00:00Z]}
end
