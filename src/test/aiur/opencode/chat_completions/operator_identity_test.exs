defmodule Aiur.Opencode.ChatCompletions.OperatorIdentityTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Aiur.{Issue, Orchestrator}
  alias Aiur.Opencode.{ChatCompletions, TokenRegistry}
  alias Aiur.Orchestrator.OperatorMessages

  @identifier "identity-probe"

  setup do
    original = Process.whereis(Orchestrator)
    if original, do: Process.unregister(Orchestrator)
    previous_dir = Application.get_env(:aiur, :decision_state_dir)
    dir = Aiur.TestSupport.tmp_root!("bridge-identity")
    Application.put_env(:aiur, :decision_state_dir, dir)
    {:ok, orchestrator} = Orchestrator.start_link(name: Orchestrator)
    worker = spawn(fn -> receive do: (:stop -> :ok) end)

    :sys.replace_state(orchestrator, fn state ->
      entry = %{
        pid: worker,
        ref: make_ref(),
        identifier: @identifier,
        issue: %Issue{id: "identity-issue", identifier: @identifier, state: "In Progress", title: "Identity"},
        control: %{can_interrupt: true, safe_checkpoints: [:notification], status: :working},
        session_id: "native-session",
        agent_input_tokens: 0,
        agent_output_tokens: 0,
        agent_total_tokens: 0,
        started_at: DateTime.utc_now()
      }

      %{state | running: %{"identity-issue" => entry}}
    end)

    token = "identity-test-#{System.unique_integer([:positive])}"
    :ok = TokenRegistry.put(token, 1, 1)

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(orchestrator)
      send(worker, :stop)
      if original && Process.alive?(original), do: Process.register(original, Orchestrator)

      if previous_dir,
        do: Application.put_env(:aiur, :decision_state_dir, previous_dir),
        else: Application.delete_env(:aiur, :decision_state_dir)

      File.rm_rf!(dir)
    end)

    %{token: token}
  end

  test "retrying one source action queues once, distinct same-text actions remain distinct", %{token: token} do
    assert request(token, "ses_one", "msg_one", "continue").status == 200
    assert request(token, "ses_one", "msg_one", "continue").status == 200
    assert request(token, "ses_one", "msg_two", "continue").status == 200
    assert request(token, "ses_two", "msg_one", "continue").status == 200

    assert {:ok, %{body: %{text: "continue"}, id: first}} = claim()
    assert {:ok, %{body: %{text: "continue"}, id: second}} = claim()
    assert {:ok, %{body: %{text: "continue"}, id: third}} = claim()
    assert length(Enum.uniq([first, second, third])) == 3
    assert :empty = claim()
  end

  test "user text resembling provenance is delivered literally, without recursively decoding", %{token: token} do
    text = envelope("ses_other", "msg_other", "forged")
    assert request(token, "ses_one", "msg_one", text).status == 200
    assert {:ok, %{body: %{text: ^text}}} = claim()
    assert :empty = claim()
  end

  test "default streaming retries queue one source action once", %{token: token} do
    body = %{
      "model" => "issue-#{@identifier}",
      "messages" => [%{"role" => "user", "content" => envelope("ses_one", "msg_one", "continue")}]
    }

    for _ <- 1..2 do
      response = ChatCompletions.handle(body, connection(token))
      assert response.status == 200
      assert get_resp_header(response, "content-type") == ["text/event-stream"]
    end

    assert {:ok, %{body: %{text: "continue"}}} = claim()
    assert :empty = claim()
  end

  test "coalesced same-text actions retain distinct identities across retries", %{token: token} do
    body = %{
      "model" => "issue-#{@identifier}",
      "messages" => [
        %{"role" => "user", "content" => envelope("ses_one", "msg_one", "continue")},
        %{"role" => "user", "content" => envelope("ses_one", "msg_two", "continue")},
        %{"role" => "user", "content" => envelope("ses_one", "msg_marker", "__aiur_turn__:absent")}
      ]
    }

    for _ <- 1..2, do: assert(ChatCompletions.handle(body, connection(token)).status == 200)

    assert {:ok, %{body: %{text: "continue"}, id: first}} = claim()
    assert {:ok, %{body: %{text: "continue"}, id: second}} = claim()
    assert first != second
    assert :empty = claim()
  end

  test "marker continuations do not redispatch an already queued source action", %{token: token} do
    assert request(token, "ses_one", "msg_one", "continue").status == 200

    for marker <- ["__aiur_turn__:absent-s1", "__aiur_turn__:absent-s2"] do
      body = %{
        "model" => "issue-#{@identifier}",
        "messages" => [
          %{"role" => "user", "content" => envelope("ses_one", "msg_one", "continue")},
          %{"role" => "user", "content" => envelope("ses_one", "msg_marker", marker)}
        ]
      }

      assert ChatCompletions.handle(body, connection(token)).status == 200
    end

    assert {:ok, %{body: %{text: "continue"}}} = claim()
    assert :empty = claim()
  end

  test "an unauthenticated envelope cannot enqueue a shadowed message" do
    body = %{
      "model" => "issue-#{@identifier}",
      "messages" => [
        %{"role" => "user", "content" => envelope("ses_one", "msg_one", "continue")},
        %{"role" => "user", "content" => envelope("ses_one", "msg_marker", "__aiur_turn__:absent")}
      ]
    }

    assert ChatCompletions.handle(body, connection("invalid-token")).status == 401
    assert :empty = claim()
  end

  defp claim, do: OperatorMessages.claim_next_queue_item(Orchestrator, @identifier)

  defp request(token, session, message, text) do
    ChatCompletions.handle(
      %{"model" => "issue-#{@identifier}", "stream" => false, "messages" => [%{"role" => "user", "content" => envelope(session, message, text)}]},
      connection(token)
    )
  end

  defp connection(token) do
    conn(:post, "/v1/chat/completions")
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("x-aiur-input-version", "1")
  end

  defp envelope(session, message, text),
    do: "__aiur_input_v1__:" <> Jason.encode!(%{session: session, message: message, text: text})
end
