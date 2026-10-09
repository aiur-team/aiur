Code.require_file("../../support/build_queue_planner_fixture.exs", __DIR__)

defmodule Aiur.BuildQueue.ObserverTest do
  use Aiur.TestSupport
  alias Aiur.BuildQueue.{PlannerFixture, Reconcile, Server}
  alias Aiur.Events.{Exchange, GithubWebhook.Deposit}
  alias Aiur.GitHub.ResourceStore
  alias Aiur.{Tracker, Workflow}

  defmodule Claims do
    def status(_ids), do: :unavailable
  end

  defmodule Snapshot do
    def open_issue_labels(_age), do: {:ok, %{"1" => %{labels: ["agent:queued"]}, "42" => %{labels: []}}, System.system_time(:millisecond)}
    def ticket_pull_request(id), do: Tracker.ticket_pull_request(id)
  end

  defmodule QueueStore do
    def load do
      input = PlannerFixture.input() |> PlannerFixture.waiting()
      document = input |> Map.from_struct() |> Map.take([:queues, :items, :edges, :intents, :latches])
      {:ok, %{document | edges: [%{PlannerFixture.edge() | prerequisite: "42"}]}}
    end

    def save(_document), do: :ok
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    ResourceStore.reset()
    on_exit(&ResourceStore.reset/0)
    owner = self()
    Exchange.subscribe("ticket.42.pr.closed_unmerged")
    on_exit(fn -> GenServer.call(Exchange, {:unsubscribe, "ticket.42.pr.closed_unmerged", owner}) end)
    {:ok, settings} = Aiur.Config.settings()
    input = PlannerFixture.input() |> PlannerFixture.waiting()
    document = input |> Map.from_struct() |> Map.take([:queues, :items, :edges, :intents, :latches])
    document = %{document | edges: [%{PlannerFixture.edge() | prerequisite: "42"}]}

    state = %{
      settings: settings,
      tracker: Snapshot,
      document: document,
      clock: fn -> System.system_time(:millisecond) end,
      holds: MapSet.new(),
      claim_probe: Claims,
      published_pr_versions: %{},
      reconciles: 0,
      intent_reconciles: %{}
    }

    {:ok, state: state}
  end

  test "closed-unmerged prerequisite fails its dependent through reconciliation", %{state: state} do
    deposit(%{})
    assert {[%{state: :failed_prerequisite, verdict: {:failed, [:pr_closed_unmerged]}}], actions, observations, _} = Reconcile.plan(state)
    assert observations["42"].pr == :closed_unmerged
    assert {:attention_open, {{:prerequisite_failed, :pr_closed_unmerged}, "42"}} in actions
    refute {:promote, "1"} in actions
  end

  test "publishes once per observed closed version and observes reopening", %{state: state} do
    deposit(%{})
    {_, _, _, state} = Reconcile.plan(state)
    assert_received {:event, %{topic: "ticket.42.pr.closed_unmerged", class: :live, refs: %{ticket: "42", pr_number: 77}}}
    {_, _, _, state} = Reconcile.plan(state)
    refute_received {:event, %{topic: "ticket.42.pr.closed_unmerged"}}
    deposit(%{"state" => "open", "updated_at" => "2026-10-08T00:01:00Z"})
    assert {[%{verdict: :waiting}], _, %{"42" => %{pr: :open}}, state} = Reconcile.plan(state)
    deposit(%{"updated_at" => "2026-10-08T00:02:00Z"})
    Reconcile.plan(state)
    assert_received {:event, %{topic: "ticket.42.pr.closed_unmerged"}}
  end

  test "no delivery stays waiting and emits nothing (future regression guard)", %{state: state} do
    assert {[%{state: :waiting, verdict: :waiting}], _, %{"42" => %{pr: nil}}, _} = Reconcile.plan(state)
    refute_received {:event, %{topic: "ticket.42.pr.closed_unmerged"}}
  end

  test "server retains published versions across reconciles", %{state: state} do
    deposit(%{})
    owner = self()
    settings = %{state.settings | build_queue: %{state.settings.build_queue | enabled: true}}

    pid =
      start_supervised!(
        {Server,
         name: nil, settings: {:ok, settings}, tracker: Snapshot, store: QueueStore, claim_probe: Claims, schedule: fn target, message, _delay -> send(owner, {:scheduled, target, message}) end}
      )

    assert_received {:scheduled, ^pid, :tick}
    assert_received {:scheduled, ^pid, initial}
    send(pid, initial)
    assert {:ok, %{projections: [%{verdict: {:failed, [:pr_closed_unmerged]}}]}} = GenServer.call(pid, :show)
    assert_received {:event, %{topic: "ticket.42.pr.closed_unmerged"}}
    assert :sys.get_state(pid).published_pr_versions == %{"42" => {77, "2026-10-08T00:00:00Z"}}
    GenServer.call(pid, :reconcile_now)
    assert_received {:scheduled, ^pid, next}
    send(pid, next)
    GenServer.call(pid, :show)
    refute_received {:event, %{topic: "ticket.42.pr.closed_unmerged"}}
  end

  test "event service outage preserves the failed verdict and retries after recovery", %{state: state} do
    deposit(%{})
    generator = Process.whereis(Aiur.Events.IdGenerator)
    Process.unregister(Aiur.Events.IdGenerator)

    try do
      assert ExUnit.CaptureLog.capture_log(fn ->
               assert {[%{verdict: {:failed, [:pr_closed_unmerged]}}], _, _, next} = Reconcile.plan(state)
               assert next.published_pr_versions == %{}
             end) =~ "was not published"

      refute_received {:event, %{topic: "ticket.42.pr.closed_unmerged"}}
    after
      Process.register(generator, Aiur.Events.IdGenerator)
    end

    Reconcile.plan(state)
    assert_received {:event, %{topic: "ticket.42.pr.closed_unmerged"}}
  end

  defp deposit(changes) do
    body = %{"number" => 77, "state" => "closed", "merged" => false, "merged_at" => nil, "updated_at" => "2026-10-08T00:00:00Z", "head" => %{"ref" => "aiur/42-pr-evidence"}}
    Deposit.deposit("pull_request", %{"action" => "closed", "pull_request" => Map.merge(body, changes)}, "owner/repo")
  end
end
