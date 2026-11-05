Code.require_file(Path.expand("../orchestrator/control_cli/fixture.exs", __DIR__))

defmodule Aiur.OpenAICompat.LiveTurnRowTest do
  # The fleet rows come from the shared Orchestrator singleton, which the
  # status-CLI fixture injects state into, so this case cannot be async.
  use Aiur.TestSupport
  use Aiur.TestSupport.OpenAICompatAgent

  import ExUnit.CaptureIO

  alias Aiur.AgentRunner.MessageHandler
  alias Aiur.Issue
  alias Aiur.OpenAICompat.{CodingAgent, LiveTurn}
  alias Aiur.Orchestrator.ControlCLI.TestFixture
  alias Aiur.Orchestrator.StatusCLI
  alias Aiur.Orchestrator.StatusCLI.AgentsTable
  alias Aiur.Orchestrator.StatusReport.RowFacts

  import TestFixture, except: [setup: 1]

  setup context do
    TestFixture.setup(context)
  end

  test "a fake OpenAI-compatible turn reports a live turn and its activity (#7506)",
       %{orchestrator: orchestrator, workspace: workspace} do
    issue = %Issue{id: "gid-7506", identifier: "repo#7506", title: "live turn"}

    starting =
      "gid-7506"
      |> running_entry("repo#7506", :working)
      |> Map.merge(%{session_id: nil, last_codex_event: nil, last_codex_message: nil, last_codex_timestamp: nil})

    # Exactly what dispatch admits for one of these backends: a live worker
    # whose provider has not reported a session or a turn yet.
    :sys.replace_state(orchestrator, fn state -> %{state | running: %{"gid-7506" => starting}} end)
    assert RowFacts.startup_work_state(starting) == :starting

    parent = self()
    {:ok, session} = CodingAgent.start_session(workspace, session_opts(parent))
    handler = MessageHandler.build(orchestrator, issue, workspace, nil, "deepseek")

    assert {:ok, %{result: :turn_completed}} =
             CodingAgent.run_turn(session, "Inspect the workspace", issue, on_message: fn message -> observe(orchestrator, parent, handler, message) end)

    # The row `aiur agents`, the dashboard and the Stream Deck all read: the
    # same facts the status report derives the live turn from.
    assert_receive {:turn_update, :tool_call, entry}, 2_000
    assert entry.session_id == "#{session.thread_id}-1"
    assert RowFacts.startup_work_state(entry) == :working
    assert AgentsTable.agent_activity(entry) == "read sample.txt"

    finished = :sys.get_state(orchestrator).running["gid-7506"]
    assert finished.last_codex_event == :turn_completed
    assert %DateTime{} = finished.last_codex_timestamp

    output = capture_io(fn -> StatusCLI.agents() end)

    assert output =~ ~r/#7506\s+working/
    assert output =~ "turn completed"
    refute output =~ "(starting provider; no live turn yet)"

    assert {:ok, :cleanup_proven} = CodingAgent.stop_session(session)
  end

  describe "identity/1" do
    test "keeps one turn's identity distinct from the next" do
      state = %{thread_id: "openai-compat-7", turn_index: 2}
      identity = LiveTurn.identity(state)

      assert identity == %{session_id: "openai-compat-7-2", thread_id: "openai-compat-7", turn_id: "2"}
      assert LiveTurn.started(identity) == Map.put(identity, :event, :session_started)
      assert %{event: :turn_completed, session_id: "openai-compat-7-2", payload: %{id: "req-9"}} = LiveTurn.completed(%{id: "req-9"}, identity)
    end
  end

  defp observe(orchestrator, parent, handler, message) do
    handler.(message)

    if match?(%{event: :tool_call}, message) do
      entry = :sys.get_state(orchestrator).running["gid-7506"]
      send(parent, {:turn_update, :tool_call, entry})
    end

    :ok
  end

  defp session_opts(parent) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    [
      backend: "deepseek",
      instance: instance(%{}),
      api_key_fetcher: fn "TEST_KEY" -> "super-secret" end,
      request_fun: fn request ->
        send(parent, {:request, request})

        case Agent.get_and_update(counter, fn n -> {n, n + 1} end) do
          0 -> response(completion_with_tool_call())
          _second -> response(completion_with_text())
        end
      end
    ]
  end

  defp completion_with_tool_call do
    %{
      "id" => "req-1",
      "choices" => [
        %{
          "finish_reason" => "tool_calls",
          "message" => %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              %{
                "id" => "call-1",
                "type" => "function",
                "function" => %{"name" => "read_file", "arguments" => ~s({"path":"sample.txt"})}
              }
            ]
          }
        }
      ],
      "usage" => %{"prompt_tokens" => 20, "completion_tokens" => 5, "total_tokens" => 25}
    }
  end

  defp completion_with_text do
    %{
      "id" => "req-2",
      "choices" => [
        %{
          "finish_reason" => "stop",
          "message" => %{"role" => "assistant", "content" => "The workspace contains the expected evidence."}
        }
      ],
      "usage" => %{"prompt_tokens" => 40, "completion_tokens" => 8, "total_tokens" => 48}
    }
  end
end
