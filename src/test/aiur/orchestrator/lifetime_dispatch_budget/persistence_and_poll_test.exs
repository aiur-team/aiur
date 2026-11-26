Code.require_file("fixture.ex", __DIR__)

defmodule Aiur.Orchestrator.LifetimeDispatchBudget.PersistenceAndPollTest do
  use Aiur.LifetimeDispatchBudgetCase, async: false
  import Aiur.TestSupport, only: [receive_barrier: 1]
  import Aiur.LifetimeDispatchBudgetCase, only: [run: 2, thrash_budget: 1, with_thrash_budget: 2, dispatch_n: 2]

  alias Aiur.AlertFeed
  alias Aiur.Config
  alias Aiur.DispatchBudgetStore
  alias Aiur.Issue
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.Dispatcher
  alias Aiur.Orchestrator.Dispatcher.BudgetTrip
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.TrackerTasks

  defmodule LifetimeLatchGitHubClient do
    def add_label(identifier, label) do
      send(Process.get(:lifetime_latch_test_parent), {:add_label, identifier, label})
      Process.put(:lifetime_latch_test_labels, Enum.uniq([label | Process.get(:lifetime_latch_test_labels, [])]))
      :ok
    end

    def remove_label(identifier, label) do
      send(Process.get(:lifetime_latch_test_parent), {:remove_label, identifier, label})
      Process.put(:lifetime_latch_test_labels, List.delete(Process.get(:lifetime_latch_test_labels, []), label))
      :ok
    end

    def update_issue_state(identifier, "needs-triage", _opts) do
      send(Process.get(:lifetime_latch_test_parent), {:state_transition, identifier, "needs-triage"})
      labels = Process.get(:lifetime_latch_test_labels, [])
      labels = ["agent:needs-triage" | Enum.reject(labels, &String.starts_with?(&1, "agent:"))]
      Process.put(:lifetime_latch_test_labels, Enum.uniq(labels))
      :ok
    end

    def fetch_open_pull_requests_for_branch(identifier) do
      send(Process.get(:lifetime_latch_test_parent), {:open_prs, identifier})
      {:ok, [%{"number" => 3001, "html_url" => "https://github.test/pull/3001"}]}
    end

    def fetch_classified_issue_comments(identifier) do
      send(Process.get(:lifetime_latch_test_parent), {:read_latch_comments, identifier})
      {:ok, Process.get(:lifetime_latch_test_comments, [])}
    end

    def create_comment(identifier, body) do
      send(Process.get(:lifetime_latch_test_parent), {:latch_comment, identifier, body})
      Process.put(:lifetime_latch_test_comments, [%{"body" => body} | Process.get(:lifetime_latch_test_comments, [])])
      :ok
    end
  end

  @issue_id "issue-lifetime"
  @window_ms 60 * 1_000

  @enabled """
  tracker:
    kind: memory
    active_states:
      - todo
      - in-progress
      - rework
  agent:
    kind: codex
    max_dispatches_per_ticket: 10
  """

  @github_enabled """
  tracker:
    kind: github
    active_states:
      - todo
      - in-progress
      - rework
    github:
      repo: owner/repo
  agent:
    kind: codex
    max_dispatches_per_ticket: 10
  """

  @tag config: @github_enabled
  test "a lifetime trip is durably moved to needs-triage exactly once" do
    previous_client = Application.get_env(:aiur, :github_client_module)
    previous_parent = Process.get(:lifetime_latch_test_parent)
    previous_comments = Process.get(:lifetime_latch_test_comments)
    Process.put(:lifetime_latch_test_parent, self())
    Process.put(:lifetime_latch_test_comments, [])
    Application.put_env(:aiur, :github_client_module, LifetimeLatchGitHubClient)

    on_exit(fn ->
      if previous_client, do: Application.put_env(:aiur, :github_client_module, previous_client), else: Application.delete_env(:aiur, :github_client_module)
      if previous_parent, do: Process.put(:lifetime_latch_test_parent, previous_parent), else: Process.delete(:lifetime_latch_test_parent)
      if previous_comments, do: Process.put(:lifetime_latch_test_comments, previous_comments), else: Process.delete(:lifetime_latch_test_comments)
    end)

    issue = %Issue{id: @issue_id, identifier: "repo#lifetime"}
    state = dispatch_n(%Orchestrator.State{}, 10)
    assert {:trip, state} = run(state, 11 * (@window_ms + 1))
    parent = self()

    state =
      Dispatcher.persist_lifetime_trip(state, issue, fn identifier, target_state ->
        send(parent, {:durable_latch, identifier, target_state})
        :ok
      end)

    assert_receive {:durable_latch, "repo#lifetime", "needs-triage"}, 1000
    assert_receive {:open_prs, "repo#lifetime"}, 1000
    assert_receive {:read_latch_comments, "repo#lifetime"}, 1000
    assert_receive {:latch_comment, "repo#lifetime", comment}, 1000
    assert comment =~ "10/10 lifetime dispatches"
    assert comment =~ "#3001 (https://github.test/pull/3001)"
    assert comment =~ "aiur-lifetime-latch:repo#lifetime:10"
    assert thrash_budget(state)[@issue_id].durable_latch_applied == true

    assert Dispatcher.persist_lifetime_trip(state, issue, fn _, _ ->
             flunk("durable latch must not be applied twice")
           end) == state

    refute_received {:durable_latch, "repo#lifetime", "needs-triage"}
    refute_received {:latch_comment, "repo#lifetime", _body}
  end

  @tag config: @github_enabled
  test "a lifetime latch leaves the bare needs-triage marker and no agent state label" do
    previous_client = Application.get_env(:aiur, :github_client_module)
    Process.put(:lifetime_latch_test_parent, self())
    Process.put(:lifetime_latch_test_labels, ["agent:in-progress"])
    Application.put_env(:aiur, :github_client_module, LifetimeLatchGitHubClient)

    on_exit(fn ->
      if previous_client, do: Application.put_env(:aiur, :github_client_module, previous_client), else: Application.delete_env(:aiur, :github_client_module)
    end)

    issue = %Issue{id: @issue_id, identifier: "repo#lifetime-labels", state: "in-progress"}
    state = dispatch_n(%Orchestrator.State{}, 10)
    assert {:trip, state} = run(state, 11 * (@window_ms + 1))

    BudgetTrip.trip_thrash_breaker(state, issue)

    assert_receive {:add_label, "repo#lifetime-labels", "needs-triage"}, 1000
    assert_receive {:state_transition, "repo#lifetime-labels", "needs-triage"}, 1000
    assert_receive {:remove_label, "repo#lifetime-labels", "agent:needs-triage"}, 1000

    labels = Process.get(:lifetime_latch_test_labels)
    assert labels == ["needs-triage"]
    refute Enum.any?(labels, &String.starts_with?(&1, "agent:"))
  end

  @tag config: @enabled
  test "async lifetime writes retain current alert fields and ignore a reset budget" do
    issue = %Issue{id: @issue_id, identifier: "repo#async-lifetime"}
    state = dispatch_n(%Orchestrator.State{snapshot_key: self()}, 10)
    assert {:trip, state} = run(state, 11 * (@window_ms + 1))
    parent = self()

    write = fn _, _ ->
      send(parent, {:latch_writer, self()})
      receive do: (:release -> :ok)
    end

    pending = Dispatcher.persist_lifetime_trip(state, issue, write)
    receive_barrier({:latch_writer, worker})
    send(worker, :release)
    receive_barrier({ref, result})
    current = update_in(pending.dispatch_recovery.codex_thrash_budget[@issue_id], &Map.put(&1, :alert_emitted, true))
    {:handled, next} = TrackerTasks.result(current, ref, result)
    assert thrash_budget(next)[@issue_id].durable_latch_applied
    assert thrash_budget(next)[@issue_id].alert_emitted

    pending = Dispatcher.persist_lifetime_trip(state, issue, write)
    receive_barrier({:latch_writer, worker})
    send(worker, :release)
    receive_barrier({ref, result})
    reset = with_thrash_budget(pending, %{@issue_id => %{lifetime: 0}})
    {:handled, next} = TrackerTasks.result(reset, ref, result)
    assert thrash_budget(next)[@issue_id] == %{lifetime: 0}
  end

  @tag config: @enabled
  test "the lifetime latch attention reaches the central alert feed" do
    # Keep the informational latch event durable and visible centrally.
    issue = %Issue{id: @issue_id, identifier: "repo#lifetime-central"}
    state = dispatch_n(%Orchestrator.State{}, 10)
    assert {:trip, state} = run(state, 11 * (@window_ms + 1))

    # Alerts only route to a workspace log when that workspace directory
    # exists, which is true for any ticket that has run. Create it so this
    # exercises the production routing rather than the no-workspace fallback.
    workspace = Aiur.Workspace.workspace_path_under(Config.workspace_root(), issue.identifier)
    File.mkdir_p!(workspace)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace) end)

    Dispatcher.persist_lifetime_trip(state, issue, fn _identifier, _target_state -> :ok end)

    topic = "ticket.repo#lifetime-central.agent.attention.error-lifetime_latch"

    alert = Enum.find(AlertFeed.list(roots: []), &(&1["topic"] == topic))
    assert alert["needs_attention"] == false
    assert alert["severity"] == "info"
  end

  # One poll cycle as the orchestrator runs it: consult dispatch eligibility, and
  # only when it admits do the gate + commit that bill a lifetime unit. Both
  # halves are the production functions (`should_dispatch_issue?/2` is the poll
  # loop's per-issue gate in `Dispatcher.choose_issues/2`;
  # `record_dispatch_committed/2` is the sole lifetime billing point), so removing
  # the #1759 guard makes this helper bill and the assertions below fail.
  defp poll_cycle(state, %Issue{} = issue, cycle) do
    if DispatchPolicy.should_dispatch_issue?(issue, state) do
      {:ok, gated} = Dispatcher.check_thrash_budget(state, issue.id, cycle * (@window_ms + 1))
      Dispatcher.record_dispatch_committed(gated, issue.id)
    else
      state
    end
  end

  defp parked_issue(id, state_name) do
    %Issue{id: id, identifier: "repo##{id}", title: "Approved and queued", state: state_name}
  end

  @tag config: """
       tracker:
         kind: memory
         active_states:
           - todo
           - in-progress
           - rework
           - merging
           - ci-wait
       agent:
         kind: codex
         max_dispatches_per_ticket: 10
       """
  test "a merging or ci-wait ticket holds a steady lifetime count across poll cycles" do
    # #1759 acceptance: #1573 sat in `agent:merging` with PR #1607 approved and in
    # the merge queue and still burned 48 lifetime dispatches in ~50 minutes,
    # latching a ticket whose work was already finished and approved. The config
    # above reproduces that operator config — `merging` listed as an active state.
    for {id, state_name} <- [{"issue-merging", "merging"}, {"issue-ci-wait", "ci-wait"}] do
      issue = parked_issue(id, state_name)
      state = %Orchestrator.State{max_concurrent_agents: 5, last_polled_issues: %{id => issue}}

      assert {:ok, 0} = DispatchBudgetStore.lifetime(id)

      state =
        Enum.reduce(1..4, state, fn cycle, acc ->
          acc = poll_cycle(acc, issue, cycle)
          assert {:ok, 0} = DispatchBudgetStore.lifetime(id)
          acc
        end)

      # Four poll cycles later the ticket is still nowhere near the latch, and no
      # in-memory lifetime was accrued either.
      assert {:ok, 0} = DispatchBudgetStore.lifetime(id)
      assert :none = Dispatcher.dispatch_latch_status(state, id)
      refute Map.has_key?(thrash_budget(state), id)
    end

    # Control: an otherwise identical ticket in a real work state does bill, so
    # the steady counts above are the guard doing its job and not a harness that
    # never bills anything.
    working = parked_issue("issue-rework", "rework")
    working_state = %Orchestrator.State{max_concurrent_agents: 5, last_polled_issues: %{"issue-rework" => working}}

    working_state = Enum.reduce(1..4, working_state, &poll_cycle(&2, working, &1))

    assert {:ok, 4} = DispatchBudgetStore.lifetime("issue-rework")
    assert %{lifetime: 4} = thrash_budget(working_state)["issue-rework"]
  end

  @tag config: """
       tracker:
         kind: memory
       agent:
         kind: codex
       """
  test "unset budget disables the latch (default is a no-op)" do
    state = dispatch_n(%Orchestrator.State{}, 30)

    assert {:ok, _state} = run(state, 31 * (@window_ms + 1))
    assert :none = Dispatcher.dispatch_latch_status(state, @issue_id)
  end
end
