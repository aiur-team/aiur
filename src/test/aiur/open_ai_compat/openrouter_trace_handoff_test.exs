defmodule Aiur.OpenAICompat.OpenRouterTraceHandoffTest do
  use ExUnit.Case, async: false
  use Aiur.TestSupport.OpenAICompatAgent

  alias Aiur.OpenAICompat.{CodingAgent, Handoff}

  test "a restored interrupted turn retains ticket, trace and next round identity", %{workspace: workspace} do
    parent = self()
    {:ok, queue} = Agent.start_link(fn -> [tool_response(), done_response()] end)

    request_fun = fn request ->
      send(parent, {:request, request})
      response = Agent.get_and_update(queue, fn [next | rest] -> {next, rest} end)
      if request.json["trace"]["generation_name"] == "round 1", do: send(self(), :handoff_hold)
      response
    end

    opts = session_opts(request_fun)
    assert {:ok, session} = CodingAgent.start_session(workspace, opts)
    session = Map.put(session, :backend, "openrouter")

    turn =
      Task.async(fn ->
        Process.put(:handoff_turn_context, %{workspace: workspace, issue: issue(), opts: Keyword.put(opts, :workspace, workspace), worker_host: nil})
        CodingAgent.run_turn(session, "Inspect", issue(), [])
      end)

    assert_receive {:request, first}, 5_000
    ref = make_ref()
    send(turn.pid, {:handoff_snapshot, self(), ref})
    assert_receive {^ref, {:ok, record}}, 5_000
    assert {:ok, saved} = Handoff.provider_state(record)
    assert saved["interrupted"]
    assert saved["trace_round"] == 2
    refute Jason.encode!(saved) =~ "private-api-key"
    send(turn.pid, :handoff_abort)
    assert {:ok, _} = Task.await(turn, 5_000)
    assert_receive {:request, _old_completion}, 1_000
    assert {:ok, :cleanup_proven} = CodingAgent.stop_session(session)

    restore_opts =
      session_opts(fn request ->
        send(parent, {:request, request})
        done_response()
      end)

    assert {:ok, restored} = CodingAgent.adopt_handoff_session(record, restore_opts)
    assert {:ok, _} = CodingAgent.resume_handoff_turn(restored, [])
    assert_receive {:request, resumed}, 1_000
    assert resumed.json["session_id"] == first.json["session_id"]
    assert resumed.json["session_id"] == "unscoped:1440"
    assert resumed.json["user"] == first.json["user"]
    assert resumed.json["trace"]["trace_id"] == session.thread_id <> ":1"
    assert resumed.json["trace"]["trace_id"] == first.json["trace"]["trace_id"]
    assert resumed.json["trace"]["generation_name"] == "round 2"
    assert {:ok, :cleanup_proven} = CodingAgent.stop_session(restored)
    Agent.stop(queue)
  end

  defp session_opts(request_fun) do
    [backend: "openrouter", model: "vendor/model", backend_config: %{}, api_key_fetcher: fn _ -> "private-api-key" end, request_fun: request_fun]
  end

  defp done_response,
    do: response(%{"id" => "done", "choices" => [%{"finish_reason" => "stop", "message" => %{"role" => "assistant", "content" => "Done"}}]})

  defp tool_response do
    response(%{
      "id" => "tool",
      "choices" => [
        %{"finish_reason" => "tool_calls", "message" => %{"role" => "assistant", "tool_calls" => [%{"id" => "call", "function" => %{"name" => "read_file", "arguments" => ~s({"path":"sample.txt"})}}]}}
      ]
    })
  end
end
