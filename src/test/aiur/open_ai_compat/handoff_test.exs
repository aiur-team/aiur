defmodule Aiur.OpenAICompat.HandoffTest do
  use ExUnit.Case, async: false
  use Aiur.TestSupport.OpenAICompatAgent

  alias Aiur.AgentRunner.Handoff, as: RunnerHandoff
  alias Aiur.Handoff.Compatibility
  alias Aiur.OpenAICompat.{CodingAgent, Handoff, Session}

  @secret "handoff-secret-key"

  defp session_opts(parent, responses) do
    queue = start_response_queue(responses)

    [
      backend: "kimi",
      instance: instance(%{}),
      api_key_fetcher: fn _env -> @secret end,
      request_fun: queue_fun(queue, parent)
    ]
  end

  # A provider whose own config names no model — the live OpenRouter registry
  # entry. The dispatch-time route (`agent.priority: ["openrouter:<model>"]`)
  # named the model once, in the session options; nothing else carries it.
  defp route_only_opts(parent, responses, model) do
    queue = start_response_queue(responses)

    [
      backend: "openrouter",
      api_key_fetcher: fn _env -> @secret end,
      request_fun: queue_fun(queue, parent)
    ]
    |> maybe_put_model(model)
  end

  defp maybe_put_model(opts, model) when is_binary(model), do: Keyword.put(opts, :model, model)
  defp maybe_put_model(opts, _model), do: opts

  defp start_response_queue(responses) do
    {:ok, queue} = Agent.start_link(fn -> responses end)
    queue
  end

  # A provider double whose responses answer in order, except an element tagged
  # `{:gated, response}`: that request announces itself with its own pid and waits
  # for the test's `:release`, so a handoff can land while a transport call is
  # genuinely in flight — the case a busy OpenRouter worker presents to a
  # keep-agents preflight (#7564).
  defp gated_queue_fun(queue, parent) do
    fn request ->
      send(parent, {:gated_request, request, self()})
      next_response(queue)
    end
  end

  defp next_response(queue) do
    next = Agent.get_and_update(queue, &shift_response/1)

    case next do
      {:gated, response} -> receive do: (:release -> response)
      response -> response
    end
  end

  defp shift_response([next | rest]), do: {next, rest}
  defp shift_response([]), do: {{:error, :unexpected_request}, []}

  defp tool_call_response do
    response(%{
      "id" => "req-handoff-1",
      "choices" => [
        %{
          "finish_reason" => "tool_calls",
          "message" => %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              %{
                "id" => "call-handoff-1",
                "type" => "function",
                "function" => %{"name" => "read_file", "arguments" => ~s({"path":"sample.txt"})}
              }
            ]
          }
        }
      ]
    })
  end

  defp final_response do
    response(%{
      "id" => "req-handoff-2",
      "choices" => [%{"finish_reason" => "stop", "message" => %{"role" => "assistant", "content" => "Resumed and finished."}}]
    })
  end

  defp turn_opts(parent) do
    [on_message: fn event -> send(parent, {:event, event}) end]
  end

  defp in_daemon_record(workspace, provider_state) do
    %{
      "workspace" => workspace,
      "backend" => "kimi",
      "transport" => %{"kind" => "in_daemon", "provider_state" => Handoff.encode_provider_state(provider_state)}
    }
  end

  defp completed_session(workspace, parent) do
    opts = session_opts(parent, [tool_call_response(), final_response()])
    {:ok, session} = CodingAgent.start_session(workspace, opts)
    session = Map.put(session, :backend, "kimi")
    {:ok, %{result: :turn_completed}} = CodingAgent.run_turn(session, "Inspect the workspace", issue(), turn_opts(parent))
    flush_requests()
    {session, opts}
  end

  defp prompt_count(messages, prompt) do
    Enum.count(messages, &(&1["role"] == "user" and &1["content"] == prompt))
  end

  # A completed turn leaves its own request messages in the test mailbox; clear
  # them so an assertion about the *next* request cannot read a stale one.
  defp flush_requests do
    receive do
      {:request, _request} -> flush_requests()
    after
      0 -> :ok
    end
  end

  test "a snapshot carries the conversation and never the resolved credentials", %{workspace: workspace} do
    parent = self()
    {session, _opts} = completed_session(workspace, parent)

    assert {:ok, provider_state} = Handoff.snapshot(session)
    assert provider_state["interrupted"] == false
    assert provider_state["thread_id"] == session.thread_id

    assert Enum.any?(provider_state["messages"], &(&1["role"] == "user" and &1["content"] == "Inspect the workspace"))

    assert Enum.any?(provider_state["messages"], &(&1["role"] == "tool" and &1["content"] =~ "workspace evidence"))

    encoded = Jason.encode!(provider_state)
    refute encoded =~ @secret
    refute encoded =~ "api_key"
    assert {:ok, _} = CodingAgent.stop_session(session)
  end

  test "adoption seeds a fresh session from the record and continues the interrupted turn", %{workspace: workspace} do
    parent = self()
    {session, _opts} = completed_session(workspace, parent)
    assert {:ok, provider_state} = Handoff.snapshot(session)
    saved_messages = provider_state["messages"]
    saved_thread = session.thread_id
    assert {:ok, _} = CodingAgent.stop_session(session)

    # The successor daemon resolves its own credentials; only the conversation
    # travelled in the record.
    opts = session_opts(parent, [final_response()])
    record = in_daemon_record(workspace, Map.put(provider_state, "interrupted", true))

    assert {:ok, restored} = CodingAgent.adopt_handoff_session(record, opts)
    assert restored.session_pid != session.session_pid
    assert restored.thread_id == saved_thread
    assert %{messages: ^saved_messages} = Session.get(restored.session_pid)
    assert Session.get(restored.session_pid).config.api_key == @secret

    assert {:ok, %{result: :turn_completed}} = CodingAgent.resume_handoff_turn(restored, turn_opts(parent))

    assert_receive {:request, request}, 1_000
    messages = request.json["messages"]
    assert Enum.any?(messages, &(&1["role"] == "user" and &1["content"] == "Inspect the workspace"))
    assert Enum.any?(messages, &(&1["role"] == "tool" and &1["content"] =~ "workspace evidence"))
    assert {:ok, _} = CodingAgent.stop_session(restored)
  end

  test "a snapshot carries the route's model and never the credentials", %{workspace: workspace} do
    parent = self()
    route_model = "deepseek/deepseek-v4.1-flash-1017"
    {:ok, session} = CodingAgent.start_session(workspace, route_only_opts(parent, [final_response()], route_model))
    session = Map.put(session, :backend, "openrouter")
    assert {:ok, %{result: :turn_completed}} = CodingAgent.run_turn(session, "Inspect the workspace", issue(), turn_opts(parent))
    flush_requests()

    assert {:ok, provider_state} = Handoff.snapshot(session)
    assert provider_state["model"] == route_model
    assert Session.get(session.session_pid).config.model == route_model

    encoded = Jason.encode!(provider_state)
    assert encoded =~ route_model
    refute encoded =~ @secret
    refute encoded =~ "api_key"
    assert {:ok, _} = CodingAgent.stop_session(session)
  end

  test "adoption starts the route's model when the provider config names none", %{workspace: workspace} do
    parent = self()
    route_model = "deepseek/deepseek-v4.1-flash-1017"
    {:ok, session} = CodingAgent.start_session(workspace, route_only_opts(parent, [final_response()], route_model))
    session = Map.put(session, :backend, "openrouter")
    assert {:ok, %{result: :turn_completed}} = CodingAgent.run_turn(session, "Inspect the workspace", issue(), turn_opts(parent))
    flush_requests()

    assert {:ok, provider_state} = Handoff.snapshot(session)
    saved_messages = provider_state["messages"]
    assert {:ok, _} = CodingAgent.stop_session(session)

    # The successor daemon's config resolves no model — `agent.priority` named it
    # only in the route — so the snapshot's model is the only way this session
    # comes back on the model dispatch chose instead of `:missing_model` (#7548).
    record = in_daemon_record(workspace, provider_state) |> Map.put("backend", "openrouter")

    assert {:ok, restored} = CodingAgent.adopt_handoff_session(record, route_only_opts(parent, [final_response()], nil))
    assert restored.model == route_model
    assert Session.get(restored.session_pid).config.model == route_model
    assert %{messages: ^saved_messages} = Session.get(restored.session_pid)

    # The restored conversation continues on the same model, not a backend default.
    assert {:ok, %{result: :turn_completed}} = CodingAgent.resume_handoff_turn(restored, turn_opts(parent))
    assert_receive {:request, request}, 1_000
    assert request.json["model"] == route_model
    assert {:ok, _} = CodingAgent.stop_session(restored)
  end

  test "adoption reads the saved session's model from a record written before the snapshot carried it", %{
    workspace: workspace
  } do
    parent = self()
    route_model = "deepseek/deepseek-v4.1-flash-1017"
    {:ok, session} = CodingAgent.start_session(workspace, route_only_opts(parent, [final_response()], route_model))

    # The runner tags a started session with the backend and model it resolved;
    # that session map is what an older daemon's record carries in
    # `session_state`, without a `model` field of its own in the snapshot.
    session = session |> Map.put(:backend, "openrouter") |> Map.put(:model, route_model)
    assert {:ok, %{result: :turn_completed}} = CodingAgent.run_turn(session, "Inspect the workspace", issue(), turn_opts(parent))
    flush_requests()

    assert {:ok, provider_state} = Handoff.snapshot(session)
    assert {:ok, _} = CodingAgent.stop_session(session)

    record =
      in_daemon_record(workspace, Map.delete(provider_state, "model"))
      |> Map.put("backend", "openrouter")
      |> Map.put("session_state", RunnerHandoff.encode(session))

    assert {:ok, restored} = CodingAgent.adopt_handoff_session(record, route_only_opts(parent, [final_response()], nil))
    assert Session.get(restored.session_pid).config.model == route_model
    assert {:ok, _} = CodingAgent.stop_session(restored)
  end

  test "adoption still names a missing model when the record carries none", %{workspace: workspace} do
    parent = self()

    # Nothing to restore and no config model, so the fallback must keep naming
    # the cause rather than starting a session on an unknown model.
    provider_state = %{"thread_id" => "thread-1", "turn_index" => 1, "next_request_id" => 2, "messages" => [], "model" => nil, "interrupted" => false}
    record = in_daemon_record(workspace, provider_state) |> Map.put("backend", "openrouter")

    assert {:error, :missing_model} = RunnerHandoff.attach(record, 2, route_only_opts(parent, [final_response()], nil))
  end

  test "a mid-turn hold captures at a step boundary and resumes the turn when the preflight aborts", %{workspace: workspace} do
    parent = self()

    # The first request answers with a tool call whose round commits; the second
    # request is still in flight when the hold lands, so the captured boundary is
    # the last completed step — the conversation as it stood when that request
    # was issued.
    opts = [
      backend: "kimi",
      instance: instance(%{}),
      api_key_fetcher: fn _env -> @secret end,
      request_fun: gated_queue_fun(start_response_queue([tool_call_response(), {:gated, final_response()}]), parent)
    ]

    {:ok, session} = CodingAgent.start_session(workspace, opts)
    session = Map.put(session, :backend, "kimi")
    test_pid = self()

    turn =
      Task.async(fn ->
        Process.put(:handoff_turn_context, %{
          workspace: workspace,
          issue: issue(),
          opts: Keyword.put(opts, :workspace, workspace),
          worker_host: nil
        })

        CodingAgent.run_turn(session, "Inspect the workspace", issue(), turn_opts(test_pid))
      end)

    assert_receive {:gated_request, _first, _first_pid}, 5_000
    assert_receive {:gated_request, _second, requester}, 5_000
    send(turn.pid, :handoff_hold)
    ref = make_ref()
    send(turn.pid, {:handoff_snapshot, self(), ref})

    assert_receive {^ref, {:ok, record}}, 5_000
    assert record["backend"] == "kimi"
    assert record["fallback_reason"] == nil
    assert RunnerHandoff.decode(record["turn_state"]) == nil
    assert record["transport"]["kind"] == "in_daemon"

    assert {:ok, saved} = Handoff.provider_state(record)
    assert saved["interrupted"] == true
    assert Enum.any?(saved["messages"], &(&1["role"] == "tool"))

    # The preflight aborted, so the parked runner must resume its own turn with
    # the request it still owns — the in-flight call is not lost.
    send(turn.pid, :handoff_abort)
    send(requester, :release)
    assert {:ok, %{result: :turn_completed}} = Task.await(turn, 5_000)
    assert {:ok, _} = CodingAgent.stop_session(session)
  end

  test "compatibility accepts a decodable in-daemon record and rejects a broken one", %{workspace: workspace} do
    parent = self()
    {session, _opts} = completed_session(workspace, parent)
    assert {:ok, provider_state} = Handoff.snapshot(session)
    record = in_daemon_record(workspace, provider_state)
    agent = Map.merge(record, %{"issue_id" => "1", "identifier" => "1", "config_fingerprint" => "config"})
    opts = [config_fingerprint: "config"]

    assert :ok = Compatibility.check(agent, record, opts)
    assert {:error, :backend_unsupported} = Compatibility.check(%{agent | "backend" => "muse"}, record, opts)
    assert {:error, :provider_state_invalid} = Compatibility.check(put_in(agent, ["transport", "provider_state"], "not-base64"), record, opts)
    assert {:error, :session_unavailable} = Compatibility.check(Map.put(agent, "fallback_reason", "session_unavailable"), record, opts)
    assert {:ok, _} = CodingAgent.stop_session(session)
  end

  test "a turn-boundary record resumes with the next turn instead of replaying the brief", %{workspace: workspace} do
    parent = self()
    {session, _opts} = completed_session(workspace, parent)
    assert {:ok, provider_state} = Handoff.snapshot(session)
    assert {:ok, _} = CodingAgent.stop_session(session)

    opts = session_opts(parent, [final_response()])
    record = in_daemon_record(workspace, provider_state)
    assert {:ok, restored} = CodingAgent.adopt_handoff_session(record, opts)
    assert Handoff.interrupted?(record) == false

    # A completed turn's snapshot resumes as an ordinary turn: the restored
    # conversation is present and the new prompt is appended to it.
    assert {:ok, %{result: :turn_completed}} = CodingAgent.run_turn(restored, "Continue the ticket", issue(), turn_opts(parent))
    assert_receive {:request, request}, 1_000
    contents = Enum.map(request.json["messages"], & &1["content"])
    assert "Inspect the workspace" in contents
    assert "Continue the ticket" in contents
    assert {:ok, _} = CodingAgent.stop_session(restored)
  end

  test "an adopted interrupted session runs the interrupted turn exactly once", %{workspace: workspace} do
    parent = self()
    {session, _opts} = completed_session(workspace, parent)
    assert {:ok, provider_state} = Handoff.snapshot(session)
    assert prompt_count(provider_state["messages"], "Inspect the workspace") == 1
    assert {:ok, _} = CodingAgent.stop_session(session)

    record = in_daemon_record(workspace, Map.put(provider_state, "interrupted", true))

    # Adoption is retried from the same record, and each attempt resumes the
    # interrupted turn. The saved conversation already holds the prompt, so no
    # attempt may append a second copy of it.
    for _attempt <- 1..2 do
      opts = session_opts(parent, [final_response()])
      assert {:ok, restored} = CodingAgent.adopt_handoff_session(record, opts)
      assert prompt_count(Session.get(restored.session_pid).messages, "Inspect the workspace") == 1

      assert {:ok, %{result: :turn_completed}} = CodingAgent.resume_handoff_turn(restored, turn_opts(parent))
      assert_receive {:request, request}, 1_000
      refute_receive {:request, _second}, 50
      assert prompt_count(request.json["messages"], "Inspect the workspace") == 1
      assert prompt_count(Session.get(restored.session_pid).messages, "Inspect the workspace") == 1
      assert {:ok, _} = CodingAgent.stop_session(restored)
      flush_requests()
    end
  end

  test "attach restores an in-daemon record through the generic runner handoff path", %{workspace: workspace} do
    parent = self()
    {session, _opts} = completed_session(workspace, parent)
    assert {:ok, provider_state} = Handoff.snapshot(session)
    saved_messages = provider_state["messages"]
    assert {:ok, _} = CodingAgent.stop_session(session)

    opts = session_opts(parent, [])
    record = in_daemon_record(workspace, provider_state)
    assert {:ok, restored} = RunnerHandoff.attach(record, 2, opts)
    assert %{messages: ^saved_messages} = Session.get(restored.session_pid)
    assert {:ok, _} = CodingAgent.stop_session(restored)
  end
end
