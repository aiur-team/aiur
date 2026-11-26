defmodule Aiur.VoiceConverse.Host.AgentChannelTest do
  use ExUnit.Case, async: false
  alias Aiur.VoiceConverse.Host.{AgentChannel, DeliveryReceipt, Worker}

  defmodule Listener do
    def send(target, text, opts) do
      send(Application.fetch_env!(:aiur, :voice_channel_test), {:listener_send, self(), target, text, opts})

      receive do
        {:send_result, result} -> result
      end
    end

    def receipt(id, _timeout) do
      send(Application.fetch_env!(:aiur, :voice_channel_test), {:read_receipt, self(), id})

      receive do
        {:receipt_result, result} -> result
      end
    end
  end

  defmodule Live do
    def subscribe(source) do
      send(Application.fetch_env!(:aiur, :voice_channel_test), {:subscribed, self(), source})
      :ok
    end

    def snapshot(_source), do: %{messages: []}
  end

  defmodule DeliveryTarget do
    def enqueue(target, text, opts), do: Listener.send(target, text, opts)
    def read_snapshot(id, timeout), do: Listener.receipt(id, timeout)
  end

  setup do
    if Process.whereis(AgentChannel.Registry) == nil, do: start_supervised!({Registry, keys: :unique, name: AgentChannel.Registry})
    previous = Application.get_env(:aiur, AgentChannel)
    Application.put_env(:aiur, :voice_channel_test, self())
    Application.put_env(:aiur, AgentChannel, listener: Listener, live: Live, available: fn -> true end, poll_ms: 1)
    target = %Worker{identity: %Aiur.TrackerIdentity{identifier: "4137"}, live_source: :source}

    on_exit(fn ->
      if Process.whereis(AgentChannel.Registry) do
        for {pid, _} <- Registry.lookup(AgentChannel.Registry, target), do: Process.exit(pid, :kill)
      end

      Application.delete_env(:aiur, :voice_channel_test)
      if previous, do: Application.put_env(:aiur, AgentChannel, previous), else: Application.delete_env(:aiur, AgentChannel)
    end)

    %{target: target}
  end

  test "sends once with voice checkpoint options without blocking the caller", %{target: target} do
    started = System.monotonic_time(:millisecond)
    assert {:ok, ref} = AgentChannel.instruct(target, "run tests", "draft-1", [])
    assert System.monotonic_time(:millisecond) - started < 300
    assert {:ok, ^ref} = AgentChannel.instruct(target, "run tests", "draft-1", [])
    assert_receive {:listener_send, observer, identity, "run tests", opts}, 1_000
    assert identity == target.identity
    assert opts == [client_request_id: "draft-1", origin: :voice_assistant, delivery_policy: :checkpoint]
    assert observer != self()
    send(observer, {:send_result, {:ok, 42}})
    assert_receive {:read_receipt, ^observer, 42}, 1_000
    send(observer, {:receipt_result, {:ok, %{receipt: :held_async}}})
    assert_receive {:receipt, ^ref, :accepted}, 1_000
    refute_receive {:listener_send, _, _, _, _}, 50
  end

  @tag :integration
  test "real Listener facade projects a harness acknowledgement", %{target: target} do
    previous = Application.fetch_env!(:aiur, :listener_delivery_target)
    Application.put_env(:aiur, :listener_delivery_target, DeliveryTarget)
    on_exit(fn -> Application.put_env(:aiur, :listener_delivery_target, previous) end)
    Application.put_env(:aiur, AgentChannel, listener: Aiur.Listener, live: Live, available: fn -> true end)
    assert {:ok, ref} = AgentChannel.instruct(target, "confirmed draft", "integration", [])
    assert_receive {:listener_send, observer, identity, "confirmed draft", opts}, 1_000
    assert identity == target.identity
    assert Enum.sort(opts) == Enum.sort(client_request_id: "integration", origin: :voice_assistant, delivery_policy: :checkpoint)
    send(observer, {:send_result, {:ok, 44}})
    assert_receive {:read_receipt, ^observer, 44}, 1_000
    now = DateTime.utc_now()
    snapshot = %{status: :delivered, provider_delivered_at: now, delivery: %{}}
    send(observer, {:receipt_result, {:ok, snapshot}})
    assert_receive {:receipt, ^ref, :delivered}, 1_000
  end

  test "maps receipt table and missing or unavailable items" do
    for {states, expected} <- [
          {[:accepted, :held_async], :accepted},
          {[:harness_queued, :in_context, :read], :delivered},
          {[:failed, :superseded], :failed},
          {[:outcome_unknown, :unknown], :unknown}
        ],
        status <- states do
      assert DeliveryReceipt.status({:ok, %{receipt: status}}) == expected
    end

    assert DeliveryReceipt.status({:ok, nil}) == :unknown
    assert DeliveryReceipt.status({:error, :not_found}) == :unknown
    assert DeliveryReceipt.status({:error, :unavailable}) == :unknown
  end

  test "consult captures only the first agent message after delivery", %{target: target} do
    assert :ok = VoiceConverse.Ports.call_port(AgentChannel, :subscribe, [target, self()], :ask)
    assert_receive {:subscribed, observer, :source}, 1_000
    started = System.monotonic_time(:millisecond)
    assert {:ok, ref} = VoiceConverse.Ports.call_port(AgentChannel, :ask, [target, "Question: explain", "consult-1", []], :ask)
    assert System.monotonic_time(:millisecond) - started < 300
    assert_receive {:listener_send, ^observer, _, "Question: explain", opts}, 1_000
    assert opts == [client_request_id: "consult-1", origin: :voice_assistant, delivery_policy: :checkpoint]
    send(observer, {:send_result, {:ok, 43}})
    assert_receive {:read_receipt, ^observer, 43}, 1_000
    now = DateTime.utc_now()
    earlier = %{role: "agent", body: "old reply", occurred_at: DateTime.add(now, -1, :second)}
    send(observer, {:receipt_result, {:ok, %{receipt: :harness_queued, observed_at: now}}})
    assert_receive {:receipt, ^ref, :delivered}, 1_000
    send(observer, {:live_conversation_changed, %{messages: [earlier]}})
    refute_receive {:agent_reply, _, _}, 50
    later = %{role: "agent", body: "answer", occurred_at: DateTime.add(now, 1, :second)}
    send(observer, {:live_conversation_changed, %{messages: [earlier, later]}})
    assert_receive {:agent_reply, ^ref, "answer"}, 1_000
    send(observer, {:live_conversation_changed, %{messages: [later]}})
    refute_receive {:agent_reply, _, _}, 50
  end

  test "absent listener is unsupported", %{target: target} do
    Application.put_env(:aiur, AgentChannel, listener: MissingVoiceListener, available: fn -> true end)
    assert AgentChannel.capabilities(target) == %{fork: :none}
    assert AgentChannel.instruct(target, "text", "key", []) == {:error, :unsupported}
    assert AgentChannel.ask(target, "text", "key", []) == {:error, :unsupported}
    assert AgentChannel.subscribe(target, self()) == :unsupported
  end

  test "send errors never claim acceptance", %{target: target} do
    for {reason, expected} <- [
          {:invalid_message, :failed},
          {:no_running_agent, :failed},
          {:unavailable, :failed},
          {:listener_mode_unavailable, :failed},
          {{:message_id_conflict, 1}, :failed},
          {{:not_queued, :timeout}, :failed},
          {{:outcome_unknown, %{}}, :unknown}
        ] do
      assert {:ok, ref} = AgentChannel.instruct(target, "text", inspect(reason), [])
      assert_receive {:listener_send, observer, _, _, _}, 1_000
      send(observer, {:send_result, {:error, reason}})
      assert_receive {:receipt, ^ref, ^expected}, 1_000
    end
  end
end
