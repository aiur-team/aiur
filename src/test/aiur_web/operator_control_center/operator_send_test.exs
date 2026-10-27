defmodule AiurWeb.OperatorControlCenter.OperatorSendTest do
  use ExUnit.Case, async: true

  alias Aiur.LiveConversation.Normalizer
  alias Aiur.TestSupport.EndpointStubs
  alias Aiur.TrackerIdentity
  alias AiurWeb.OperatorControlCenter.OperatorSend

  @composer %{issue_identifier: "42", tracker_identity: nil, target_key: "42", writable_target?: true}

  defp stub_send(replies) do
    test_pid = self()
    {:ok, agent} = Agent.start_link(fn -> replies end)

    EndpointStubs.put(
      agent_chat_send_fun: fn target, text, opts ->
        send(test_pid, {:sent, target, text, Keyword.fetch!(opts, :message_id)})
        Agent.get_and_update(agent, fn [reply | rest] -> {reply, rest} end)
      end
    )
  end

  # The build composer needs the request id to poll delivery and to match the
  # transcript echo; the drawer's helper dropped it.
  test "an accepted send returns the request id and drops the pending id" do
    stub_send([{:ok, 7}])
    pending = %{"42" => {"dashboard-old", "older text"}}

    assert {:ok, 7, "dashboard-" <> _, %{}} = OperatorSend.send(@composer, "hello", pending)
    assert_received {:sent, "42", "hello", _id}
  end

  # #2717: an unknown outcome keeps the id, so Send again with the same text
  # cannot queue a copy; an edited draft is a new message.
  test "unknown outcome keeps the message id for the same text only" do
    unknown = {:error, {:outcome_unknown, %{item_id: nil}}}
    stub_send([unknown, unknown, unknown, {:ok, 9}])

    {:error, {:outcome_unknown, _}, first, pending} = OperatorSend.send(@composer, "go", %{})
    assert pending == %{"42" => {first, "go"}}
    {:error, _, again, pending} = OperatorSend.send(@composer, "go", pending)
    assert again == first
    {:error, _, edited, pending} = OperatorSend.send(@composer, "go now", pending)
    refute edited == first
    {:ok, 9, final, pending} = OperatorSend.send(@composer, "go now", pending)
    assert final == edited
    assert pending == %{}
  end

  test "a known failure drops the pending id so the next press is a new message" do
    stub_send([{:error, :no_running_agent}])
    pending = %{"42" => {"dashboard-kept", "go"}}
    assert {:error, :no_running_agent, "dashboard-kept", %{}} = OperatorSend.send(@composer, "go", pending)
  end

  test "empty text is refused without calling the send path" do
    stub_send([])
    assert {:error, :empty_message, nil, %{}} = OperatorSend.send(@composer, "", %{})
    refute_received {:sent, _, _, _}
  end

  test "a typed identity is the target and the row token the key" do
    identity = %TrackerIdentity{identifier: "42"}
    composer = %{@composer | tracker_identity: identity, target_key: "row-token"}
    assert OperatorSend.target(composer) == identity
    assert OperatorSend.key(composer) == "row-token"
    assert OperatorSend.target(%{issue_identifier: 42}) == "42"
    assert OperatorSend.key(%{issue_identifier: 42}) == "42"
  end

  # The remote-worker transcript echo must replace the composer's local row,
  # which works only if this id is the one the projection really assigns.
  test "transcript id equals the projection id of the agent's claim" do
    {:ok, message} = Normalizer.normalize_trusted(:user, %{role: :user, msg_id: "operator:7", body: "hi"}, DateTime.utc_now())
    assert message.id == OperatorSend.transcript_id(7)
    refute message.id == OperatorSend.transcript_id(8)
  end

  test "delivery status reads through the endpoint seam" do
    test_pid = self()

    EndpointStubs.put(
      agent_chat_delivery_status_fun: fn request_id, timeout ->
        send(test_pid, {:status, request_id, timeout})
        {:ok, :delivered}
      end
    )

    assert OperatorSend.delivery_status(7, 1_000) == {:ok, :delivered}
    assert_received {:status, 7, 1_000}
  end
end
