defmodule Aiur.Claude.CodingAgentRefusalTest do
  use Aiur.TestSupport

  alias Aiur.AgentRunner.TurnAlerts
  alias Aiur.Claude.CodingAgent, as: ClaudeAgent
  alias Aiur.Issue
  alias Aiur.ModelAvailability
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.{RateLimitFallback, State}
  alias Aiur.Workflow

  test "rate-limit notifications ingest through the Claude meter adapter and log only a redacted marker" do
    root = Aiur.TestSupport.tmp_root!("aiur_claude_meter")
    workspace = Path.join(root, "agent-1")
    File.mkdir_p!(workspace)
    frames = Path.join(workspace, "frames.jsonl")
    on_exit(fn -> File.rm_rf(root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_kind: "claude",
      workspace_root: root,
      command: fake_app_server_with_rate_limit(frames)
    )

    {:ok, account_owner} =
      start_supervised({Aiur.ProviderAccountGeneration, name: nil}, id: :claude_meter_account_owner)

    test_pid = self()

    ingester = fn update ->
      send(test_pid, {:meter_update, update})
      {:ok, %{}}
    end

    failure_recorder = fn failure ->
      send(test_pid, {:meter_failure, failure})
      {:ok, %{}}
    end

    on_message = fn message -> send(test_pid, {:agent_message, message}) end
    issue = %{id: 1, identifier: "test:meter", title: "meter"}

    assert {:ok, session} =
             ClaudeAgent.start_session(workspace,
               account_generation_server: account_owner,
               provider_meter_ingester: ingester,
               provider_meter_failure_recorder: failure_recorder
             )

    assert {:ok, %{result: :turn_completed}} =
             ClaudeAgent.run_turn(session, "read limits", issue, on_message: on_message)

    assert_received {:meter_update,
                     %{
                       provider: :claude,
                       auth_mode: :subscription,
                       source_version: 9_009_009,
                       windows: [%{standing: :allowed_warning, used_percent: 83}]
                     }}

    assert_received {:agent_message,
                     %{
                       event: :notification,
                       payload: %{"method" => "provider_account/rate_limits_changed", "params" => %{}},
                       raw: nil
                     } = message}

    notification_wire = Jason.encode!(message)
    refute String.contains?(notification_wire, "secret-turn-correlation")
    refute String.contains?(notification_wire, "secret-thread-correlation")
    refute String.contains?(notification_wire, "source_version")
    refute_received {:meter_failure, _failure}

    ClaudeAgent.stop_session(session)
  end

  test "provider stderr session-limit refusal pauses without retries and resumes at the parsed reset" do
    # The wrapper includes CLI stderr in turn/failed.error. Assistant text
    # alone does not establish that a provider refusal occurred.
    root = Aiur.TestSupport.tmp_root!("aiur_claude_session_limit")
    workspace = Path.join(root, "agent-1")
    File.mkdir_p!(workspace)
    frames = Path.join(workspace, "frames.jsonl")
    on_exit(fn -> File.rm_rf(root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_kind: "claude",
      workspace_root: root,
      command: fake_app_server_that_hits_the_session_limit(frames)
    )

    issue = %Issue{id: "session-limit", identifier: "test:session-limit", title: "session-limit", selected_backend: "claude", state: "In Progress"}
    test_pid = self()
    on_message = fn message -> send(test_pid, {:agent_message, message}) end

    assert {:ok, session} = ClaudeAgent.start_session(workspace)

    assert {:paused, pause} = ClaudeAgent.run_turn(session, "do the thing", issue, on_message: on_message)

    assert pause.kind == :usage_limit_exhausted
    assert pause.reason =~ "session limit"
    assert pause.reset_hint == "12:20am (America/Los_Angeles)"
    assert {:ok, reset, 0} = DateTime.from_iso8601(pause.reset_at)
    assert reset.hour == 7 or reset.hour == 8
    assert reset.minute == 20
    refute_received {:agent_message, %{event: :turn_ended_with_error}}

    TurnAlerts.maybe_emit_usage_limit_alert(issue, workspace, nil, Map.put(pause, :backend, "claude"))
    ledger = ModelAvailability.load()
    assert get_in(ledger, ["backends", "claude", "reset_at"]) == pause.reset_at

    # Reproduce a failed atomic rename without touching any shared/live path.
    ledger_path = ModelAvailability.path()
    File.rm!(ledger_path)
    File.mkdir!(ledger_path)

    assert ExUnit.CaptureLog.capture_log(fn ->
             TurnAlerts.maybe_emit_usage_limit_alert(issue, workspace, nil, Map.put(pause, :backend, "claude"))
           end) =~ "Unable to persist provider limit"

    assert ModelAvailability.load() == %{"backends" => %{}}
    File.rmdir!(ledger_path)
    File.write!(ledger_path, Jason.encode!(ledger))

    entry = %{
      issue: issue,
      identifier: issue.identifier,
      pid: self(),
      ref: make_ref(),
      started_at: DateTime.utc_now(),
      retry_attempt: 2,
      control: %{status: :working, can_interrupt: true}
    }

    state = %State{running: %{issue.id => entry}, max_concurrent_agents: 6}
    assert {:noreply, paused} = Orchestrator.handle_info({:worker_control_state, issue.id, :paused, pause}, state)
    assert paused.retry_attempts == state.retry_attempts
    assert paused.running[issue.id].retry_attempt == 2
    assert paused.running[issue.id].paused_reason == :usage_limit_exhausted
    assert paused.running[issue.id].usage_limit_reset_at == pause.reset_at

    opts = [primary_backend: "claude", fallback_backend: nil, marker_label: "agent:rate-limit-fallback", state: %{"backends" => %{}}]
    assert RateLimitFallback.reconcile(paused, Keyword.put(opts, :now, DateTime.add(reset, -1))) == paused

    assert RateLimitFallback.decide(paused.running[issue.id], issue, Keyword.merge(opts, fallback_backend: "codex", current_backend: "claude", now: DateTime.add(reset, -1))) ==
             :engage

    global_pause = %{paused | globally_paused: true}
    assert RateLimitFallback.reconcile(global_pause, Keyword.put(opts, :now, reset)) == global_pause
    label_pause = put_in(paused.running[issue.id].issue.paused, true)
    assert RateLimitFallback.reconcile(label_pause, Keyword.put(opts, :now, reset)) == label_pause
    operator_pause = put_in(paused.running[issue.id].paused_reason, :operator_pause)
    assert RateLimitFallback.reconcile(operator_pause, Keyword.put(opts, :now, reset)) == operator_pause

    resumed = RateLimitFallback.reconcile(paused, Keyword.put(opts, :now, reset))
    assert_received {:resume_agent, _request_id}
    assert resumed.running[issue.id].control.status == :working
    assert resumed.retry_attempts == state.retry_attempts
    assert resumed.running[issue.id].retry_attempt == 2
    assert {:ok, %{result: :turn_completed}} = ClaudeAgent.run_turn(session, "resume", issue)

    # The preceding quota refusal must not misclassify a later ordinary crash.
    assert {:error, {:turn_failed, %{"error" => "Error: claude exited with code 1"}}} =
             ClaudeAgent.run_turn(session, "next turn", issue)

    # Quoted prose, another turn's banner and tool output are not refusals.
    for prompt <- ["stale turn", "quoted banner", "tool output"] do
      assert {:error, {:turn_failed, %{"error" => "Error: claude exited with code 1"}}} =
               ClaudeAgent.run_turn(session, prompt, issue)
    end

    ClaudeAgent.stop_session(session)
  end

  test "an exact assistant session-limit banner followed by an unrelated crash does not limit availability" do
    root = Aiur.TestSupport.tmp_root!("aiur_claude_assistant_banner")
    workspace = Path.join(root, "agent-1")
    File.mkdir_p!(workspace)
    frames = Path.join(workspace, "frames.jsonl")
    on_exit(fn -> File.rm_rf(root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_kind: "claude",
      workspace_root: root,
      command: fake_app_server_that_hits_the_session_limit(frames, false)
    )

    issue = %Issue{id: "assistant-banner", identifier: "test:assistant-banner", title: "assistant-banner", selected_backend: "claude"}
    availability_before = ModelAvailability.load()
    assert {:ok, session} = ClaudeAgent.start_session(workspace)
    on_exit(fn -> ClaudeAgent.stop_session(session) end)

    result = ClaudeAgent.run_turn(session, "repeat the banner verbatim", issue)

    # Exercise the runner's pause-to-ledger boundary if the adapter incorrectly
    # trusts the assistant's text; an ordinary crash must never reach it.
    case result do
      {:paused, pause} -> TurnAlerts.maybe_emit_usage_limit_alert(issue, workspace, nil, Map.put(pause, :backend, "claude"))
      _ -> :ok
    end

    assert ModelAvailability.load() == availability_before
    assert {:error, {:turn_failed, %{"error" => "Error: claude exited with code 1"}}} = result
  end

  test "the observed Khala refusal pauses from CLI provenance at the banner's reset without a retry" do
    # #2727: the CLI printed the banner as a synthetic assistant message
    # (error "rate_limit", api_error_status 429) and exited 1 with no stderr.
    # These are the frames aiur-claude emits for that CLI stream once it
    # forwards provenance; the banner text alone is never trusted.
    root = Aiur.TestSupport.tmp_root!("aiur_claude_provider_refusal")
    workspace = Path.join(root, "agent-1")
    File.mkdir_p!(workspace)
    frames = Path.join(workspace, "frames.jsonl")
    on_exit(fn -> File.rm_rf(root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_kind: "claude",
      workspace_root: root,
      command: fake_app_server_with_provider_refusal(frames)
    )

    issue = %Issue{id: "khala-20", identifier: "test:khala-20", title: "khala-20", selected_backend: "claude", state: "In Progress"}
    test_pid = self()
    on_message = fn message -> send(test_pid, {:agent_message, message}) end

    assert {:ok, session} = ClaudeAgent.start_session(workspace, clock: fn -> ~U[2026-09-18 04:53:32Z] end)
    on_exit(fn -> ClaudeAgent.stop_session(session) end)

    assert {:paused, pause} = ClaudeAgent.run_turn(session, "rework PR #74", issue, on_message: on_message)
    assert pause.kind == :usage_limit_exhausted
    assert pause.reason == "You've hit your session limit · resets 12:20am (America/Los_Angeles)"
    assert pause.reset_hint == "12:20am (America/Los_Angeles)"
    assert pause.reset_at == "2026-09-18T07:20:00Z"
    refute_received {:agent_message, %{event: :turn_ended_with_error}}

    entry = %{
      issue: issue,
      identifier: issue.identifier,
      pid: self(),
      ref: make_ref(),
      started_at: DateTime.utc_now(),
      retry_attempt: 2,
      control: %{status: :working, can_interrupt: true}
    }

    state = %State{running: %{issue.id => entry}, max_concurrent_agents: 6}
    assert {:noreply, paused} = Orchestrator.handle_info({:worker_control_state, issue.id, :paused, pause}, state)
    assert paused.retry_attempts == state.retry_attempts
    assert paused.running[issue.id].retry_attempt == 2
    assert paused.running[issue.id].paused_reason == :usage_limit_exhausted
    assert paused.running[issue.id].usage_limit_reset_at == "2026-09-18T07:20:00Z"

    # Provenance for a different provider error is still a turn failure.
    assert {:error, {:turn_failed, %{"provider_error" => %{"error" => "model_not_found"}}}} =
             ClaudeAgent.run_turn(session, "unknown model", issue, on_message: on_message)

    # The legacy wire shape (untagged banner text, bare exit 1) stays a failure.
    assert {:error, {:turn_failed, %{"error" => "Error: claude exited with code 1"} = params}} =
             ClaudeAgent.run_turn(session, "untagged banner", issue, on_message: on_message)

    refute Map.has_key?(params, "provider_error")
  end

  test "an ordinary turn failure is still a turn failure" do
    root = Aiur.TestSupport.tmp_root!("aiur_claude_turn_failed")
    workspace = Path.join(root, "agent-1")
    File.mkdir_p!(workspace)
    frames = Path.join(workspace, "frames.jsonl")
    on_exit(fn -> File.rm_rf(root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_kind: "claude",
      workspace_root: root,
      command: fake_app_server_that_fails_a_turn(frames)
    )

    issue = %{id: 1, identifier: "test:turn-failed", title: "turn-failed"}

    assert {:ok, session} = ClaudeAgent.start_session(workspace)

    assert {:error, {:turn_failed, %{"error" => "Error: claude exited with code 1"}}} =
             ClaudeAgent.run_turn(session, "do the thing", issue, on_message: fn _message -> :ok end)
  end

  defp fake_app_server_with_rate_limit(frames) do
    init = ~s({"jsonrpc":"2.0","id":1,"result":{"server":{"name":"fake"}}})
    thread = ~s({"jsonrpc":"2.0","id":2,"result":{"thread":{"id":"t1"}}})
    turn = ~s({"jsonrpc":"2.0","id":3,"result":{"turn":{"id":"u1"}}})

    rate_limit =
      ~s|{"jsonrpc":"2.0","method":"rate_limit/update","params":{"turn_id":"secret-turn-correlation","thread_id":"secret-thread-correlation","rate_limit":{"status":"allowed_warning","used_percent":83,"resets_at":1784192400,"account_type":"subscription","source_version":"9.9.9-test (fake-claude)"}}}|

    completed = ~s({"jsonrpc":"2.0","method":"turn/completed","params":{"turn":{"status":"completed"}}})

    "while IFS= read -r line; do echo \"$line\" >> #{frames}; " <>
      "case \"$line\" in " <>
      "*'\"initialize\"'*) echo '#{init}' ;; " <>
      "*'\"thread/start\"'*) echo '#{thread}' ;; " <>
      "*'\"turn/start\"'*) echo '#{turn}'; echo '#{rate_limit}'; echo '#{completed}' ;; " <>
      "esac; done"
  end

  # Preserve the wrapper's distinction between assistant text and CLI stderr.
  defp fake_app_server_that_hits_the_session_limit(frames, provider_refusal? \\ true) do
    init = ~s({"jsonrpc":"2.0","id":1,"result":{"server":{"name":"fake"}}})
    thread = ~s({"jsonrpc":"2.0","id":2,"result":{"thread":{"id":"t1"}}})
    turn = ~s({"jsonrpc":"2.0","id":3,"result":{"turn":{"id":"u1"}}})

    banner =
      Jason.encode!(%{
        "method" => "item/created",
        "params" => %{"turn_id" => "u1", "item" => %{"type" => "text", "text" => "You've hit your session limit · resets 12:20am (America/Los_Angeles)"}}
      })
      |> String.replace("'", "\\u0027")

    stale = String.replace(banner, "u1", "earlier-turn")
    quoted = String.replace(banner, "You", "The log says: You")
    tool = String.replace(banner, "\"type\":\"text\"", "\"type\":\"tool_result\"")

    failed =
      ~s({"jsonrpc":"2.0","method":"turn/failed","params":{"error":"Error: claude exited with code 1","turn_id":"u1"}})

    first_failure =
      if provider_refusal? do
        Jason.encode!(%{
          "method" => "turn/failed",
          "params" => %{"turn_id" => "u1", "error" => "Error: claude exited with code 1\nstderr: You've hit your session limit · resets 12:20am (America/Los_Angeles)"}
        })
        |> String.replace("'", "\\u0027")
      else
        failed
      end

    script =
      "n=0; while IFS= read -r line; do echo \"$line\" >> #{frames}; " <>
        "case \"$line\" in " <>
        "*'\"initialize\"'*) echo '#{init}' ;; " <>
        "*'\"thread/start\"'*) echo '#{thread}' ;; " <>
        "*'\"turn/start\"'*) n=$((n + 1)); echo '#{turn}'; " <>
        "if [ \"$n\" -eq 1 ]; then echo '#{banner}'; echo '#{first_failure}'; " <>
        ~s(elif [ "$n" -eq 2 ]; then echo '{"method":"turn/completed","params":{}}'; ) <>
        "else " <>
        "case \"$n\" in 4) echo '#{stale}' ;; 5) echo '#{quoted}' ;; 6) echo '#{tool}' ;; esac; " <>
        "echo '#{failed}'; fi ;; " <>
        "esac; done"

    File.write!(frames <> ".sh", script)
    "bash #{frames}.sh"
  end

  # Frames captured from aiur-claude replaying the CLI stream-json of the Khala
  # incident (turn ids normalized to u1): the synthesized text is tagged and
  # turn/failed carries the CLI's error class, HTTP status and banner.
  defp fake_app_server_with_provider_refusal(frames) do
    init = ~s({"jsonrpc":"2.0","id":1,"result":{"server":{"name":"fake"}}})
    thread = ~s({"jsonrpc":"2.0","id":2,"result":{"thread":{"id":"t1"}}})
    turn = ~s({"jsonrpc":"2.0","id":3,"result":{"turn":{"id":"u1"}}})
    banner = "You've hit your session limit · resets 12:20am (America/Los_Angeles)"
    not_found = "There's an issue with the selected model (claude-nonexistent-model-probe)."

    encode = fn frame -> frame |> Jason.encode!() |> String.replace("'", "\\u0027") end

    progress = encode.(%{"jsonrpc" => "2.0", "method" => "item/progress", "params" => %{"turn_id" => "u1", "delta" => %{"type" => "text", "text" => banner}}})

    created = fn provider_error ->
      item = %{"id" => "i1", "created_at" => 1_789_723_858_759, "type" => "text", "text" => banner}
      item = if provider_error, do: Map.put(item, "provider_error", provider_error), else: item
      encode.(%{"jsonrpc" => "2.0", "method" => "item/created", "params" => %{"turn_id" => "u1", "item" => item}})
    end

    failed = fn provider_error ->
      params = %{"turn_id" => "u1", "error" => "Error: claude exited with code 1"}
      params = if provider_error, do: Map.put(params, "provider_error", provider_error), else: params
      encode.(%{"jsonrpc" => "2.0", "method" => "turn/failed", "params" => params})
    end

    refusal = %{"error" => "rate_limit", "api_error_status" => 429, "message" => banner}
    model = %{"error" => "model_not_found", "api_error_status" => 404, "message" => not_found}

    script =
      "n=0; while IFS= read -r line; do echo \"$line\" >> #{frames}; " <>
        "case \"$line\" in " <>
        "*'\"initialize\"'*) echo '#{init}' ;; " <>
        "*'\"thread/start\"'*) echo '#{thread}' ;; " <>
        "*'\"turn/start\"'*) n=$((n + 1)); echo '#{turn}'; " <>
        "case \"$n\" in " <>
        "1) echo '#{progress}'; echo '#{created.("rate_limit")}'; echo '#{failed.(refusal)}' ;; " <>
        "2) echo '#{failed.(model)}' ;; " <>
        "*) echo '#{progress}'; echo '#{created.(nil)}'; echo '#{failed.(nil)}' ;; " <>
        "esac ;; " <>
        "esac; done"

    File.write!(frames <> ".sh", script)
    "bash #{frames}.sh"
  end

  defp fake_app_server_that_fails_a_turn(frames) do
    init = ~s({"jsonrpc":"2.0","id":1,"result":{"server":{"name":"fake"}}})
    thread = ~s({"jsonrpc":"2.0","id":2,"result":{"thread":{"id":"t1"}}})
    turn = ~s({"jsonrpc":"2.0","id":3,"result":{"turn":{"id":"u1"}}})

    failed =
      ~s({"jsonrpc":"2.0","method":"turn/failed","params":{"error":"Error: claude exited with code 1","turn_id":"u1"}})

    "while IFS= read -r line; do echo \"$line\" >> #{frames}; " <>
      "case \"$line\" in " <>
      "*'\"initialize\"'*) echo '#{init}' ;; " <>
      "*'\"thread/start\"'*) echo '#{thread}' ;; " <>
      "*'\"turn/start\"'*) echo '#{turn}'; echo '#{failed}' ;; " <>
      "esac; done"
  end
end
