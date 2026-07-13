defmodule Aiur.ExtensionsTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Aiur.Linear.Tracker, as: LinearTracker
  alias Aiur.Memory.Tracker, as: Memory

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

    def init(opts), do: {:ok, opts}

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

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :decisions), name: name)
    end

    def init(decisions), do: {:ok, decisions}
    def handle_call(:list, _from, decisions), do: {:reply, decisions, decisions}
    def handle_call({:recent_decisions, limit}, _from, decisions), do: {:reply, Enum.take(decisions, limit), decisions}
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

    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Second prompt")
    send(WorkflowStore, :poll)

    assert_eventually(fn ->
      match?({:ok, %{prompt: "Second prompt"}}, Workflow.current())
    end)

    File.write!(Workflow.workflow_file_path(), "tracker: [\n")
    assert {:error, _reason} = WorkflowStore.force_reload()
    assert {:ok, %{prompt: "Second prompt"}} = Workflow.current()

    third_workflow = Path.join(Path.dirname(Workflow.workflow_file_path()), "third.aiurconfig")
    write_workflow_file!(third_workflow, prompt: "Third prompt")
    Workflow.set_workflow_file_path(third_workflow)
    assert {:ok, %{prompt: "Third prompt"}} = Workflow.current()

    assert :ok = Supervisor.terminate_child(Aiur.Supervisor, WorkflowStore)
    assert {:ok, %{prompt: "Third prompt"}} = WorkflowStore.current()
    assert :ok = WorkflowStore.force_reload()
    assert :ok = ensure_workflow_store_running()
  end

  test "workflow store falls back when it shuts down during a read" do
    ensure_workflow_store_running()
    store = Process.whereis(WorkflowStore)

    on_exit(fn ->
      if Process.alive?(store), do: :sys.resume(store)
      ensure_workflow_store_running()
    end)

    :sys.suspend(store)
    :erlang.trace(store, true, [:receive])

    reader = Task.Supervisor.async_nolink(Aiur.TaskSupervisor, fn -> WorkflowStore.current() end)

    assert_receive {:trace, ^store, :receive, {:"$gen_call", _from, :current}}
    assert :ok = Supervisor.terminate_child(Aiur.Supervisor, WorkflowStore)
    assert {:ok, %{prompt: "You are an agent for this repository."}} = Task.await(reader)
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

    config_path = Path.join(Path.dirname(original_path), "prompt_reload.aiurconfig")
    write_workflow_file!(config_path, prompt: "Original prompt body")
    Workflow.set_workflow_file_path(config_path)

    assert {:ok, %{prompt: "Original prompt body"}} = Workflow.current()

    # Edit only the referenced prompt_file; the .aiurconfig bytes are untouched.
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
    missing_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "missing.aiurconfig")
    Workflow.set_workflow_file_path(missing_path)

    assert {:stop, {:missing_workflow_file, ^missing_path, :enoent}} = WorkflowStore.init([])
  end

  test "workflow store start_link and poll callback cover missing-file error paths" do
    ensure_workflow_store_running()
    # Terminates the shared WorkflowStore mid-body; restore it in on_exit so a
    # mid-test failure can't leak a down store to a later sequential module.
    on_exit(fn -> ensure_workflow_store_running() end)
    existing_path = Workflow.workflow_file_path()
    manual_path = Path.join(Path.dirname(existing_path), "manual.aiurconfig")
    missing_path = Path.join(Path.dirname(existing_path), "manual-missing.aiurconfig")

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
                 "ci" => nil,
                 "review" => "not_started",
                 "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
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
                 "ci" => nil,
                 "review" => "not_started"
               }
             ],
             "idle" => [],
             "agent_totals" => %{
               "input_tokens" => 4,
               "output_tokens" => 8,
               "total_tokens" => 12,
               "seconds_running" => 42.5
             },
             "rate_limits" => %{"primary" => %{"remaining" => 11}}
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
               "last_event_at" => nil,
               "stale_for_seconds" => nil,
               "waiting_reason" => "active",
               "open_decision_count" => 0,
               "ci" => nil,
               "review" => "not_started",
               "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
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
    assert html =~ "/vendor/phoenix_html/phoenix_html.js"
    assert html =~ "/vendor/phoenix/phoenix.js"
    assert html =~ "/vendor/phoenix_live_view/phoenix_live_view.js"
    refute html =~ "/assets/app.js"
    refute html =~ "<style>"

    dashboard_css = response(get(build_conn(), "/dashboard.css"), 200)
    assert dashboard_css =~ ":root {"
    assert dashboard_css =~ ".status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-offline"
    assert dashboard_css =~ ".live-button[data-live=\"false\"]"

    logo = get(build_conn(), "/aiur-logo.png")
    assert response(logo, 200) == File.read!(Path.expand("../../../website/public/assets/aiur-logo.png", __DIR__))
    assert Plug.Conn.get_resp_header(logo, "content-type") == ["image/png; charset=utf-8"]

    phoenix_html_js = response(get(build_conn(), "/vendor/phoenix_html/phoenix_html.js"), 200)
    assert phoenix_html_js =~ "phoenix.link.click"

    phoenix_js = response(get(build_conn(), "/vendor/phoenix/phoenix.js"), 200)
    assert phoenix_js =~ "var Phoenix = (() => {"

    live_view_js =
      response(get(build_conn(), "/vendor/phoenix_live_view/phoenix_live_view.js"), 200)

    assert live_view_js =~ "var LiveView = (() => {"
    assert html =~ "AgentLogPanel"
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

    snapshot = static_snapshot(workspace_path: log_root)

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

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Operator Control Center"
    assert html =~ "MT-HTTP"
    assert html =~ "MT-RETRY"
    assert html =~ "rendered"
    assert html =~ "Elapsed"
    assert html =~ "Live"
    assert html =~ "Offline"
    assert html =~ "Latest"
    assert html =~ "phx-click=\"show-agent-log\""
    refute html =~ "data-runtime-clock="
    refute html =~ "setInterval(refreshRuntimeClocks"
    refute html =~ "Refresh now"
    refute html =~ "Transport"
    assert html =~ "status-badge-live"
    assert html =~ "status-badge-offline"

    updated_snapshot =
      put_in(snapshot.running, [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
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

    AiurWeb.ObservabilityPubSub.broadcast_update()

    assert_eventually(fn ->
      render(view) =~ "structured update"
    end)

    log_html =
      view
      |> element("tr[phx-value-issue=\"MT-HTTP\"]")
      |> render_click()

    assert log_html =~ "Logs"
    assert log_html =~ "MT-HTTP"
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

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot})
    start_supervised!({StaticDecisionStore, name: decision_store_name, decisions: [decision | unrelated]})

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50,
      decision_store: decision_store_name,
      dashboard_writable: false
    )

    {:ok, inbox_view, inbox_html} = live(build_conn(), "/decisions")
    assert inbox_html =~ "Decision inbox"
    assert has_element?(inbox_view, ~s(a[href="/decisions/decision-live-route"]))
    refute has_element?(inbox_view, ~s(a[href="/decisions/unrelated-decision-50"]))

    {:ok, detail_view, detail_html} = live(build_conn(), "/decisions/decision-live-route")
    assert has_element?(detail_view, "#decision-detail-decision-live-route")
    assert detail_html =~ "Should this real projected decision ship?"
    assert detail_html =~ "&lt;script&gt;never execute&lt;/script&gt;"
    assert detail_html =~ "Read-only mode · mutation controls are hidden."
    refute detail_html =~ "phx-click=\"answer-decision\""

    {:ok, _missing_view, missing_html} = live(build_conn(), "/decisions/not-present")
    assert missing_html =~ "Decision not found"
    assert missing_html =~ "not-present"
  end

  test "read-only dashboard liveview hides chat controls and no-ops write events" do
    orchestrator_name = Module.concat(__MODULE__, :ReadOnlyDashboardOrchestrator)
    snapshot = static_snapshot()

    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50,
      dashboard_writable: false
    )

    {:ok, view, _html} = live(build_conn(), "/")

    modal_html =
      view
      |> element("tr[phx-value-issue=\"MT-HTTP\"]")
      |> render_click()

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
    assert html =~ "Snapshot unavailable"
    assert html =~ "snapshot_unavailable"
  end

  test "http server serves embedded assets, accepts form posts, and rejects invalid hosts" do
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

    response = Req.get!("http://127.0.0.1:#{port}/api/v1/state")
    assert response.status == 200
    assert response.body["counts"] == %{"running" => 1, "retrying" => 1, "idle" => 0}

    dashboard_css = Req.get!("http://127.0.0.1:#{port}/dashboard.css")
    assert dashboard_css.status == 200
    assert dashboard_css.body =~ ":root {"

    phoenix_js = Req.get!("http://127.0.0.1:#{port}/vendor/phoenix/phoenix.js")
    assert phoenix_js.status == 200
    assert phoenix_js.body =~ "var Phoenix = (() => {"

    refresh_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/refresh",
        headers: [
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
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert method_not_allowed_response.status == 405
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

    start_supervised!({HttpServer, port: 0})
    assert is_integer(wait_for_bound_port())
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :aiur
      |> Application.get_env(AiurWeb.Endpoint, [])
      |> Keyword.merge(
        server: false,
        secret_key_base: String.duplicate("s", 64),
        dashboard_writable: true
      )
      |> Keyword.merge(overrides)

    Application.put_env(:aiur, AiurWeb.Endpoint, endpoint_config)
    start_supervised!({AiurWeb.Endpoint, []})
  end

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
    Map.drop(payload, ["decision_history", "recent_merges", "analytics"])
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
