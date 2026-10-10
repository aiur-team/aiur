defmodule Aiur.BuildQueue.RefreshTest do
  use Aiur.TestSupport
  alias Aiur.BuildQueue.{Model, Server, Settings}
  alias Aiur.Config.Schema
  alias Aiur.GitHub.{Issues, OpenIssueSnapshot}

  defmodule Boundary do
    def open_issue_labels(_age), do: Agent.get(__MODULE__, & &1.snapshot)
    def load, do: Agent.get(__MODULE__, & &1.document)
    def status(_ids), do: :unavailable
    def blocked_by(_id), do: {:ok, []}
    def save(document), do: Agent.update(__MODULE__, &%{&1 | document: {:ok, document}})
    def update_issue_state(id, "todo", expected_state: :none), do: Agent.update(__MODULE__, &%{&1 | promoted: &1.promoted ++ [id]})
    def notify_demand(_ids), do: :ok

    # Stands in for the remote listing: it renews the snapshot only when the tracker is reachable.
    def refresh_open_issue_labels do
      state = Agent.get_and_update(__MODULE__, &{&1, %{&1 | refreshes: &1.refreshes + 1, snapshot: if(&1.reachable, do: {:ok, &1.listing, &1.now}, else: &1.snapshot)}})
      if state.reachable, do: Phoenix.PubSub.broadcast(Aiur.PubSub, "tracker:open_issues", {:open_issues_recorded, state.now})
      send(state.test, :refresh_requested)
      if state.reachable, do: :ok, else: {:error, :offline}
    end
  end

  setup do
    queue = %Model.Queue{id: "q", name: "Q", kind: :list, root: nil, held: false, generation: 0, created_at: ~U[2026-10-08 00:00:00Z]}
    item = %Model.Item{issue_id: "1", queue_id: "q", position: nil, hold: nil, override: nil, promoted_at: nil, added_at: queue.created_at}

    boundary = %{
      test: self(),
      now: 1_000,
      snapshot: :none,
      reachable: false,
      refreshes: 0,
      promoted: [],
      listing: %{"1" => %{labels: ["agent:queued"], updated_at: nil}},
      document: {:ok, %{queues: [queue], items: [item], edges: [], intents: [], latches: []}}
    }

    pid = start_supervised!({Agent, fn -> boundary end})
    Process.register(pid, Boundary)
    %{max_age: Settings.observation_max_age_ms(settings())}
  end

  # Host-saturation reproduction (#3946): the dispatch poll never lists, as in the 2026-10-09 stall.
  # Covered: the daemon still schedules the queue server. Not covered: a host that cannot schedule
  # the daemon, or an unreachable tracker; the first refresh below fails and freshness stays unknown.
  test "a stale non-empty queue requests one listing per observation age and plans from it", %{max_age: max_age} do
    pid = server()
    reconcile(pid)
    assert :sys.get_state(pid).refresh_not_before_ms == 1_000 + max_age
    assert Agent.get(Boundary, & &1.refreshes) == 0

    advance(max_age)
    reconcile(pid)
    receive_barrier(:refresh_requested)
    assert {:ok, %{freshness: :unknown}} = GenServer.call(pid, :show)

    advance(max_age - 1)
    reconcile(pid)
    assert :sys.get_state(pid).refresh_not_before_ms == 1_000 + 2 * max_age

    Agent.update(Boundary, &%{&1 | reachable: true})
    advance(1)
    reconcile(pid)
    receive_barrier(:refresh_requested)
    assert Agent.get(Boundary, & &1.refreshes) == 2

    # The recorded listing wakes the queue through the same signal the dispatch poll publishes.
    receive_barrier({:scheduled, ^pid, message, 2_000})
    send(pid, message)
    assert {:ok, %{freshness: :fresh}} = GenServer.call(pid, :show)
    assert Agent.get(Boundary, & &1.promoted) == ["1"]
  end

  test "an empty queue never requests a listing", %{max_age: max_age} do
    Agent.update(Boundary, &%{&1 | document: {:ok, %{queues: [], items: [], edges: [], intents: [], latches: []}}})
    pid = server()
    reconcile(pid)
    advance(2 * max_age)
    reconcile(pid)
    assert :sys.get_state(pid).refresh_not_before_ms == nil
    assert Agent.get(Boundary, & &1.refreshes) == 0
  end

  test "the listing-only refresh records dispatchable issues without authorizing them" do
    token_key = {Aiur.GitHub.Config, :resolved_token}
    previous = {System.get_env("GITHUB_TOKEN"), :persistent_term.get(token_key, :unset)}
    :persistent_term.erase(token_key)
    System.put_env("GITHUB_TOKEN", "test-gh-token")
    OpenIssueSnapshot.reset()

    on_exit(fn ->
      {env, cached} = previous
      restore_env("GITHUB_TOKEN", env)
      if cached == :unset, do: :persistent_term.erase(token_key), else: :persistent_term.put(token_key, cached)
      OpenIssueSnapshot.reset()
    end)

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo", tracker_label_prefix: "sym", tracker_active_states: ["todo"])
    parent = self()
    issue = %{"number" => 7, "title" => "Queued", "body" => nil, "html_url" => "https://github.com/owner/repo/issues/7", "labels" => [%{"name" => "sym:todo"}], "assignee" => nil}

    request_fun = fn request ->
      send(parent, {:request, request.url})
      {:ok, %{status: 200, headers: [], body: [issue]}}
    end

    # The same listing through the candidate path spends an authorization read; the refresh must not.
    assert {:ok, [%{id: "7"}]} = Issues.fetch_candidate_issues(request_fun: request_fun)
    assert length(drain_requests()) > 1

    OpenIssueSnapshot.reset()
    assert Issues.refresh_open_issues(request_fun: request_fun) == :ok
    assert drain_requests() == ["https://api.github.com/repos/owner/repo/issues?state=open&per_page=100"]
    assert {:ok, %{"7" => %{labels: ["sym:todo"]}}, _} = OpenIssueSnapshot.fetch_labels("owner", "repo", 60_000)
  end

  defp drain_requests do
    receive do
      {:request, url} -> [url | drain_requests()]
    after
      0 -> []
    end
  end

  defp settings, do: %Schema{build_queue: %Schema.BuildQueue{enabled: true}, tracker: %Schema.Tracker{}, polling: %Schema.Polling{}}
  defp advance(ms), do: Agent.update(Boundary, &%{&1 | now: &1.now + ms})

  defp server do
    owner = self()

    pid =
      start_supervised!(
        {Server,
         name: nil,
         settings: {:ok, settings()},
         tracker: Boundary,
         store: Boundary,
         claim_probe: Boundary,
         clock: fn -> Agent.get(Boundary, & &1.now) end,
         exchange: :absent_queue_exchange,
         schedule: fn pid, message, delay ->
           send(owner, {:scheduled, pid, message, delay})
           make_ref()
         end}
      )

    assert_received {:scheduled, ^pid, :tick, 60_000}
    pid
  end

  # Runs the pending debounced reconcile, requesting one first when none is pending.
  defp reconcile(pid) do
    assert :ok = GenServer.call(pid, :reconcile_now)
    receive_barrier({:scheduled, ^pid, message, 2_000})
    send(pid, message)
    assert GenServer.call(pid, :status) == :running
  end
end
