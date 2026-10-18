defmodule Aiur.Claude.ProtocolFixtureTest do
  # Characterization guards: deliberately pass on main, detecting future sibling drift.
  use Aiur.TestSupport

  alias Aiur.AgentTools.Catalog
  alias Aiur.AppServer.{Rpc, Transport, TurnLoop, TurnState}
  alias Aiur.Claude.CodingAgent
  alias Aiur.Codex.TurnLoopTestSupport
  alias Aiur.Workflow

  @moduletag :r7_characterization
  @fixture Path.expand("../../fixtures/aiur_claude/protocol-1.1.0.ndjson", __DIR__)
  @peer Path.expand("../../fixtures/aiur_claude/replay.py", __DIR__)
  @issue %{id: "protocol", identifier: "fixture", title: "Protocol fixture"}

  for scenario <- ~w(completed_tool operator interrupt failure_legacy failure_provenance busy unknown legacy_limit) do
    @tag scenario: scenario
    test "replays recorded #{scenario} frames through the real adapter", context do
      {session, frames, rows} = start_replay(context.scenario)
      parent = self()

      on_message = fn message ->
        send(parent, {:protocol_event, message})

        if context.scenario in ["interrupt", "busy"] and get_in(message, [:payload, "method"]) == "turn/started" do
          if context.scenario == "busy" do
            {:ok, request_id} = CodingAgent.send_operator_message(session, %{kind: :text, body: "Operator follow-up"})
            send(parent, {:busy_response, Rpc.with_timeout_response(session.port, request_id, 5_000, "", "Claude")})
          end

          send(parent, {:pause_agent, 91, 4})
        end
      end

      result =
        CodingAgent.run_turn(session, "Protocol fixture prompt", @issue,
          on_message: on_message,
          tool_executor: fn tool, arguments ->
            send(parent, {:protocol_tool, tool, arguments})
            %{"success" => true, "output" => "alert emitted"}
          end
        )

      assert_result(context.scenario, result)
      if context.scenario == "busy", do: assert_received({:busy_response, {:error, {:response_error, %{"code" => -32_003}}}})

      if context.scenario == "operator" do
        assert {:ok, request_id} = CodingAgent.send_operator_message(session, %{kind: :text, body: "Operator follow-up"})
        assert {:ok, %{"turn" => %{"id" => "<turn-2>"}}} = Rpc.with_timeout_response(session.port, request_id, 5_000, "", "Claude")

        state =
          TurnLoopTestSupport.base_state()
          |> Map.merge(%{backend: CodingAgent, active_turn_ids: MapSet.new(), current_turn_id: "<turn-2>", pending_line: "", timeout_ms: 5_000, on_message: on_message})
          |> TurnState.initialize_turn_tracking()

        assert {:ok, :turn_completed} = TurnLoop.receive_loop(session, state)
      end

      if context.scenario == "unknown" do
        assert_received {:protocol_event, %{event: :notification, payload: %{"method" => "future/notification"}}}
      end

      if context.scenario == "completed_tool" do
        assert_received {:protocol_event, %{event: :tool_call_completed}}
        assert_received {:protocol_tool, "emit_alert", %{"name" => "milestone.test", "message" => "hi", "reason" => "r", "needs_attention" => false}}
        assert_received {:protocol_event, %{event: :notification, payload: %{"method" => "provider_account/rate_limits_changed"}}}
        assert_received {:protocol_event, %{event: :notification, payload: %{"method" => "turn/permission_denied"}}}
      end

      assert true = Transport.command(session.port, Jason.encode!(%{"replay" => "done"}) <> "\n")
      assert {:ok, %{"replayed" => replayed}} = Rpc.with_timeout_response(session.port, 999_999, 5_000, "", "Claude")
      assert replayed == length(rows)
      actual = frames |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
      expected = for %{"dir" => "out", "msg" => message} <- rows, do: message
      assert Enum.map(actual, &normalize_request_id/1) == Enum.map(expected, &normalize_request_id/1)
      refute Enum.any?(actual, &(&1["method"] == "turn/steer"))
      CodingAgent.stop_session(session)
    end
  end

  defp assert_result("interrupt", result), do: assert({:paused, %{control: %{request_id: 91, generation: 4}}} = result)
  defp assert_result("legacy_limit", result), do: assert({:paused, %{kind: :usage_limit_exhausted, reason: "rate limit"}} = result)
  defp assert_result("failure_legacy", result), do: assert({:error, {:turn_failed, %{"error" => "Error: claude exited with code 1", "turn_id" => "<turn>"}}} = result)
  defp assert_result("failure_provenance", result), do: assert({:paused, %{kind: :usage_limit_exhausted, provider_error: "rate_limit"}} = result)
  defp assert_result("busy", result), do: assert({:paused, %{control: %{request_id: 91, generation: 4}}} = result)
  defp assert_result(_scenario, result), do: assert({:ok, %{result: :turn_completed}} = result)

  defp normalize_request_id(%{"id" => id, "method" => method} = frame) when method in ["turn/interrupt", "turn/start"] and id != 3,
    do: Map.put(frame, "id", "<req>")

  defp normalize_request_id(frame), do: frame

  defp start_replay(scenario) do
    root = Aiur.TestSupport.tmp_root!("claude-protocol-#{scenario}")
    workspace = Path.join(root, "agent")
    File.mkdir_p!(workspace)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    frames = Path.join(root, "frames.ndjson")
    replay = Path.join(root, "replay.ndjson")

    rows =
      @fixture
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.filter(&(&1["scenario"] == fixture_scenario(scenario)))
      |> Enum.map(&expand(&1, workspace))

    rows = compatibility_rows(rows, scenario)
    assert rows != []
    File.write!(replay, Enum.map_join(rows, "\n", &Jason.encode!/1) <> "\n")
    command = Enum.map_join(["python3", @peer, replay, frames], " ", &Aiur.Shell.escape/1)
    write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "claude", workspace_root: root, command: command, agent_read_timeout_ms: 5_000)
    assert {:ok, session} = CodingAgent.start_session(workspace)
    on_exit(fn -> CodingAgent.stop_session(session) end)
    {session, frames, rows}
  end

  defp fixture_scenario("unknown"), do: "completed_tool"
  defp fixture_scenario("legacy_limit"), do: "failure_legacy"
  defp fixture_scenario(scenario), do: scenario

  # Synthetic forward-compatibility probes are kept out of the sibling recording.
  defp compatibility_rows(rows, "unknown") do
    List.insert_at(rows, -2, %{"dir" => "in", "msg" => %{"jsonrpc" => "2.0", "method" => "future/notification", "params" => %{}}})
  end

  defp compatibility_rows(rows, "legacy_limit") do
    Enum.map(rows, fn
      %{"msg" => %{"method" => "turn/failed"}} = row -> put_in(row, ["msg", "params", "error"], "rate limit")
      row -> row
    end)
  end

  defp compatibility_rows(rows, _scenario), do: rows

  defp expand("<workspace>", workspace), do: workspace
  defp expand("<client-version>", _workspace), do: Mix.Project.config()[:version]
  defp expand("<dynamic-tools>", _workspace), do: Catalog.specs()
  defp expand(value, workspace) when is_map(value), do: Map.new(value, fn {key, item} -> {key, expand(item, workspace)} end)
  defp expand(value, workspace) when is_list(value), do: Enum.map(value, &expand(&1, workspace))
  defp expand(value, _workspace), do: value
end
