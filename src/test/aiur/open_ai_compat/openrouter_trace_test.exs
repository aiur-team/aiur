defmodule Aiur.OpenAICompat.OpenRouterTraceTest do
  use ExUnit.Case, async: false
  use Aiur.TestSupport.OpenAICompatAgent
  alias Aiur.OpenAICompat.CodingAgent
  alias Aiur.TrackerIdentity

  setup do
    previous = System.get_env("AIUR_INSTANCE_KEY")
    System.put_env("AIUR_INSTANCE_KEY", "trace-test")

    on_exit(fn ->
      if previous, do: System.put_env("AIUR_INSTANCE_KEY", previous), else: System.delete_env("AIUR_INSTANCE_KEY")
    end)

    :ok
  end

  test "identity follows ticket, dispatch, turn and tool round without private content", %{workspace: workspace} do
    {:ok, queue} = Agent.start_link(fn -> [tool_response(), done_response(), done_response()] end)
    session = start(workspace, queue_fun(queue, self()), "openrouter", %{"openrouter_trace" => true})
    assert <<"openai-compat-", uuid::binary>> = session.thread_id
    assert {:ok, ^uuid} = Ecto.UUID.cast(uuid)
    identity = %TrackerIdentity{status: :joinable, kind: :github, owner: "aiur-team", repository: "aiur", provider_id: "node-1440", identifier: "1440", reason: nil}
    ticket = %{issue() | tracker_identity: identity, title: "PRIVATE TITLE", description: "PRIVATE DESCRIPTION", labels: ["complexity:2"]}
    assert {:ok, _} = CodingAgent.run_turn(session, "PRIVATE PROMPT", ticket, [])
    assert {:ok, _} = CodingAgent.run_turn(session, "PRIVATE FOLLOWUP", ticket, [])
    [first, second, third] = collect_requests(3) |> Enum.map(& &1.json)
    assert first["session_id"] == "github:aiur-team/aiur#1440"
    assert first["user"] == first["trace"]["environment"] <> "/test-account"

    assert first["trace"] == %{
             "trace_id" => session.thread_id <> ":1",
             "trace_name" => "#1440 turn 1",
             "generation_name" => "round 1",
             "thread_id" => session.thread_id,
             "dispatch_id" => session.thread_id,
             "issue_identifier" => "1440",
             "backend" => "openrouter",
             "model" => "deepseek-v4-flash",
             "complexity" => "2",
             "environment" => "trace-test",
             "release" => Aiur.Config.Overrides.build_version()
           }

    assert second["trace"]["trace_id"] == first["trace"]["trace_id"]
    assert second["trace"]["generation_name"] == "round 2"
    assert third["trace"]["trace_id"] == session.thread_id <> ":2"
    assert third["trace"]["generation_name"] == "round 1"
    encoded = Jason.encode!(Map.take(first, ["session_id", "user", "trace"]))
    for private <- [workspace, ticket.title, ticket.description, "PRIVATE PROMPT", "PRIVATE FOLLOWUP"], do: refute(String.contains?(encoded, private))
    assert {:ok, :cleanup_proven} = CodingAgent.stop_session(session)
    Agent.stop(queue)

    # Pair suppression with the positive request above so absence alone cannot pass.
    for {backend, quirks} <- [{"openrouter", %{openrouter_trace: false}}, {"kimi", %{openrouter_trace: true}}, {"kimi", %{}}] do
      session = start(workspace, capture(), backend, quirks)
      assert {:ok, _} = CodingAgent.run_turn(session, "prompt", issue(), [])
      [request] = collect_requests(1)
      assert Map.take(request.json, ["session_id", "user", "trace"]) == %{}
      assert {:ok, :cleanup_proven} = CodingAgent.stop_session(session)
    end
  end

  test "long identifiers respect request field limits", %{workspace: workspace} do
    session = start(workspace, capture(), "openrouter", %{openrouter_trace: true}, String.duplicate("a", 200))
    ticket = %{issue() | identifier: String.duplicate("界", 400)}
    assert {:ok, _} = CodingAgent.run_turn(session, "prompt", ticket, [])
    [request] = collect_requests(1)
    assert String.length(request.json["session_id"]) == 256
    assert String.length(request.json["user"]) == 128
    assert String.valid?(request.json["session_id"])
    assert {:ok, :cleanup_proven} = CodingAgent.stop_session(session)
  end

  test "a failed turn consumes its trace ID", %{workspace: workspace} do
    {:ok, queue} = Agent.start_link(fn -> [{:ok, %{status: 401, body: %{}, headers: %{}}}, done_response()] end)
    session = start(workspace, queue_fun(queue, self()), "openrouter", %{openrouter_trace: true})
    assert {:error, :unauthorized} = CodingAgent.run_turn(session, "first", issue(), [])
    assert {:ok, _} = CodingAgent.run_turn(session, "second", issue(), [])
    [first, second] = collect_requests(2)
    assert first.json["trace"]["trace_id"] == session.thread_id <> ":1"
    assert second.json["trace"]["trace_id"] == session.thread_id <> ":2"
    assert first.json["session_id"] == second.json["session_id"]
    assert {:ok, :cleanup_proven} = CodingAgent.stop_session(session)
    Agent.stop(queue)
  end

  test "built-in OpenRouter tracing is enabled by default", %{workspace: workspace} do
    assert {:ok, session} = CodingAgent.start_session(workspace, backend: "openrouter", model: "vendor/model", backend_config: %{}, api_key_fetcher: fn _ -> "test" end, request_fun: capture())
    assert {:ok, _} = CodingAgent.run_turn(session, "prompt", issue(), [])
    [request] = collect_requests(1)
    assert request.json["session_id"] == "unscoped:1440"
    assert {:ok, :cleanup_proven} = CodingAgent.stop_session(session)

    assert {:ok, disabled} =
             CodingAgent.start_session(workspace,
               backend: "openrouter",
               model: "vendor/model",
               backend_config: %{"quirks" => %{"openrouter_trace" => false}},
               api_key_fetcher: fn _ -> "test" end,
               request_fun: capture()
             )

    assert disabled.thread_id != session.thread_id
    assert {:ok, _} = CodingAgent.run_turn(disabled, "prompt", issue(), [])
    [request] = collect_requests(1)
    assert Map.take(request.json, ["session_id", "user", "trace"]) == %{}
    assert {:ok, :cleanup_proven} = CodingAgent.stop_session(disabled)
  end

  defp start(workspace, request_fun, backend, quirks, account \\ "test-account") do
    assert {:ok, session} =
             CodingAgent.start_session(workspace,
               backend: backend,
               instance: %{instance([]) | quirks: quirks},
               backend_config: %{},
               account_name: account,
               api_key_fetcher: fn _ -> "test" end,
               request_fun: request_fun
             )

    session
  end

  defp capture do
    parent = self()

    fn request ->
      send(parent, {:request, request})
      done_response()
    end
  end

  defp done_response, do: response(%{"id" => "done", "choices" => [%{"finish_reason" => "stop", "message" => %{"role" => "assistant", "content" => "Done"}}]})

  defp tool_response,
    do:
      response(%{
        "id" => "tool",
        "choices" => [
          %{
            "finish_reason" => "tool_calls",
            "message" => %{"role" => "assistant", "tool_calls" => [%{"id" => "call", "function" => %{"name" => "read_file", "arguments" => "{\"path\":\"sample.txt\"}"}}]}
          }
        ]
      })
end
