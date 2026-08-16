defmodule Aiur.ExtensionsTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Aiur.Linear.Tracker, as: LinearTracker
  alias Aiur.Memory.Tracker, as: Memory
  alias Aiur.Orchestrator.SnapshotStore
  alias AiurWeb.OperatorControlCenter.UnitsPresenter

  @endpoint AiurWeb.Endpoint

  defmodule FakeLinearClient do
    def fetch_candidate_issues do
      send(self(), :fetch_candidate_issues_called)
      {:ok, [:candidate]}
    end

    def fetch_issues_by_states(states), do: fetch_issues_by_states(states, [])

    def fetch_issues_by_states(states, _opts) do
      send(self(), {:fetch_issues_by_states_called, states})
      {:ok, states}
    end

    def fetch_issue_states_by_ids(issue_ids) do
      send(self(), {:fetch_issue_states_by_ids_called, issue_ids})
      {:ok, issue_ids}
    end

    def graphql(query, variables) do
      send(self(), {:graphql_called, query, variables})

      case Process.get({__MODULE__, :graphql_results}) do
        [result | rest] ->
          Process.put({__MODULE__, :graphql_results}, rest)
          result

        _ ->
          Process.get({__MODULE__, :graphql_result})
      end
    end
  end

  defmodule SlowOrchestrator do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, :ok, opts)
    end

    def init(:ok), do: {:ok, :ok}

    def handle_call(:snapshot, _from, state) do
      Process.sleep(25)
      {:reply, %{}, state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, :unavailable, state}
    end
  end

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts) do
      :ok = SnapshotStore.publish(Keyword.fetch!(opts, :name), Keyword.fetch!(opts, :snapshot))
      {:ok, opts}
    end

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end

    def handle_call({:send_operator_message, issue_identifier, _payload}, _from, state) do
      reply =
        Keyword.get(state, :send_operator_message, {:ok, 1})
        |> case do
          fun when is_function(fun, 1) -> fun.(issue_identifier)
          other -> other
        end

      {:reply, reply, state}
    end
  end

  defmodule StaticDecisionStore do
    use GenServer

    alias Aiur.DecisionStore.RetainedSnapshot

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :decisions), name: name)
    end

    def init(decisions), do: {:ok, decisions}

    def handle_call({:get, decision_id}, _from, decisions) do
      case Enum.find(decisions, &(&1.decision_id == decision_id)) do
        nil -> {:reply, {:error, :not_found}, decisions}
        decision -> {:reply, {:ok, decision}, decisions}
      end
    end

    def handle_call({:retained_lookup, decision_id}, _from, decisions) do
      decision = Enum.find(decisions, &(&1.decision_id == decision_id))
      {:reply, {:ok, %{decision: decision, health: :writable}}, decisions}
    end

    def handle_call({:retained_query, query}, _from, decisions) do
      current = Map.new(decisions, &{&1.decision_id, &1})
      index = RetainedSnapshot.build_index(current)

      {:reply, RetainedSnapshot.query(current, index, :writable, query), decisions}
    end

    def handle_call(:retained_counts, _from, decisions) do
      current = Map.new(decisions, &{&1.decision_id, &1})
      index = RetainedSnapshot.build_index(current)
      {:reply, RetainedSnapshot.counts(index, :writable), decisions}
    end

    def handle_call(:list, _from, decisions), do: {:reply, decisions, decisions}
    def handle_call(:health, _from, decisions), do: {:reply, :writable, decisions}
    def handle_call({:recent_decisions, limit}, _from, decisions), do: {:reply, Enum.take(decisions, limit), decisions}

    def handle_call({:recent_audit_history, _limit}, _from, decisions) do
      {:reply, %{records: [], contexts: %{}, revisions: %{}}, decisions}
    end

    def handle_call(:all_audit_history, _from, decisions), do: {:reply, %{}, decisions}
  end

  defmodule StaticPayloadProvider do
    use GenServer

    def start_link(responses), do: GenServer.start_link(__MODULE__, Map.new(responses))
    def init(responses), do: {:ok, responses}

    def handle_call(request, _from, responses) do
      {:reply, Map.fetch!(responses, request), responses}
    end
  end

  setup do
    linear_client_module = Application.get_env(:aiur, :linear_client_module)

    on_exit(fn ->
      if is_nil(linear_client_module) do
        Application.delete_env(:aiur, :linear_client_module)
      else
        Application.put_env(:aiur, :linear_client_module, linear_client_module)
      end
    end)

    :ok
  end

  setup do
    endpoint_config = Application.get_env(:aiur, AiurWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:aiur, AiurWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "workflow store reloads changes, keeps last good workflow, and falls back when stopped" do
    ensure_workflow_store_running()
    # This test terminates the shared WorkflowStore singleton mid-body; restore
    # it in on_exit so a mid-test failure can't leak a down store to the next
    # sequential module (the #780 WorkspaceAndConfigTest flake).
    on_exit(fn -> ensure_workflow_store_running() end)
    assert {:ok, %{prompt: "You are an agent for this repository."}} = Workflow.current()
    assert :ok = WorkflowStore.subscribe()
    first_generation = :sys.get_state(WorkflowStore).generation

    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Second prompt")
    send(WorkflowStore, :poll)

    assert_receive {:workflow_config_updated, generation}
    assert generation > first_generation

    assert_eventually(fn ->
      match?({:ok, %{prompt: "Second prompt"}}, Workflow.current())
    end)

    assert {:ok, %{prompt: "Second prompt"}, ^generation} =
             WorkflowStore.current_with_generation()

    File.write!(Workflow.workflow_file_path(), "tracker: [\n")
    assert {:error, _reason} = WorkflowStore.force_reload()
    assert {:ok, %{prompt: "Second prompt"}} = Workflow.current()

    third_workflow = Path.join(Path.dirname(Workflow.workflow_file_path()), "thirdconfig.yaml")
    write_workflow_file!(third_workflow, prompt: "Third prompt")
    Workflow.set_workflow_file_path(third_workflow)
    assert {:ok, %{prompt: "Third prompt"}} = Workflow.current()

    assert :ok = Supervisor.terminate_child(Aiur.Supervisor, WorkflowStore)
    assert {:ok, %{prompt: "Third prompt"}} = WorkflowStore.current()
    assert {:ok, %{prompt: "Third prompt"}, :unknown} = WorkflowStore.current_with_generation()
    assert :ok = WorkflowStore.force_reload()
    assert :ok = ensure_workflow_store_running()
  end

  # Since #1731 a read never enters the store's mailbox, so there is no longer a
  # "read in flight when the store dies" window to trace. The guarantee that
  # test protected — a reader must get the config, not an exit — is now covered
  # by the two properties below: a suspended store does not block a read at all,
  # and a store that has gone away leaves no cache behind to serve.
  test "a suspended store does not block a read" do
    ensure_workflow_store_running()
    store = Process.whereis(WorkflowStore)

    on_exit(fn ->
      if Process.alive?(store), do: :sys.resume(store)
      ensure_workflow_store_running()
    end)

    :sys.suspend(store)

    reader = Task.Supervisor.async_nolink(Aiur.TaskSupervisor, fn -> WorkflowStore.current() end)

    assert {:ok, %{prompt: "You are an agent for this repository."}} = Task.await(reader, 1_000)
    assert {:message_queue_len, 0} = Process.info(store, :message_queue_len)
  end

  test "workflow store falls back to the file when it has shut down" do
    ensure_workflow_store_running()
    on_exit(fn -> ensure_workflow_store_running() end)

    assert :ok = Supervisor.terminate_child(Aiur.Supervisor, WorkflowStore)
    refute Process.whereis(WorkflowStore)

    assert {:ok, %{prompt: "You are an agent for this repository."}} = WorkflowStore.current()
    assert {:ok, %{}, :unknown} = WorkflowStore.current_with_generation()
  end

  test "workflow store retries a transient parse failure during a config write" do
    ensure_workflow_store_running()
    path = Workflow.workflow_file_path()
    valid_config = File.read!(path)

    File.write!(path, "tracker: [\n")

    writer =
      Task.async(fn ->
        Process.sleep(75)
        File.write!(path, valid_config)
      end)

    assert :ok = WorkflowStore.force_reload()
    assert :ok = Task.await(writer)
  end

  test "workflow store reloads when only the prompt_file body changes" do
    ensure_workflow_store_running()
    original_path = Workflow.workflow_file_path()

    config_path = Path.join(Path.dirname(original_path), "prompt_reloadconfig.yaml")
    write_workflow_file!(config_path, prompt: "Original prompt body")
    Workflow.set_workflow_file_path(config_path)

    assert {:ok, %{prompt: "Original prompt body"}} = Workflow.current()

    # Edit only the referenced prompt_file; the config.yaml bytes are untouched.
    prompt_basename = String.trim_leading(Path.basename(config_path), ".") <> ".prompt.md"
    File.write!(Path.join(Path.dirname(config_path), prompt_basename), "Edited prompt body\n")
    send(WorkflowStore, :poll)

    assert_eventually(fn ->
      match?({:ok, %{prompt: "Edited prompt body"}}, Workflow.current())
    end)

    Workflow.set_workflow_file_path(original_path)
    WorkflowStore.force_reload()
  end

  test "workflow store init stops on missing workflow file" do
    missing_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "missingconfig.yaml")
    Workflow.set_workflow_file_path(missing_path)

    assert {:stop, {:missing_workflow_file, ^missing_path, :enoent}} = WorkflowStore.init([])
  end

  test "workflow store start_link and poll callback cover missing-file error paths" do
    ensure_workflow_store_running()
    # Terminates the shared WorkflowStore mid-body; restore it in on_exit so a
    # mid-test failure can't leak a down store to a later sequential module.
    on_exit(fn -> ensure_workflow_store_running() end)
    existing_path = Workflow.workflow_file_path()
    manual_path = Path.join(Path.dirname(existing_path), "manualconfig.yaml")
    missing_path = Path.join(Path.dirname(existing_path), "manual-missingconfig.yaml")

    assert :ok = Supervisor.terminate_child(Aiur.Supervisor, WorkflowStore)

    Workflow.set_workflow_file_path(missing_path)

    assert {:error, {:missing_workflow_file, ^missing_path, :enoent}} =
             WorkflowStore.force_reload()

    write_workflow_file!(manual_path, prompt: "Manual workflow prompt")
    Workflow.set_workflow_file_path(manual_path)

    assert {:ok, manual_pid} = WorkflowStore.start_link()
    assert Process.alive?(manual_pid)

    state = :sys.get_state(manual_pid)
    File.write!(manual_path, "tracker: [\n")
    assert {:noreply, returned_state} = WorkflowStore.handle_info(:poll, state)
    assert returned_state.workflow.prompt == "Manual workflow prompt"
    refute returned_state.stamp == nil
    assert_receive :poll, 5_000

    Workflow.set_workflow_file_path(missing_path)
    assert {:noreply, path_error_state} = WorkflowStore.handle_info(:poll, returned_state)
    assert path_error_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 5_000

    Workflow.set_workflow_file_path(manual_path)
    File.rm!(manual_path)
    assert {:noreply, removed_state} = WorkflowStore.handle_info(:poll, path_error_state)
    assert removed_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 5_000

    :ok = GenServer.stop(manual_pid)
    refute Process.alive?(manual_pid)

    Workflow.set_workflow_file_path(existing_path)

    assert :ok = ensure_workflow_store_running()
    restarted_pid = Process.whereis(WorkflowStore)
    assert Process.alive?(restarted_pid)

    WorkflowStore.force_reload()
  end

  test "tracker delegates to memory and linear adapters" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "In Progress"}
    Application.put_env(:aiur, :memory_tracker_issues, [issue, %{id: "ignored"}])
    Application.put_env(:aiur, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    assert Config.settings!().tracker.kind == "memory"
    assert Aiur.Tracker.adapter() == Memory
    assert Memory.project_identity() == "memory"
    assert Memory.default_prompt_template() =~ "You are working on an issue."
    assert {:ok, [^issue]} = Aiur.Tracker.fetch_candidate_issues()
    assert {:ok, [^issue]} = Aiur.Tracker.fetch_issues_by_states([" in progress ", 42])
    assert {:ok, [^issue]} = Aiur.Tracker.fetch_issue_states_by_ids(["issue-1"])
    assert :ok = Aiur.Tracker.create_comment("issue-1", "comment")
    assert :ok = Aiur.Tracker.update_issue_state("issue-1", "Done")
    assert_receive {:memory_tracker_comment, "issue-1", "comment"}
    assert_receive {:memory_tracker_state_update, "issue-1", "Done"}

    Application.delete_env(:aiur, :memory_tracker_recipient)
    assert :ok = Memory.create_comment("issue-1", "quiet")
    assert :ok = Memory.update_issue_state("issue-1", "Quiet")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    assert Aiur.Tracker.adapter() == LinearTracker
  end

  test "linear adapter delegates reads and validates mutation responses" do
    Application.put_env(:aiur, :linear_client_module, FakeLinearClient)

    assert {:ok, [:candidate]} = LinearTracker.fetch_candidate_issues()
    assert_receive :fetch_candidate_issues_called

    assert {:ok, ["Todo"]} = LinearTracker.fetch_issues_by_states(["Todo"])
    assert_receive {:fetch_issues_by_states_called, ["Todo"]}

    assert {:ok, ["issue-1"]} = LinearTracker.fetch_issue_states_by_ids(["issue-1"])
    assert_receive {:fetch_issue_states_by_ids_called, ["issue-1"]}

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
    )

    assert :ok = LinearTracker.create_comment("issue-1", "hello")
    assert_receive {:graphql_called, create_comment_query, %{body: "hello", issueId: "issue-1"}}
    assert create_comment_query =~ "commentCreate"

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => false}}}}
    )

    assert {:error, :comment_create_failed} =
             LinearTracker.create_comment("issue-1", "broken")

    Process.put({FakeLinearClient, :graphql_result}, {:error, :boom})

    assert {:error, :boom} = LinearTracker.create_comment("issue-1", "boom")

    Process.put({FakeLinearClient, :graphql_result}, {:ok, %{"data" => %{}}})
    assert {:error, :comment_create_failed} = LinearTracker.create_comment("issue-1", "weird")

    Process.put({FakeLinearClient, :graphql_result}, :unexpected)
    assert {:error, :comment_create_failed} = LinearTracker.create_comment("issue-1", "odd")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      ]
    )

    assert :ok = LinearTracker.update_issue_state("issue-1", "Done")
    assert_receive {:graphql_called, state_lookup_query, %{issueId: "issue-1", stateName: "Done"}}
    assert state_lookup_query =~ "states"

    assert_receive {:graphql_called, update_issue_query, %{issueId: "issue-1", stateId: "state-1"}}

    assert update_issue_query =~ "issueUpdate"

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => false}}}}
      ]
    )

    assert {:error, :issue_update_failed} =
             LinearTracker.update_issue_state("issue-1", "Broken")

    Process.put({FakeLinearClient, :graphql_results}, [{:error, :boom}])

    assert {:error, :boom} = LinearTracker.update_issue_state("issue-1", "Boom")

    Process.put({FakeLinearClient, :graphql_results}, [{:ok, %{"data" => %{}}}])
    assert {:error, :state_not_found} = LinearTracker.update_issue_state("issue-1", "Missing")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{}}}
      ]
    )

    assert {:error, :issue_update_failed} = LinearTracker.update_issue_state("issue-1", "Weird")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        :unexpected
      ]
    )

    assert {:error, :issue_update_failed} = LinearTracker.update_issue_state("issue-1", "Odd")
  end

  test "phoenix observability api preserves state, issue, and refresh responses" do
    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :ObservabilityApiOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll", "reconcile"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    conn = get(build_conn(), "/api/v1/state")
    state_payload = json_response(conn, 200)
    assert_occ_sections(state_payload)

    assert without_occ_sections(state_payload) == %{
             "generated_at" => state_payload["generated_at"],
             "counts" => %{"running" => 1, "retrying" => 1, "idle" => 0},
             "running" => [
               %{
                 "issue_id" => "issue-http",
                 "issue_identifier" => "MT-HTTP",
                 "state" => "In Progress",
                 "tag" => nil,
                 "title" => nil,
                 "url" => nil,
                 "worker_host" => nil,
                 "workspace_path" => nil,
                 "session_id" => "thread-http",
                 "turn_count" => 7,
                 "runtime_seconds" => 0,
                 "work_state" => "working",
                 "pause_reason" => nil,
                 "tracker_paused" => false,
                 "last_event" => "notification",
                 "last_message" => "rendered",
                 "live_conversation" => nil,
                 "queue_depth" => 1,
                 "capabilities" => %{
                   "accepts_operator_messages" => true,
                   "can_interrupt" => false,
                   "accepted_delivery_policies" => ["checkpoint"],
                   "safe_checkpoints" => ["notification", "tool_result"],
                   "queue_depth" => 1
                 },
                 "started_at" => state_payload["running"] |> List.first() |> Map.fetch!("started_at"),
                 "last_event_at" => nil,
                 "stale_for_seconds" => nil,
                 "waiting_reason" => "active",
                 "open_decision_count" => 0,
                 "open_decision_count_health" => "unknown",
                 "ci" => nil,
                 "review" => "not_started"
               }
             ],
             "retrying" => [
               %{
                 "issue_id" => "issue-retry",
                 "issue_identifier" => "MT-RETRY",
                 "attempt" => 2,
                 "due_at" => state_payload["retrying"] |> List.first() |> Map.fetch!("due_at"),
                 "error" => "boom",
                 "worker_host" => nil,
                 "workspace_path" => nil,
                 "state" => nil,
                 "tag" => nil,
                 "title" => nil,
                 "url" => nil,
                 "runtime_seconds" => 0,
                 "work_state" => "retrying",
                 "tracker_paused" => false,
                 "waiting_reason" => "backing_off",
                 "open_decision_count" => 0,
                 "open_decision_count_health" => "unknown",
                 "ci" => nil,
                 "review" => "not_started"
               }
             ],
             "idle" => [],
             "agent_totals" => %{"seconds_running" => 42.5},
             # The global pause switch rides along on every state payload so
             # API consumers can tell a quiet fleet from a held one.
             "globally_paused" => false
           }

    conn = get(build_conn(), "/api/v1/MT-HTTP")
    issue_payload = json_response(conn, 200)

    assert issue_payload == %{
             "issue_identifier" => "MT-HTTP",
             "issue_id" => "issue-http",
             "status" => "running",
             "workspace" => %{
               "path" => Path.join(Config.settings!().workspace.root, "MT-HTTP"),
               "host" => nil
             },
             "attempts" => %{"restart_count" => 0, "current_retry_attempt" => 0},
             "running" => %{
               "worker_host" => nil,
               "workspace_path" => nil,
               "session_id" => "thread-http",
               "turn_count" => 7,
               "state" => "In Progress",
               "queue_depth" => 1,
               "capabilities" => %{
                 "accepts_operator_messages" => true,
                 "can_interrupt" => false,
                 "accepted_delivery_policies" => ["checkpoint"],
                 "safe_checkpoints" => ["notification", "tool_result"],
                 "queue_depth" => 1
               },
               "started_at" => issue_payload["running"]["started_at"],
               "last_event" => "notification",
               "last_message" => "rendered",
               "live_conversation" => nil,
               "last_event_at" => nil,
               "stale_for_seconds" => nil,
               "waiting_reason" => "active",
               "open_decision_count" => 0,
               "open_decision_count_health" => "unknown",
               "ci" => nil,
               "review" => "not_started"
             },
             "retry" => nil,
             "capabilities" => %{
               "accepts_operator_messages" => true,
               "can_interrupt" => false,
               "accepted_delivery_policies" => ["checkpoint"],
               "safe_checkpoints" => ["notification", "tool_result"],
               "queue_depth" => 1
             },
             "queue" => %{"depth" => 1},
             "logs" => %{"codex_session_logs" => []},
             "recent_events" => [],
             "last_error" => nil,
             "tracked" => %{}
           }

    conn = get(build_conn(), "/api/v1/MT-RETRY")

    assert %{"status" => "retrying", "retry" => %{"attempt" => 2, "error" => "boom"}} =
             json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/MT-MISSING")

    assert json_response(conn, 404) == %{
             "error" => %{"code" => "issue_not_found", "message" => "Issue not found"}
           }

    conn =
      build_conn()
      |> Plug.Conn.put_req_header("origin", "http://127.0.0.1")
      |> Plug.Conn.put_req_header("x-aiur-request", "1")
      |> post("/api/v1/refresh", %{})

    assert %{"queued" => true, "coalesced" => false, "operations" => ["poll", "reconcile"]} =
             json_response(conn, 202)

    conn =
      build_conn()
      |> Plug.Conn.put_req_header("origin", "http://127.0.0.1")
      |> Plug.Conn.put_req_header("x-aiur-request", "1")
      |> post("/api/v1/MT-HTTP/messages", %{"text" => "hello"})

    assert json_response(conn, 202) == %{"issue_identifier" => "MT-HTTP", "request_id" => 1}
  end

  test "observability issue details include tracker-active idle rows" do
    snapshot = %{
      static_snapshot()
      | running: [],
        retrying: [],
        idle: [
          %{
            issue_id: "issue-idle",
            identifier: "MT-IDLE",
            state: "human-review",
            tag: "agent:human-review",
            title: "Awaiting review",
            url: "https://example.test/issues/idle",
            queue_depth: 2,
            waiting_reason: :waiting_for_review,
            open_decision_count: 1,
            ci_result: %{decision: :passed, pr_number: 1014, head_sha: "abc123"}
          }
        ]
    }

    orchestrator_name = Module.concat(__MODULE__, :IdleObservabilityApiOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    assert %{"counts" => %{"idle" => 1}} =
             json_response(get(build_conn(), "/api/v1/state"), 200)

    assert %{
             "status" => "idle",
             "issue_id" => "issue-idle",
             "queue" => %{"depth" => 2},
             "idle" => %{
               "waiting_reason" => "waiting_for_review",
               "open_decision_count" => 1,
               "review" => "awaiting",
               "ci" => %{"decision" => "passed", "pr_number" => 1014, "head_sha" => "abc123"}
             }
           } = json_response(get(build_conn(), "/api/v1/MT-IDLE"), 200)
  end

  test "observability API preserves tracker identity in status and issue snapshots" do
    identity = %Aiur.TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: "owner",
      repository: "repo",
      provider_id: "I_kwDOHTTP",
      identifier: "MT-HTTP"
    }

    snapshot =
      update_in(static_snapshot(), [:running], fn [running] ->
        [Map.put(running, :tracker_identity, identity)]
      end)

    orchestrator_name = Module.concat(__MODULE__, :TrackerIdentityObservabilityApiOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    assert %{
             "running" => [
               %{
                 "tracker_identity" => %{
                   "version" => 1,
                   "status" => "joinable",
                   "kind" => "github",
                   "owner" => "owner",
                   "repository" => "repo",
                   "provider_id" => "I_kwDOHTTP",
                   "identifier" => "MT-HTTP"
                 }
               }
             ]
           } = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert %{
             "tracker_identity" => %{"provider_id" => "I_kwDOHTTP"},
             "running" => %{"tracker_identity" => %{"provider_id" => "I_kwDOHTTP"}}
           } = json_response(get(build_conn(), "/api/v1/MT-HTTP"), 200)
  end

  test "observability API rejects ambiguous identifier snapshots before exposing nested identity" do
    first_identity = %Aiur.TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: "owner",
      repository: "repo-one",
      provider_id: "I_kwDOFirst",
      identifier: "42"
    }

    second_identity = %{first_identity | repository: "repo-two", provider_id: "I_kwDOSecond"}

    snapshot =
      update_in(static_snapshot(), [:running], fn [running] ->
        first = Map.merge(running, %{identifier: "42", tracker_identity: first_identity})

        second =
          Map.merge(running, %{
            issue_id: "issue-http-second",
            identifier: "42",
            session_id: "thread-http-second",
            workspace_path: "/workspace/repo-two/42",
            tracker_identity: second_identity
          })

        [first, second]
      end)

    orchestrator_name = Module.concat(__MODULE__, :AmbiguousIdentityObservabilityApiOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    assert json_response(get(build_conn(), "/api/v1/42"), 404) == %{
             "error" => %{"code" => "issue_not_found", "message" => "Issue not found"}
           }
  end

  test "read-only dashboard blocks agent-write endpoints but keeps reads working" do
    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :ReadOnlyOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll", "reconcile"]
        }
      )

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50,
      dashboard_writable: false
    )

    # Reads still work.
    assert %{"counts" => _} = json_response(get(build_conn(), "/api/v1/state"), 200)

    # Agent-write endpoints are gated read-only (after the CSRF bypass headers,
    # so we're proving the read-only gate, not the same-origin gate).
    refresh_conn =
      build_conn()
      |> Plug.Conn.put_req_header("origin", "http://127.0.0.1")
      |> Plug.Conn.put_req_header("x-aiur-request", "1")
      |> post("/api/v1/refresh", %{})

    assert json_response(refresh_conn, 403) == %{"error" => "dashboard is read-only"}

    messages_conn =
      build_conn()
      |> Plug.Conn.put_req_header("origin", "http://127.0.0.1")
      |> Plug.Conn.put_req_header("x-aiur-request", "1")
      |> post("/api/v1/MT-HTTP/messages", %{"text" => "hello"})

    assert json_response(messages_conn, 403) == %{"error" => "dashboard is read-only"}
  end

  test "read-only dashboard keeps the machine-to-machine claude-hook working" do
    start_test_endpoint(
      orchestrator: Module.concat(__MODULE__, :ClaudeHookOrchestrator),
      snapshot_timeout_ms: 5,
      dashboard_writable: false
    )

    hook_conn =
      build_conn()
      |> Plug.Conn.put_req_header("origin", "http://127.0.0.1")
      |> Plug.Conn.put_req_header("x-aiur-request", "1")
      |> post("/api/v1/MT-RO/claude-hook", %{"hook_event_name" => "Stop"})

    assert json_response(hook_conn, 200) == %{"ok" => true}
  end

  test "phoenix observability api preserves 405, 404, and unavailable behavior" do
    unavailable_orchestrator = Module.concat(__MODULE__, :UnavailableOrchestrator)
    start_test_endpoint(orchestrator: unavailable_orchestrator, snapshot_timeout_ms: 5)

    assert json_response(post(build_conn(), "/api/v1/state", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    # CSRF gates on the write scope mean GET-on-write-route hits the CSRF gate
    # before reaching the method_not_allowed handler — that's correct defense.
    # Add the bypass headers so we see the underlying 405.
    refresh_get =
      build_conn()
      |> Plug.Conn.put_req_header("origin", "http://127.0.0.1")
      |> Plug.Conn.put_req_header("x-aiur-request", "1")
      |> get("/api/v1/refresh")

    assert json_response(refresh_get, 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/api/v1/MT-1", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/unknown"), 404) ==
             %{"error" => %{"code" => "not_found", "message" => "Route not found"}}

    state_payload = json_response(get(build_conn(), "/api/v1/state"), 200)
    assert_occ_sections(state_payload)

    assert without_occ_sections(state_payload) ==
             %{
               "generated_at" => state_payload["generated_at"],
               "error" => %{"code" => "snapshot_unavailable", "message" => "Snapshot unavailable"}
             }

    refresh_conn =
      build_conn()
      |> Plug.Conn.put_req_header("origin", "http://127.0.0.1")
      |> Plug.Conn.put_req_header("x-aiur-request", "1")
      |> post("/api/v1/refresh", %{})

    assert json_response(refresh_conn, 503) ==
             %{
               "error" => %{
                 "code" => "orchestrator_unavailable",
                 "message" => "Orchestrator is unavailable"
               }
             }

    messages_get =
      build_conn()
      |> Plug.Conn.put_req_header("origin", "http://127.0.0.1")
      |> Plug.Conn.put_req_header("x-aiur-request", "1")
      |> get("/api/v1/MT-1/messages")

    assert json_response(messages_get, 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}
  end

  test "phoenix observability api preserves snapshot timeout behavior" do
    timeout_orchestrator = Module.concat(__MODULE__, :TimeoutOrchestrator)
    {:ok, _pid} = SlowOrchestrator.start_link(name: timeout_orchestrator)
    start_test_endpoint(orchestrator: timeout_orchestrator, snapshot_timeout_ms: 1)

    timeout_payload = json_response(get(build_conn(), "/api/v1/state"), 200)
    assert_occ_sections(timeout_payload)

    assert without_occ_sections(timeout_payload) ==
             %{
               "generated_at" => timeout_payload["generated_at"],
               "error" => %{"code" => "snapshot_timeout", "message" => "Snapshot timed out"}
             }
  end

  test "dashboard bootstraps liveview from embedded static assets" do
    orchestrator_name = Module.concat(__MODULE__, :AssetOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    html = html_response(get(build_conn(), "/"), 200)
    assert html =~ "/dashboard.css"
    assert html =~ "/ticket-context-dialog-hook.js"
    assert html =~ "/conversation-drawer-hook.js"
    assert html =~ "/time-brush-hook.js"
    assert html =~ "/aiur-dom-svg-layout-loader.js"
    assert html =~ "/vendor/phoenix_html/phoenix_html.js"
    assert html =~ "/vendor/phoenix/phoenix.js"
    assert html =~ "/vendor/phoenix_live_view/phoenix_live_view.js"
    refute html =~ "/assets/app.js"
    refute html =~ "<style>"

    dashboard_css_conn = get(build_conn(), "/dashboard.css")
    dashboard_css = response(dashboard_css_conn, 200)
    assert dashboard_css =~ ":root {"
    refute dashboard_css =~ ".status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-offline"
    assert dashboard_css =~ ".dashboard-shell[data-nav-collapsed=\"true\"] .shell-nav-sidebar"
    # Collapsing hides the route list, not the whole sidebar: the `<aside>` stays
    # as a bare rail so the control that reopens the nav is still on screen.
    assert dashboard_css =~ ".dashboard-shell[data-nav-collapsed=\"true\"] .shell-nav-toggle"
    assert dashboard_css =~ ".live-button[data-live=\"false\"]"
    assert Plug.Conn.get_resp_header(dashboard_css_conn, "cache-control") == ["private, max-age=0, must-revalidate"]

    provider_assets =
      Aiur.CodingAgent.provider_descriptors()
      |> Enum.flat_map(&[&1.logo, &1.token_icon])
      |> Enum.map(&String.replace_prefix(&1, "/provider-assets/", ""))
      |> Enum.uniq()
      |> Enum.sort()

    assert provider_assets == AiurWeb.StaticAssets.provider_asset_paths()

    for provider_asset <- provider_assets do
      provider_asset_conn = get(build_conn(), "/provider-assets/#{provider_asset}")
      assert response(provider_asset_conn, 200) =~ "<svg"
      assert Plug.Conn.get_resp_header(provider_asset_conn, "cache-control") == ["private, max-age=0, must-revalidate"]
    end

    dialog_hook_conn = get(build_conn(), "/ticket-context-dialog-hook.js")
    assert response(dialog_hook_conn, 200) =~ "AiurTicketContextDialogHook"
    assert Plug.Conn.get_resp_header(dialog_hook_conn, "cache-control") == ["private, max-age=0, must-revalidate"]

    conversation_drawer_hook_conn = get(build_conn(), "/conversation-drawer-hook.js")
    assert response(conversation_drawer_hook_conn, 200) =~ "AiurConversationDrawerHook"
    assert Plug.Conn.get_resp_header(conversation_drawer_hook_conn, "content-type") == ["text/javascript"]

    time_brush_hook_conn = get(build_conn(), "/time-brush-hook.js")
    assert response(time_brush_hook_conn, 200) =~ "AiurTimeBrushHook"
    assert Plug.Conn.get_resp_header(time_brush_hook_conn, "cache-control") == ["private, max-age=0, must-revalidate"]

    for hook <- ["build-order-grid-hook.js", "streamdeck-emulator-hook.js"] do
      hook_conn = get(build_conn(), "/#{hook}")
      assert response(hook_conn, 200) != ""
      assert Plug.Conn.get_resp_header(hook_conn, "cache-control") == ["private, max-age=0, must-revalidate"]
    end

    adapter_conn = get(build_conn(), "/aiur-dom-svg-layout-adapter.js")
    adapter = response(adapter_conn, 200)
    assert adapter =~ "createDomSvgLayoutHook"
    assert Plug.Conn.get_resp_header(adapter_conn, "cache-control") == ["private, max-age=0, must-revalidate"]

    for module <- ["interaction-policy.js", "interaction.js", "lifecycle.js", "measurement.js", "protocol.js", "renderer.js"] do
      conn = get(build_conn(), "/aiur-dom-svg-layout/#{module}")
      assert response(conn, 200) != ""
      assert Plug.Conn.get_resp_header(conn, "cache-control") == ["private, max-age=0, must-revalidate"]
    end

    assert response(get(build_conn(), "/aiur-dom-svg-layout/not-a-module.js"), 404) == "Not Found"

    loader_conn = get(build_conn(), "/aiur-dom-svg-layout-loader.js")
    assert response(loader_conn, 200) =~ "createLiveViewHook"
    assert Plug.Conn.get_resp_header(loader_conn, "cache-control") == ["private, max-age=0, must-revalidate"]

    logo = get(build_conn(), "/aiur-logo.png")
    assert response(logo, 200) == File.read!(Path.expand("../../../website/public/assets/aiur-logo.png", __DIR__))
    assert Plug.Conn.get_resp_header(logo, "content-type") == ["image/png"]

    github_mark = get(build_conn(), "/images/github-mark.svg")
    assert response(github_mark, 200) =~ "<svg"
    assert Plug.Conn.get_resp_header(github_mark, "cache-control") == ["private, max-age=0, must-revalidate"]

    bungee = get(build_conn(), "/bungee.woff2")
    assert response(bungee, 200) != ""
    assert Plug.Conn.get_resp_header(bungee, "content-type") == ["font/woff2"]

    phoenix_html_js = response(get(build_conn(), "/vendor/phoenix_html/phoenix_html.js"), 200)
    assert phoenix_html_js =~ "phoenix.link.click"

    phoenix_js = response(get(build_conn(), "/vendor/phoenix/phoenix.js"), 200)
    assert phoenix_js =~ "var Phoenix = (() => {"

    live_view_js =
      response(get(build_conn(), "/vendor/phoenix_live_view/phoenix_live_view.js"), 200)

    assert live_view_js =~ "var LiveView = (() => {"

    layout_urls = AiurWeb.StaticAssets.layout_asset_urls()

    assert layout_urls.engine =~ ~r/^\/vendor\/layout\/elk-0\.11\.1\/[a-f0-9]{64}\/elk-worker\.min\.js$/
    assert layout_urls.worker =~ ~r/^\/vendor\/layout\/worker-v1\/[a-f0-9]{64}\/aiur-layout-worker\.js$/
    assert layout_urls.client =~ ~r/^\/vendor\/layout\/client-v1\/[a-f0-9]{64}\/aiur-layout-client\.js$/

    for url <- Map.values(layout_urls) do
      conn = get(build_conn(), url)
      assert response(conn, 200) != ""
      assert Plug.Conn.get_resp_header(conn, "content-type") == ["application/javascript; charset=utf-8"]
      assert Plug.Conn.get_resp_header(conn, "cache-control") == ["private, max-age=31536000, immutable"]
    end

    assert response(get(build_conn(), "/vendor/layout/worker-v1/not-a-digest/aiur-layout-worker.js"), 404) == "Not Found"

    for private_asset <- ["LICENSE.md", "PROVENANCE.md", "SOURCE.md"] do
      private_asset_url = String.replace(layout_urls.worker, "aiur-layout-worker.js", private_asset)
      assert response(get(build_conn(), private_asset_url), 404) == "Not Found"
    end

    assert html =~ "AgentLogPanel"
    assert html =~ "AiurTicketContextDialogHook"
    assert html =~ "hooks: Hooks"
  end

  test "dashboard liveview renders and refreshes over pubsub" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardOrchestrator)
    log_root = Path.join(System.tmp_dir!(), "aiur-dashboard-log-#{System.unique_integer([:positive])}")
    log_dir = Path.join(log_root, "logs")
    File.mkdir_p!(log_dir)

    File.write!(
      Path.join(log_dir, "agent.md"),
      """
      ## 2026-05-10T03:48:24Z notification

      ```text
      {"method":"item/started","params":{"item":{"type":"userMessage","content":[{"type":"text","text":"hello from workspace log"}]}}}
      ```

      ## 2026-05-10T03:48:31Z notification

      ```text
      {"method":"item/agentMessage/delta","params":{"itemId":"msg-1","delta":"working "}}
      ```

      ## 2026-05-10T03:48:32Z notification

      ```text
      {"method":"item/agentMessage/delta","params":{"itemId":"msg-1","delta":"now"}}
      ```

      ## 2026-05-10T03:48:33Z notification

      ```text
      {"method":"item/completed","params":{"item":{"type":"agentMessage","id":"msg-1","text":"working now"}}}
      ```
      """
    )

    {snapshot, units_membership} =
      static_snapshot(workspace_path: log_root)
      |> with_static_units()

    on_exit(fn -> File.rm_rf(log_root) end)

    {:ok, orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: true,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50,
      units_membership_fun: fn -> units_membership end,
      units_activity_fun: &static_units_activity/0
    )

    {:ok, view, html} = live(build_conn(), "/?v=1&scope=unfinished")
    assert html =~ "Units"
    assert Floki.parse_document!(html) |> Floki.find("title") |> Floki.text() =~ "Dashboard"
    assert html =~ "1100"
    assert html =~ "1101"
    assert html =~ "Progress"
    assert html =~ "Runtime"
    assert html =~ "Live"
    assert html =~ "Offline"
    refute html =~ "Latest evidence"
    # The standalone read-agent-log row action moved into the chat modal, so the
    # Units row no longer carries a show-agent-log button.
    refute html =~ "phx-click=\"show-agent-log\""
    refute html =~ "data-runtime-clock="
    refute html =~ "setInterval(refreshRuntimeClocks"
    refute html =~ "Refresh now"
    refute html =~ "Transport"
    refute html =~ "status-badge-live"
    assert html =~ "status-badge-offline"
    assert html =~ ~s(id="nav-toggle")
    assert html =~ ~s(phx-hook="NavToggle")

    updated_snapshot =
      put_in(snapshot.running, [
        %{
          issue_id: "issue-http",
          identifier: "1100",
          tracker_identity: static_units_identity("1100"),
          state: "In Progress",
          title: "Updated unit title",
          session_id: "thread-http",
          turn_count: 8,
          last_codex_event: :notification,
          workspace_path: log_root,
          last_codex_message: %{
            event: :notification,
            message: %{
              payload: %{
                "method" => "codex/event/agent_message_content_delta",
                "params" => %{
                  "msg" => %{
                    "content" => "structured update"
                  }
                }
              }
            }
          },
          last_codex_timestamp: DateTime.utc_now(),
          agent_input_tokens: 10,
          agent_output_tokens: 12,
          agent_total_tokens: 22,
          started_at: DateTime.utc_now()
        }
      ])

    :sys.replace_state(orchestrator_pid, fn state ->
      Keyword.put(state, :snapshot, updated_snapshot)
    end)

    :ok = SnapshotStore.publish(orchestrator_name, updated_snapshot)

    AiurWeb.ObservabilityPubSub.broadcast_update()

    assert_eventually(fn ->
      render(view) =~ "Updated unit title"
    end)

    token = UnitsPresenter.row_token(%{identity: static_units_identity("1100")})

    # The Units row no longer has a standalone agent-log button (the chat modal
    # carries the log now), so drive the AgentLogModal event handler directly.
    log_html = render_hook(view, "show-agent-log", %{"unit" => token})

    assert log_html =~ "Logs"
    assert log_html =~ "1100"
    assert log_html =~ "data-agent-log-live"
    assert log_html =~ "Live"
    assert log_html =~ "phx-hook=\"AgentLogPanel\""
    assert log_html =~ "phx-click-away=\"close-agent-log\""
    refute log_html =~ "modal-panel\" onclick=\"event.stopPropagation()\""
    assert log_html =~ "Executor"
    assert log_html =~ "hello from workspace log"
    assert log_html =~ "working now"
    assert length(Regex.scan(~r/working now/, log_html)) == 1
    assert log_html =~ "log-message-assistant"
    assert log_html =~ Path.join(log_root, "logs/agent.md")

    File.write!(
      Path.join(log_dir, "agent.md"),
      """

      ## 2026-05-10T03:48:35Z notification

      ```text
      {"method":"item/completed","params":{"item":{"type":"agentMessage","text":"fresh modal update"}}}
      ```
      """,
      [:append]
    )

    AiurWeb.ObservabilityPubSub.broadcast_update()

    assert_eventually(fn ->
      render(view) =~ "fresh modal update"
    end)

    closed_html =
      view
      |> element("button", "Close")
      |> render_click()

    refute closed_html =~ "hello from workspace log"
  end

  test "dashboard decision routes render a stable deep link from the real Decision projection" do
    orchestrator_name = Module.concat(__MODULE__, :DecisionRouteOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :DecisionRouteStore)
    snapshot = static_snapshot()
    decision = decision_fixture("decision-live-route")

    unrelated =
      Enum.map(1..50, fn index ->
        decision_fixture("unrelated-decision-#{index}")
        |> Map.put(:blocking, false)
        |> Map.put(:urgency, :low)
      end)

    orchestrator = start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot})

    decision_store =
      start_supervised!({StaticDecisionStore, name: decision_store_name, decisions: [decision | unrelated]})

    cache = start_supervised!({AiurWeb.ControlCenterCache, name: nil})

    decision_metrics =
      start_static_payload_provider(:decision_route_metrics, snapshots: %{})

    recent_merges =
      start_static_payload_provider(
        :decision_route_recent_merges,
        snapshot: %{
          merges: [],
          health: :writable,
          reconciliation: %{status: :complete, partial?: false, pages_fetched: 0}
        }
      )

    start_test_endpoint(
      orchestrator: orchestrator,
      snapshot_timeout_ms: 50,
      decision_store: decision_store,
      decision_metrics: decision_metrics,
      recent_merge_store: recent_merges,
      control_center_cache: cache,
      dashboard_writable: false
    )

    providers = %{
      orchestrator: orchestrator,
      decision_store: decision_store,
      decision_metrics: decision_metrics,
      recent_merge_store: recent_merges,
      control_center_cache: cache
    }

    {:ok, inbox_view, inbox_html} = live(build_conn(), "/commands")
    assert inbox_html =~ "Commands inbox"

    assert has_element?(inbox_view, ~s(a[href="/commands/decision-live-route"])),
           dashboard_route_diagnostic(inbox_html, providers)

    refute has_element?(inbox_view, ~s(a[href="/commands/unrelated-decision-50"]))

    {:ok, detail_view, detail_html} = live(build_conn(), "/commands/decision-live-route")

    assert has_element?(detail_view, "#decision-detail-decision-live-route"),
           dashboard_route_diagnostic(detail_html, providers)

    assert detail_html =~ "Should this real projected decision ship?"
    assert detail_html =~ "&lt;script&gt;never execute&lt;/script&gt;"
    assert detail_html =~ "Read-only mode · Command mutation controls are hidden."
    refute detail_html =~ "phx-click=\"answer-decision\""

    {:ok, _missing_view, missing_html} = live(build_conn(), "/commands/not-present")
    assert missing_html =~ "Command not found"
    assert missing_html =~ "not-present"

    lifecycle_diagnostic = dashboard_route_diagnostic(missing_html, providers)
    assert Process.alive?(decision_store), lifecycle_diagnostic
    assert GenServer.whereis(decision_store_name) == decision_store, lifecycle_diagnostic
  end

  test "read-only dashboard liveview hides chat controls and no-ops write events" do
    orchestrator_name = Module.concat(__MODULE__, :ReadOnlyDashboardOrchestrator)
    {snapshot, units_membership} = static_snapshot() |> with_static_units()

    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50,
      dashboard_writable: false,
      units_membership_fun: fn -> units_membership end,
      units_activity_fun: &static_units_activity/0
    )

    {:ok, view, _html} = live(build_conn(), "/")

    token = UnitsPresenter.row_token(%{identity: static_units_identity("1100")})

    modal_html = render_hook(view, "show-agent-log", %{"unit" => token})

    # The agent log modal still opens (reads work), but the composer and its
    # Send/Pause controls are gone — replaced by the read-only notice.
    assert modal_html =~ "Read-only dashboard"
    refute modal_html =~ "agent-chat-send"
    refute modal_html =~ "phx-submit=\"send-operator-message\""
    refute modal_html =~ "phx-click=\"pause-agent\""

    # Defense-in-depth: even a crafted client pushing the write events is a
    # no-op — the guarded clauses fall through and the view stays alive.
    assert render_hook(view, "send-operator-message", %{"message" => "hello"}) =~ "Read-only dashboard"
    assert render_hook(view, "pause-agent", %{}) =~ "Read-only dashboard"
    assert Process.alive?(view.pid)
  end

  test "dashboard liveview renders an unavailable state without crashing" do
    start_test_endpoint(
      orchestrator: Module.concat(__MODULE__, :MissingDashboardOrchestrator),
      snapshot_timeout_ms: 5
    )

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Fleet snapshot unavailable"
    assert html =~ "orchestrator_unavailable"
    # The presenter still carries the unpublished wording for other codes; an
    # unreachable Orchestrator must never borrow it.
    refute html =~ "No fleet snapshot published yet"
  end

  test "http server serves embedded assets, accepts form posts, and rejects invalid hosts" do
    previous_username = System.get_env("AIUR_DASHBOARD_USERNAME")
    previous_password = System.get_env("AIUR_DASHBOARD_PASSWORD")
    previous_endpoint_config = Application.get_env(:aiur, AiurWeb.Endpoint)
    System.put_env("AIUR_DASHBOARD_USERNAME", "operator")
    System.put_env("AIUR_DASHBOARD_PASSWORD", "secret")

    on_exit(fn ->
      restore_env("AIUR_DASHBOARD_USERNAME", previous_username)
      restore_env("AIUR_DASHBOARD_PASSWORD", previous_password)
      restore_endpoint_config(previous_endpoint_config)
    end)

    authorization = {"authorization", "Basic " <> Base.encode64("operator:secret")}

    spec = HttpServer.child_spec(port: 0)
    assert spec.id == HttpServer
    assert spec.start == {HttpServer, :start_link, [[port: 0]]}

    assert :ignore = HttpServer.start_link(port: nil)
    assert HttpServer.bound_port() == nil

    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :BoundPortOrchestrator)

    refresh = %{
      queued: true,
      coalesced: false,
      requested_at: DateTime.utc_now(),
      operations: ["poll"]
    }

    server_opts = [
      host: "127.0.0.1",
      port: 0,
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50,
      dashboard_writable: true
    ]

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot, refresh: refresh})

    start_supervised!({HttpServer, server_opts})

    port = wait_for_bound_port()
    assert port == HttpServer.bound_port()
    assert HttpServer.base_url() == "http://127.0.0.1:#{port}"

    unauthenticated_response = Req.get!("http://127.0.0.1:#{port}/api/v1/state")
    assert unauthenticated_response.status == 401

    for asset_path <- ["/conversation-drawer-hook.js", "/provider-assets/codex-color.svg"] do
      unauthenticated_asset = Req.get!("http://127.0.0.1:#{port}#{asset_path}")
      assert unauthenticated_asset.status == 401
    end

    response = Req.get!("http://127.0.0.1:#{port}/api/v1/state", headers: [authorization])
    assert response.status == 200
    assert response.body["counts"] == %{"running" => 1, "retrying" => 1, "idle" => 0}

    dashboard_css = Req.get!("http://127.0.0.1:#{port}/dashboard.css", headers: [authorization])
    assert dashboard_css.status == 200
    assert dashboard_css.body =~ ":root {"

    conversation_drawer_hook = Req.get!("http://127.0.0.1:#{port}/conversation-drawer-hook.js", headers: [authorization])
    assert conversation_drawer_hook.status == 200
    assert conversation_drawer_hook.body =~ "AiurConversationDrawerHook"

    provider_asset = Req.get!("http://127.0.0.1:#{port}/provider-assets/codex-color.svg", headers: [authorization])
    assert provider_asset.status == 200
    assert provider_asset.body =~ "<svg"

    phoenix_js = Req.get!("http://127.0.0.1:#{port}/vendor/phoenix/phoenix.js", headers: [authorization])
    assert phoenix_js.status == 200
    assert phoenix_js.body =~ "var Phoenix = (() => {"

    refresh_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/refresh",
        headers: [
          authorization,
          {"content-type", "application/x-www-form-urlencoded"},
          {"origin", "http://127.0.0.1:#{port}"},
          {"x-aiur-request", "1"}
        ],
        body: ""
      )

    assert refresh_response.status == 202
    assert refresh_response.body["queued"] == true

    method_not_allowed_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/state",
        headers: [authorization, {"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert method_not_allowed_response.status == 405

    System.delete_env("AIUR_DASHBOARD_PASSWORD")

    credential_loss_response =
      Req.get!("http://127.0.0.1:#{port}/api/v1/state", headers: [authorization])

    assert credential_loss_response.status == 401
    assert method_not_allowed_response.body["error"]["code"] == "method_not_allowed"

    assert {:error, _reason} = HttpServer.start_link(host: "bad host", port: 0)
  end

  test "http server honors host override when workflow host is unavailable" do
    previous_host_override = Application.get_env(:aiur, :server_host_override)

    Application.put_env(:aiur, :server_host_override, "127.0.0.1")

    on_exit(fn ->
      case previous_host_override do
        nil -> Application.delete_env(:aiur, :server_host_override)
        host -> Application.put_env(:aiur, :server_host_override, host)
      end
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      server_host: "192.0.2.123",
      server_port: 0
    )

    start_supervised!({HttpServer, port: 0, dashboard_writable: false})
    assert is_integer(wait_for_bound_port())
  end

  defp start_test_endpoint(overrides) do
    control_center_cache =
      Keyword.get_lazy(overrides, :control_center_cache, fn ->
        start_supervised!({AiurWeb.ControlCenterCache, name: nil})
      end)

    endpoint_config =
      :aiur
      |> Application.get_env(AiurWeb.Endpoint, [])
      |> Keyword.merge(
        server: false,
        secret_key_base: String.duplicate("s", 64),
        dashboard_writable: true,
        dashboard_auth_required: false,
        control_center_cache: control_center_cache
      )
      |> Keyword.merge(overrides)

    Application.put_env(:aiur, AiurWeb.Endpoint, endpoint_config)
    start_supervised!({AiurWeb.Endpoint, []})
  end

  defp start_static_payload_provider(id, responses) do
    {StaticPayloadProvider, responses}
    |> Supervisor.child_spec(id: {StaticPayloadProvider, id})
    |> start_supervised!()
  end

  defp dashboard_route_diagnostic(html, providers) do
    payload =
      AiurWeb.ControlCenterPresenter.state_payload(providers.orchestrator, 50,
        decision_store: providers.decision_store,
        decision_metrics: providers.decision_metrics,
        recent_merge_store: providers.recent_merge_store
      )

    provider_status =
      Map.new(providers, fn {name, server} ->
        pid = GenServer.whereis(server)
        {name, %{server: inspect(server), pid: inspect(pid), alive?: is_pid(pid) and Process.alive?(pid)}}
      end)

    """
    Expected the stable Decision route from isolated providers.
    provider_status=#{inspect(provider_status, pretty: true)}
    payload_health=#{inspect(payload.provider_health, pretty: true)}
    payload_decision_ids=#{inspect(Enum.map(payload.decisions, & &1.decision_id))}
    rendered_html=#{html}
    """
  end

  defp restore_endpoint_config(nil), do: Application.delete_env(:aiur, AiurWeb.Endpoint)
  defp restore_endpoint_config(config), do: Application.put_env(:aiur, AiurWeb.Endpoint, config)

  defp static_snapshot(opts \\ []) do
    workspace_path = Keyword.get(opts, :workspace_path)

    %{
      running: [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 7,
          codex_app_server_pid: nil,
          last_codex_message: "rendered",
          last_codex_timestamp: nil,
          last_codex_event: :notification,
          workspace_path: workspace_path,
          queue_depth: 1,
          control: %{
            accepts_operator_messages: true,
            can_interrupt: false,
            accepted_delivery_policies: [:checkpoint],
            safe_checkpoints: [:notification, :tool_result],
            queue_depth: 1
          },
          agent_input_tokens: 4,
          agent_output_tokens: 8,
          agent_total_tokens: 12,
          started_at: DateTime.utc_now()
        }
      ],
      retrying: [
        %{
          issue_id: "issue-retry",
          identifier: "MT-RETRY",
          attempt: 2,
          due_in_ms: 2_000,
          error: "boom"
        }
      ],
      idle: [],
      agent_totals: %{input_tokens: 4, output_tokens: 8, total_tokens: 12, seconds_running: 42.5},
      rate_limits: %{"primary" => %{"remaining" => 11}}
    }
  end

  defp with_static_units(snapshot) do
    observed_at = DateTime.utc_now()
    running_identity = static_units_identity("1100")
    retrying_identity = static_units_identity("1101")

    snapshot =
      snapshot
      |> update_in([:running], fn rows ->
        Enum.map(rows, &Map.merge(&1, %{identifier: "1100", tracker_identity: running_identity}))
      end)
      |> update_in([:retrying], fn rows ->
        Enum.map(rows, &Map.merge(&1, %{identifier: "1101", tracker_identity: retrying_identity}))
      end)

    membership = %{
      run_id: "extensions-dashboard",
      generation: 1,
      health: :healthy,
      health_message: nil,
      freshness: %{status: :fresh, observed_at: observed_at},
      members: [
        static_units_member(running_identity, :running, observed_at),
        static_units_member(retrying_identity, :retrying, observed_at)
      ],
      truncated?: false
    }

    {snapshot, membership}
  end

  defp static_units_identity(identifier) do
    %Aiur.TrackerIdentity{
      status: :joinable,
      kind: :github,
      owner: Aiur.TestSupport.github_owner(),
      repository: Aiur.TestSupport.github_repository_name(),
      provider_id: "NODE-#{identifier}",
      identifier: identifier,
      reason: nil
    }
  end

  defp static_units_member(identity, lifecycle, observed_at) do
    %{
      identity: identity,
      lifecycle: lifecycle,
      terminal?: false,
      first_observed_at: observed_at,
      last_observed_at: observed_at
    }
  end

  defp static_units_activity do
    %{
      generation: 1,
      health: :healthy,
      freshness: %{status: :fresh},
      entries: []
    }
  end

  defp decision_fixture(decision_id) do
    %Aiur.Decision{
      decision_id: decision_id,
      source_id: decision_id,
      version: 1,
      ticket: %{identifier: "MT-HTTP", title: "Projected ticket", url: "https://example.test/issues/MT-HTTP"},
      source: %{agent_id: "agent-http", session_id: "thread-http", event_id: "event-http"},
      kind: "architecture",
      authority: :human_required,
      urgency: :critical,
      blocking: true,
      reversibility: :reversible,
      question: "Should this real projected decision ship?",
      context: %{short_summary: "A durable request", long_context_markdown: "<script>never execute</script>"},
      options: [],
      recommendation: nil,
      consequence_of_delay: "The ticket agent remains paused.",
      artifacts: [],
      created_at: ~U[2026-07-12 12:00:00Z],
      source_created_at: ~U[2026-07-12 12:00:00Z],
      content_hash: "hash-#{decision_id}"
    }
  end

  defp assert_occ_sections(payload) do
    assert %{"entries" => decision_entries, "status" => decision_status} = payload["decision_history"]
    assert is_list(decision_entries)
    assert decision_status in ["available", "unavailable"]

    assert %{
             "entries" => merge_entries,
             "reconciliation" => %{"pages_fetched" => pages_fetched},
             "status" => merge_status
           } = payload["recent_merges"]

    assert is_list(merge_entries)
    assert is_integer(pages_fetched)
    assert merge_status in ["available", "degraded", "unavailable"]

    assert %{"available?" => available?, "message" => message} = payload["analytics"]
    assert is_boolean(available?)
    assert is_binary(message)
  end

  defp without_occ_sections(payload) do
    Map.drop(payload, [
      "decision_history",
      "recent_merges",
      "analytics",
      "capacity",
      "capacity_hold",
      "dispatch_hold"
    ])
  end

  defp wait_for_bound_port do
    assert_eventually(fn ->
      is_integer(HttpServer.bound_port())
    end)

    HttpServer.bound_port()
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")
end
