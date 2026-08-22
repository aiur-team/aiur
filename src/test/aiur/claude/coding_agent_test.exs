defmodule Aiur.Claude.CodingAgentWorkspaceTest do
  use Aiur.TestSupport

  alias Aiur.AgentRunner.ToolExecutor
  alias Aiur.Claude.CodingAgent, as: ClaudeAgent
  alias Aiur.Codex.DynamicTool
  alias Aiur.CodingAgent
  alias Aiur.Issue
  alias Aiur.Workflow

  test "spawned claude shell receives workspace, configured base, and launch vars" do
    root = Path.join(System.tmp_dir!(), "aiur_claude_env_#{System.pid()}-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "agent-1")
    File.mkdir_p!(workspace)
    marker = Path.join(workspace, "env_marker")
    on_exit(fn -> File.rm_rf(root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_kind: "claude",
      workspace_root: root,
      tracker_base_branch: "integration",
      # The fake app-server records the workspace variables the spawned shell sees,
      # then idles so the initialize handshake reads back nothing and
      # start_session returns a timeout error. The marker is written first.
      command: "env | grep -E '^(AIUR_AGENT_WORKSPACE|AIUR_BASE_BRANCH|CLAUDE_CODE_ENABLE_TELEMETRY)=' | sort | sed 's/^[^=]*=//' > #{marker}; sleep 2",
      agent_read_timeout_ms: 300
    )

    assert {:error, _reason} =
             ClaudeAgent.start_session(workspace,
               telemetry_launch: %{env: [{"CLAUDE_CODE_ENABLE_TELEMETRY", "1"}]}
             )

    assert File.exists?(marker)
    assert String.split(File.read!(marker), "\n", trim: true) == [workspace, "integration", "1"]
  end

  test "turn/start carries the configured model and completes a turn" do
    root = Path.join(System.tmp_dir!(), "aiur_claude_model_#{System.pid()}-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "agent-1")
    File.mkdir_p!(workspace)
    frames = Path.join(workspace, "frames.jsonl")
    on_exit(fn -> File.rm_rf(root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_kind: "claude",
      workspace_root: root,
      claude_model: "claude-opus-4-8",
      command: fake_app_server(frames)
    )

    issue = %{id: 1, identifier: "test:1", title: "demo"}

    assert {:ok, session} = ClaudeAgent.start_session(workspace)
    assert session.metadata.agent_process_group_id == String.to_integer(session.metadata.provider_pid)
    assert {:ok, result} = ClaudeAgent.run_turn(session, "do the thing", issue)
    assert result.result == :turn_completed
    ClaudeAgent.stop_session(session)

    turn_frame =
      frames
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.find(&(&1["method"] == "turn/start"))

    assert turn_frame["params"]["model"] == "claude-opus-4-8"

    thread_frame =
      frames
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.find(&(&1["method"] == "thread/start"))

    advertised_tool_names =
      thread_frame
      |> get_in(["params", "dynamicTools"])
      |> Enum.map(& &1["name"])
      |> Enum.sort()

    expected_tool_names =
      DynamicTool.tool_specs()
      |> Enum.map(& &1["name"])
      |> Enum.sort()

    assert advertised_tool_names == expected_tool_names
  end

  test "rate-limit notifications ingest through the Claude meter adapter and log only a redacted marker" do
    root = Path.join(System.tmp_dir!(), "aiur_claude_meter_#{System.pid()}-#{System.unique_integer([:positive])}")
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

  test "tool calls execute through the injected tool executor" do
    root = Path.join(System.tmp_dir!(), "aiur_claude_tool_call_#{System.pid()}-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "agent-1")
    File.mkdir_p!(workspace)
    frames = Path.join(workspace, "frames.jsonl")
    on_exit(fn -> File.rm_rf(root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_kind: "claude",
      workspace_root: root,
      command: fake_app_server_with_tool_call(frames)
    )

    issue = %{id: 1, identifier: "test:tool", title: "tool-call"}
    test_pid = self()

    tool_executor = fn tool, arguments ->
      send(test_pid, {:tool_called, tool, arguments})

      %{
        "success" => true,
        "contentItems" => [
          %{"type" => "inputText", "text" => ~s({"ok":true})}
        ]
      }
    end

    assert {:ok, session} = ClaudeAgent.start_session(workspace)

    assert {:ok, %{result: :turn_completed}} =
             ClaudeAgent.run_turn(session, "emit progress", issue, tool_executor: tool_executor)

    ClaudeAgent.stop_session(session)

    assert_received {:tool_called, "emit_event", %{"name" => "progress", "message" => "40%", "payload" => %{"percent" => 40}}}

    response_frame =
      frames
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.find(&(Map.get(&1, "id") == 101))

    assert get_in(response_frame, ["result", "success"]) == true
    assert get_in(response_frame, ["result", "output"]) == ~s({"ok":true})
  end

  @tag :tmp_dir
  test "oversized tool calls spill through the Claude adapter", %{tmp_dir: tmp_dir} do
    workspace = Path.join(tmp_dir, "agent-1")
    File.mkdir_p!(workspace)
    {_output, 0} = System.cmd("git", ["init", "-q"], cd: workspace)
    frames = Path.join(workspace, "frames.jsonl")

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_kind: "claude",
      workspace_root: tmp_dir,
      command: fake_app_server_with_tool_call(frames)
    )

    issue = %{id: 1, identifier: "test:large-tool", title: "large-tool"}
    output = String.duplicate("x", 110 * 1024)
    tool_executor = fn _tool, _arguments -> %{"success" => true, "output" => output} end

    assert {:ok, session} = ClaudeAgent.start_session(workspace)
    assert {:ok, %{result: :turn_completed}} = ClaudeAgent.run_turn(session, "emit progress", issue, tool_executor: tool_executor)
    ClaudeAgent.stop_session(session)

    response_frame =
      frames
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.find(&(Map.get(&1, "id") == 101))

    assert [path] =
             Regex.run(~r/saved as JSON to (.+)\. Read the file/, get_in(response_frame, ["result", "output"]), capture: :all_but_first)

    assert Jason.decode!(File.read!(path))["output"] == output
  end

  test "tool call failures and unsupported calls are reported" do
    root = Path.join(System.tmp_dir!(), "aiur_claude_tool_errors_#{System.pid()}-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "agent-1")
    File.mkdir_p!(workspace)
    frames = Path.join(workspace, "frames.jsonl")
    on_exit(fn -> File.rm_rf(root) end)

    failed_call =
      ~s({"jsonrpc":"2.0","id":101,"method":"item/tool/call","params":{"tool":"emit_alert","arguments":{"name":"phase.work.start","message":"starting"}}})

    unsupported_call = ~s({"jsonrpc":"2.0","id":102,"method":"item/tool/call","params":{}})

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_kind: "claude",
      workspace_root: root,
      command: fake_app_server_with_two_tool_calls(frames, failed_call, unsupported_call)
    )

    issue = %{id: 1, identifier: "test:tool-errors", title: "tool-errors"}
    test_pid = self()

    on_message = fn message -> send(test_pid, {:agent_message, message}) end

    tool_executor = fn tool, arguments ->
      send(test_pid, {:tool_called, tool, arguments, ToolExecutor.invocation_id()})
      %{"success" => false, "error" => "not available"}
    end

    assert {:ok, session} = ClaudeAgent.start_session(workspace)

    assert {:ok, %{result: :turn_completed}} =
             ClaudeAgent.run_turn(session, "emit progress", issue,
               on_message: on_message,
               tool_executor: tool_executor
             )

    ClaudeAgent.stop_session(session)

    assert_received {:tool_called, "emit_alert", %{"name" => "phase.work.start", "message" => "starting"}, 101}
    assert_received {:tool_called, nil, %{}, 102}
    assert_received {:agent_message, %{event: :tool_call_failed, payload: %{"params" => %{"tool" => "emit_alert"}}}}
    assert_received {:agent_message, %{event: :unsupported_tool_call, payload: %{"params" => %{}}}}

    response_ids =
      frames
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.map(&Map.get(&1, "id"))

    assert 101 in response_ids
    assert 102 in response_ids
  end

  test "two concurrent claude sessions run distinct models: config default vs issue tag" do
    root = Path.join(System.tmp_dir!(), "aiur_claude_multi_#{System.pid()}-#{System.unique_integer([:positive])}")
    config_ws = Path.join(root, "config-agent")
    tag_ws = Path.join(root, "tag-agent")
    File.mkdir_p!(config_ws)
    File.mkdir_p!(tag_ws)
    frames = Path.join(root, "frames.jsonl")
    on_exit(fn -> File.rm_rf(root) end)

    # Global claude.model default. The first session inherits it; the second
    # carries a per-issue model resolved from a `model:claude-opus-4-8` tag,
    # which must override the config default on the wire. Both sessions spawn
    # the same fake app-server (claude.command is global), recording every
    # frame to one file tagged by threadId so we can tell them apart.
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_kind: "claude",
      workspace_root: root,
      claude_model: "claude-sonnet-4-6",
      command: fake_app_server(frames)
    )

    tag_model = CodingAgent.model_for(%Issue{labels: ["model:claude-opus-4-8"]})
    assert tag_model == "opus-4-8"

    config_issue = %{id: 1, identifier: "config:1", title: "config-default"}
    tag_issue = %{id: 2, identifier: "tag:1", title: "tag-override"}

    # Both sessions are started (both fake app-servers spawned and alive)
    # before either turn runs, so two claude backends are live at once. Turns
    # are driven from this process because it owns the ports' message stream.
    assert {:ok, config_session} = ClaudeAgent.start_session(config_ws)
    assert {:ok, tag_session} = ClaudeAgent.start_session(tag_ws, model: tag_model)

    assert {:ok, %{result: :turn_completed}} = ClaudeAgent.run_turn(config_session, "go", config_issue)
    assert {:ok, %{result: :turn_completed}} = ClaudeAgent.run_turn(tag_session, "go", tag_issue)

    ClaudeAgent.stop_session(config_session)
    ClaudeAgent.stop_session(tag_session)

    turn_models =
      frames
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.filter(&(&1["method"] == "turn/start"))
      |> Enum.map(&get_in(&1, ["params", "model"]))
      |> Enum.sort()

    # Both claude models were sent on the wire in the same run: the config
    # default for the untagged session, the tag override for the other.
    assert turn_models == ["claude-sonnet-4-6", "opus-4-8"]
  end

  test "an operator message after the transport is torn down fails cleanly, never crashing the caller" do
    # Regression for #708/#699: a write to the agent backend after its stdio
    # transport closed used to raise `ArgumentError` from `Port.command/2` and
    # crash the turn — the Elixir-side mirror of the unguarded-stdout EPIPE that
    # killed the Node agent. Delivering a queued operator message onto a
    # torn-down port must now fail with `{:error, :port_closed}` instead.
    root = Path.join(System.tmp_dir!(), "aiur_claude_port_closed_#{System.pid()}-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "agent-1")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_kind: "claude",
      workspace_root: root,
      command: fake_app_server(Path.join(workspace, "frames.jsonl"))
    )

    assert {:ok, session} = ClaudeAgent.start_session(workspace)

    # Close the agent's stdio out from under the caller, mirroring the aiur peer
    # closing the agent's stdout read-end mid-session.
    Port.close(session.port)

    assert {:error, :port_closed} =
             ClaudeAgent.send_operator_message(session, %{kind: :text, body: "queued operator message"})
  end

  test "a backend that dies mid-turn ends the turn with a clean port_exit, not an EPIPE crash" do
    # Regression for #708/#699: when the backend's stdout closes mid-turn the
    # turn must unwind to a clean `{:port_exit, N}` error (and emit
    # `:turn_ended_with_error` carrying that tuple reason — the same
    # `{:port_exit, N}` shape the AgentEventLog encoder fix now persists), rather
    # than crash the receive loop.
    root = Path.join(System.tmp_dir!(), "aiur_claude_port_exit_#{System.pid()}-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "agent-1")
    File.mkdir_p!(workspace)
    frames = Path.join(workspace, "frames.jsonl")
    on_exit(fn -> File.rm_rf(root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_kind: "claude",
      workspace_root: root,
      command: fake_app_server_that_exits_after_turn_start(frames)
    )

    issue = %{id: 1, identifier: "test:port-exit", title: "port-exit"}
    test_pid = self()
    on_message = fn message -> send(test_pid, {:agent_message, message}) end

    assert {:ok, session} = ClaudeAgent.start_session(workspace)

    assert {:error, {:port_exit, 1}} =
             ClaudeAgent.run_turn(session, "do the thing", issue, on_message: on_message)

    assert_received {:agent_message, %{event: :turn_ended_with_error, reason: {:port_exit, 1}}}
  end

  # Minimal bash stand-in for the Claude app-server: records every frame
  # it receives to `frames`, and replies to the fixed initialize(1) /
  # thread/start(2) / turn/start(3) request ids so a full turn completes.
  # Single line + echo (no backslash escapes) so it survives YAML scalar
  # round-tripping in the generated config.yaml file.
  defp fake_app_server(frames) do
    init = ~s({"jsonrpc":"2.0","id":1,"result":{"server":{"name":"fake"}}})
    thread = ~s({"jsonrpc":"2.0","id":2,"result":{"thread":{"id":"t1"}}})
    turn = ~s({"jsonrpc":"2.0","id":3,"result":{"turn":{"id":"u1"}}})
    completed = ~s({"jsonrpc":"2.0","method":"turn/completed","params":{"turn":{"status":"completed"}}})

    "while IFS= read -r line; do echo \"$line\" >> #{frames}; " <>
      "case \"$line\" in " <>
      "*'\"initialize\"'*) echo '#{init}' ;; " <>
      "*'\"thread/start\"'*) echo '#{thread}' ;; " <>
      "*'\"turn/start\"'*) echo '#{turn}'; echo '#{completed}' ;; " <>
      "esac; done"
  end

  defp fake_app_server_with_tool_call(frames) do
    init = ~s({"jsonrpc":"2.0","id":1,"result":{"server":{"name":"fake"}}})
    thread = ~s({"jsonrpc":"2.0","id":2,"result":{"thread":{"id":"t1"}}})
    turn = ~s({"jsonrpc":"2.0","id":3,"result":{"turn":{"id":"u1"}}})

    tool_call =
      ~s({"jsonrpc":"2.0","id":101,"method":"item/tool/call","params":{"name":"emit_event","callId":"call-101","threadId":"t1","turnId":"u1","arguments":{"name":"progress","message":"40%","payload":{"percent":40}}}})

    completed = ~s({"jsonrpc":"2.0","method":"turn/completed","params":{"turn":{"status":"completed"}}})

    "while IFS= read -r line; do echo \"$line\" >> #{frames}; " <>
      "case \"$line\" in " <>
      "*'\"initialize\"'*) echo '#{init}' ;; " <>
      "*'\"thread/start\"'*) echo '#{thread}' ;; " <>
      "*'\"turn/start\"'*) echo '#{turn}'; echo '#{tool_call}' ;; " <>
      "*'\"id\":101'*) echo '#{completed}' ;; " <>
      "esac; done"
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

  # Replies to the turn/start request id so the turn is accepted, then exits
  # non-zero — the agent backend dying (closing its stdout) mid-turn.
  defp fake_app_server_that_exits_after_turn_start(frames) do
    init = ~s({"jsonrpc":"2.0","id":1,"result":{"server":{"name":"fake"}}})
    thread = ~s({"jsonrpc":"2.0","id":2,"result":{"thread":{"id":"t1"}}})
    turn = ~s({"jsonrpc":"2.0","id":3,"result":{"turn":{"id":"u1"}}})

    "while IFS= read -r line; do echo \"$line\" >> #{frames}; " <>
      "case \"$line\" in " <>
      "*'\"initialize\"'*) echo '#{init}' ;; " <>
      "*'\"thread/start\"'*) echo '#{thread}' ;; " <>
      "*'\"turn/start\"'*) echo '#{turn}'; exit 1 ;; " <>
      "esac; done"
  end

  defp fake_app_server_with_two_tool_calls(frames, first_tool_call, second_tool_call) do
    init = ~s({"jsonrpc":"2.0","id":1,"result":{"server":{"name":"fake"}}})
    thread = ~s({"jsonrpc":"2.0","id":2,"result":{"thread":{"id":"t1"}}})
    turn = ~s({"jsonrpc":"2.0","id":3,"result":{"turn":{"id":"u1"}}})
    completed = ~s({"jsonrpc":"2.0","method":"turn/completed","params":{"turn":{"status":"completed"}}})

    "while IFS= read -r line; do echo \"$line\" >> #{frames}; " <>
      "case \"$line\" in " <>
      "*'\"initialize\"'*) echo '#{init}' ;; " <>
      "*'\"thread/start\"'*) echo '#{thread}' ;; " <>
      "*'\"turn/start\"'*) echo '#{turn}'; echo '#{first_tool_call}' ;; " <>
      "*'\"id\":101'*) echo '#{second_tool_call}' ;; " <>
      "*'\"id\":102'*) echo '#{completed}' ;; " <>
      "esac; done"
  end
end
