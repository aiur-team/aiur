Code.require_file("../../support/build_queue_planner_fixture.exs", __DIR__)

defmodule Aiur.BuildQueue.PRObserverTest do
  use Aiur.TestSupport
  use Aiur.TestSupport.EventTicket
  alias Aiur.BuildQueue.{PlannerFixture, Reconcile, Server}
  alias Aiur.Events.Exchange
  alias Aiur.Events.GithubWebhook.Deposit
  alias Aiur.GitHub.ResourceStore
  alias Aiur.{Tracker, Workflow}

  defmodule Claims do
    def status(_ids), do: :unavailable
  end

  defmodule Snapshot do
    def open_issue_labels(_age),
      do: {:ok, %{"1" => %{labels: ["agent:queued"]}, Application.fetch_env!(:aiur, :pr_observer_ticket) => %{labels: []}}, Application.fetch_env!(:aiur, :pr_observer_observed_at)}

    def ticket_pull_request(id), do: Tracker.ticket_pull_request(id)
  end

  defmodule QueueStore do
    def load do
      input = PlannerFixture.input() |> PlannerFixture.waiting()
      document = input |> Map.from_struct() |> Map.take([:queues, :items, :edges, :intents, :latches])
      {:ok, %{document | edges: [%{PlannerFixture.edge() | prerequisite: Application.fetch_env!(:aiur, :pr_observer_ticket)}]}}
    end

    def save(_document), do: :ok
  end

  setup do
    ticket = ticket_id()
    topic = "ticket.#{ticket}.pr.closed_unmerged"
    observed_at = System.system_time(:millisecond)
    Application.put_env(:aiur, :pr_observer_ticket, ticket)
    Application.put_env(:aiur, :pr_observer_observed_at, observed_at)

    on_exit(fn ->
      Application.delete_env(:aiur, :pr_observer_ticket)
      Application.delete_env(:aiur, :pr_observer_observed_at)
    end)

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    ResourceStore.reset()
    on_exit(&ResourceStore.reset/0)
    owner = self()
    Exchange.subscribe(topic)
    on_exit(fn -> GenServer.call(Exchange, {:unsubscribe, topic, owner}) end)
    {:ok, settings} = Aiur.Config.settings()
    input = PlannerFixture.input() |> PlannerFixture.waiting()
    document = input |> Map.from_struct() |> Map.take([:queues, :items, :edges, :intents, :latches])
    document = %{document | edges: [%{PlannerFixture.edge() | prerequisite: ticket}]}

    state = %{
      settings: settings,
      tracker: Snapshot,
      document: document,
      clock: fn -> observed_at end,
      holds: MapSet.new(),
      claim_probe: Claims,
      published_pr_versions: %{},
      reconciles: 0,
      intent_reconciles: %{}
    }

    {:ok, state: state}
  end

  test "closed-unmerged prerequisite fails its dependent through reconciliation", %{state: state} do
    ticket = ticket_id()
    deposit(%{})
    assert {[%{state: :failed_prerequisite, verdict: {:failed, [:pr_closed_unmerged]}}], actions, observations, _} = plan(state)
    assert observations[ticket].pr == :closed_unmerged
    assert {:attention_open, {{:prerequisite_failed, :pr_closed_unmerged}, ticket}} in actions
    refute {:promote, "1"} in actions
  end

  test "publishes once per observed closed version and observes reopening", %{state: state} do
    ticket = ticket_id()
    topic = "ticket.#{ticket}.pr.closed_unmerged"
    deposit(%{})
    {_, _, _, state} = plan(state)
    assert_received {:event, %{topic: ^topic, class: :live, refs: %{ticket: ^ticket, pr_number: 77}}}
    {_, _, _, state} = plan(state)
    refute_received {:event, %{topic: ^topic}}
    deposit(%{"state" => "open", "updated_at" => "2026-10-08T00:01:00Z"})
    assert {[%{verdict: :waiting}], _, %{^ticket => %{pr: :open}}, state} = plan(state)
    deposit(%{"updated_at" => "2026-10-08T00:02:00Z"})
    plan(state)
    assert_received {:event, %{topic: ^topic}}
  end

  test "no delivery stays waiting and emits nothing (future regression guard)", %{state: state} do
    ticket = ticket_id()
    topic = "ticket.#{ticket}.pr.closed_unmerged"
    assert {[%{state: :waiting, verdict: :waiting}], _, %{^ticket => %{pr: nil}}, _} = plan(state)
    refute_received {:event, %{topic: ^topic}}
  end

  test "server retains published versions across reconciles", %{state: state} do
    ticket = ticket_id()
    topic = "ticket.#{ticket}.pr.closed_unmerged"
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
    assert_received {:event, %{topic: ^topic}}
    assert :sys.get_state(pid).published_pr_versions == %{ticket => {77, "2026-10-08T00:00:00Z"}}
    GenServer.call(pid, :reconcile_now)
    assert_received {:scheduled, ^pid, next}
    send(pid, next)
    GenServer.call(pid, :show)
    refute_received {:event, %{topic: ^topic}}
  end

  test "event service outage preserves the failed verdict and retries after recovery", %{state: state} do
    ticket = ticket_id()
    topic = "ticket.#{ticket}.pr.closed_unmerged"
    deposit(%{})
    generator = Process.whereis(Aiur.Events.IdGenerator)
    Process.unregister(Aiur.Events.IdGenerator)

    try do
      assert ExUnit.CaptureLog.capture_log(fn ->
               assert {[%{verdict: {:failed, [:pr_closed_unmerged]}}], _, _, next} = plan(state)
               assert next.published_pr_versions == %{}
             end) =~ "was not published"

      refute_received {:event, %{topic: ^topic}}
    after
      Process.register(generator, Aiur.Events.IdGenerator)
    end

    plan(state)
    assert_received {:event, %{topic: ^topic}}
  end

  # Reconcile.plan/1 returns the published PR versions; carry them as the server does.
  defp plan(state) do
    {projections, actions, observations, _cache, _holds, published, _edges} = Reconcile.plan(state)
    {projections, actions, observations, %{state | published_pr_versions: published}}
  end

  defp deposit(changes) do
    body = %{
      "number" => 77,
      "state" => "closed",
      "draft" => false,
      "merged" => false,
      "merged_at" => nil,
      "updated_at" => "2026-10-08T00:00:00Z",
      "head" => %{"ref" => "aiur/#{ticket_id()}-pr-evidence", "repo" => %{"full_name" => "owner/repo"}}
    }

    Deposit.deposit("pull_request", %{"action" => "closed", "pull_request" => Map.merge(body, changes)}, "owner/repo")
    :sys.get_state(Aiur.StartTrigger.ProgressStore)
  end
end
