defmodule Aiur.AgentRunner.QueueDrain.RecoveryTest do
  use ExUnit.Case, async: false
  @moduletag :r7_characterization

  alias Aiur.AgentRunner.QueueDrain
  alias Aiur.Issue
  alias Aiur.LiveConversation
  alias Aiur.TrackerIdentity

  defmodule FakeQueueOrchestrator do
    use GenServer

    def start_link(item, report), do: GenServer.start_link(__MODULE__, %{item: item, delivered: nil, report: report})

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:claim_next_queue_item, _identifier}, _from, %{item: item} = state) when is_map(item) do
      {:reply, {:ok, item}, %{state | item: nil, delivered: item}}
    end

    def handle_call({:claim_next_queue_item, _identifier}, _from, state) do
      {:reply, :empty, state}
    end

    def handle_call({:consume_delivered_queue_items, identifier}, _from, state) do
      send(state.report, {:queue_item_consumed, identifier})
      {:reply, :ok, %{state | delivered: nil}}
    end

    def handle_call({:restore_delivered_queue_items, identifier}, _from, %{delivered: delivered} = state) do
      send(state.report, {:queue_item_restored, identifier})
      {:reply, :ok, %{state | item: delivered, delivered: nil}}
    end

    def handle_call({:fail_delivered_queue_items, identifier, reason}, _from, state) do
      send(state.report, {:queue_item_failed, identifier, reason})
      {:reply, :ok, %{state | delivered: nil}}
    end

    def handle_call(
          {:acknowledge_queue_item_delivery, item_id, provider_metadata},
          _from,
          state
        ) do
      send(state.report, {:provider_delivered, item_id, provider_metadata})
      {:reply, :ok, state}
    end
  end

  describe "drain_operator_messages/6" do
    test "provider exits restore the queued message for a replacement to drain once" do
      identifier = Integer.to_string(System.unique_integer([:positive]))
      identity = queue_identity(identifier)
      issue = %Issue{id: "gid-#{identifier}", identifier: identifier, tracker_identity: identity}
      item = %{category: :operator_message, id: 2, body: %{text: "retry on replacement"}}
      {:ok, orchestrator} = FakeQueueOrchestrator.start_link(item, self())
      server = start_supervised!({LiveConversation, name: nil})

      common_opts = [
        attempt_id: "attempt-#{identifier}",
        live_conversation_server: server
      ]

      retired_source = %{
        identity: identity,
        attempt_id: "attempt-#{identifier}",
        session_id: "retired-thread",
        backend: "codex",
        worker_generation: 10
      }

      assert {:error, {:port_exit, 9}} =
               QueueDrain.drain_operator_messages(
                 %{backend: "codex", thread_id: "retired-thread"},
                 issue,
                 fn _message -> :ok end,
                 orchestrator,
                 nil,
                 common_opts ++
                   [
                     session_id: "retired-thread",
                     worker_generation: 10,
                     run_turn: fn _session, _text, _issue, _opts ->
                       {:error, {:port_exit, 9}}
                     end
                   ]
               )

      assert_receive {:queue_item_restored, ^identifier}, 1000
      refute_receive {:queue_item_consumed, ^identifier}, 100
      refute_receive {:queue_item_failed, ^identifier, {:port_exit, 9}}, 100
      assert %{messages: []} = LiveConversation.snapshot(retired_source, server: server)

      test_pid = self()

      replacement_source = %{
        identity: identity,
        attempt_id: "attempt-#{identifier}",
        session_id: "replacement-thread",
        backend: "codex",
        worker_generation: 11
      }

      assert :ok =
               QueueDrain.drain_operator_messages(
                 %{backend: "codex", thread_id: "replacement-thread"},
                 issue,
                 fn _message -> :ok end,
                 orchestrator,
                 nil,
                 common_opts ++
                   [
                     session_id: "replacement-thread",
                     worker_generation: 11,
                     run_turn: fn session, text, _issue, _opts ->
                       send(test_pid, {:replacement_turn, session.thread_id, text})
                       {:ok, session}
                     end
                   ]
               )

      assert_receive {:replacement_turn, "replacement-thread", "retry on replacement"}, 1000
      refute_receive {:replacement_turn, "replacement-thread", "retry on replacement"}, 100
      assert_receive {:queue_item_consumed, ^identifier}, 1000
      refute_receive {:queue_item_restored, ^identifier}, 100

      assert %{messages: [%{role: "operator", body: "retry on replacement"}]} =
               LiveConversation.snapshot(replacement_source, server: server)

      assert %{messages: []} = LiveConversation.snapshot(retired_source, server: server)

      assert :ok =
               QueueDrain.drain_operator_messages(
                 %{backend: "codex", thread_id: "replacement-thread"},
                 issue,
                 fn _message -> :ok end,
                 orchestrator,
                 nil,
                 common_opts ++ [session_id: "replacement-thread", worker_generation: 11]
               )

      assert %{messages: [_single_delivery]} =
               LiveConversation.snapshot(replacement_source, server: server)
    end

    test "accepted queued prompts retain delivery chronology ahead of assistant output" do
      identifier = Integer.to_string(System.unique_integer([:positive]))
      identity = queue_identity(identifier)
      issue = %Issue{id: "gid-#{identifier}", identifier: identifier, tracker_identity: identity}
      delivered_at = ~U[2026-07-17 12:00:00Z]
      assistant_at = DateTime.add(delivered_at, 1, :second)

      item = %{
        category: :operator_message,
        id: 20,
        body: %{text: "accepted prompt"},
        inserted_at: DateTime.add(delivered_at, -1, :second),
        delivered_at: delivered_at
      }

      {:ok, orchestrator} = FakeQueueOrchestrator.start_link(item, self())
      server = start_supervised!({LiveConversation, name: nil})

      assert :ok =
               QueueDrain.drain_operator_messages(
                 %{backend: "codex", thread_id: "ordered-thread"},
                 issue,
                 fn _message -> :ok end,
                 orchestrator,
                 nil,
                 attempt_id: "attempt-#{identifier}",
                 session_id: "ordered-thread",
                 worker_generation: 20,
                 live_conversation_server: server,
                 run_turn: fn session, _text, _issue, turn_opts ->
                   Keyword.fetch!(turn_opts, :on_message).(%{
                     event: :agent_message,
                     body: "assistant response",
                     timestamp: assistant_at
                   })

                   {:ok, session}
                 end
               )

      source = %{
        identity: identity,
        attempt_id: "attempt-#{identifier}",
        session_id: "ordered-thread",
        backend: "codex",
        worker_generation: 20
      }

      assert %{messages: [operator, assistant]} = LiveConversation.snapshot(source, server: server)
      assert %{role: "operator", body: "accepted prompt", occurred_at: ^delivered_at} = operator
      assert %{role: "agent", body: "assistant response", occurred_at: ^assistant_at} = assistant
    end

    test "assistant output from a failed queued turn never admits the unaccepted prompt" do
      identifier = Integer.to_string(System.unique_integer([:positive]))
      identity = queue_identity(identifier)
      issue = %Issue{id: "gid-#{identifier}", identifier: identifier, tracker_identity: identity}

      item = %{
        category: :operator_message,
        id: 21,
        body: %{text: "must remain unaccepted"},
        delivered_at: ~U[2026-07-17 12:00:00Z]
      }

      {:ok, orchestrator} = FakeQueueOrchestrator.start_link(item, self())
      server = start_supervised!({LiveConversation, name: nil})

      assert {:error, :provider_failed} =
               QueueDrain.drain_operator_messages(
                 %{backend: "claude", thread_id: "failed-thread"},
                 issue,
                 fn _message -> :ok end,
                 orchestrator,
                 nil,
                 attempt_id: "attempt-#{identifier}",
                 session_id: "failed-thread",
                 worker_generation: 21,
                 live_conversation_server: server,
                 run_turn: fn _session, _text, _issue, turn_opts ->
                   Keyword.fetch!(turn_opts, :on_message).(%{
                     event: :agent_message,
                     body: "pre-failure assistant output",
                     timestamp: ~U[2026-07-17 12:00:01Z]
                   })

                   {:error, :provider_failed}
                 end
               )

      source = %{
        identity: identity,
        attempt_id: "attempt-#{identifier}",
        session_id: "failed-thread",
        backend: "claude",
        worker_generation: 21
      }

      assert %{messages: [%{role: "agent", body: "pre-failure assistant output"}]} =
               LiveConversation.snapshot(source, server: server)
    end

    test "closed turn/start restores the queued message for one replacement delivery" do
      identifier = "QD-start-port-closed-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      item = %{category: :operator_message, id: 5, body: %{text: "survive closed start"}}
      {:ok, orchestrator} = FakeQueueOrchestrator.start_link(item, self())

      assert {:error, {:turn_start_failed, :port_closed}} =
               QueueDrain.drain_operator_messages(
                 %{backend: "codex", thread_id: "retired-thread"},
                 issue,
                 fn _message -> :ok end,
                 orchestrator,
                 nil,
                 run_turn: fn _session, _text, _issue, _opts ->
                   {:error, {:turn_start_failed, :port_closed}}
                 end
               )

      assert_receive {:queue_item_restored, ^identifier}, 1000
      refute_receive {:queue_item_consumed, ^identifier}, 100
      refute_receive {:queue_item_failed, ^identifier, {:turn_start_failed, :port_closed}}, 100

      test_pid = self()

      assert :ok =
               QueueDrain.drain_operator_messages(
                 %{backend: "codex", thread_id: "replacement-thread"},
                 issue,
                 fn _message -> :ok end,
                 orchestrator,
                 nil,
                 run_turn: fn session, text, _issue, _opts ->
                   send(test_pid, {:replacement_turn, session.thread_id, text})
                   {:ok, session}
                 end
               )

      assert_receive {:replacement_turn, "replacement-thread", "survive closed start"}, 1000
      refute_receive {:replacement_turn, "replacement-thread", "survive closed start"}, 100
      assert_receive {:queue_item_consumed, ^identifier}, 1000
      refute_receive {:queue_item_restored, ^identifier}, 100
    end

    test "Muse pre-write closed turn/start restores a queued message for one replacement delivery" do
      identifier = "QD-muse-start-port-closed-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      item = %{category: :operator_message, id: 52, body: %{text: "survive Muse closed start"}}
      {:ok, orchestrator} = FakeQueueOrchestrator.start_link(item, self())

      assert {:error, {:turn_start_failed, :port_closed}} =
               QueueDrain.drain_operator_messages(
                 %{backend: "muse", thread_id: "retired-native-session"},
                 issue,
                 fn _message -> :ok end,
                 orchestrator,
                 nil,
                 run_turn: fn _session, _text, _issue, _opts ->
                   {:error, {:turn_start_failed, :port_closed}}
                 end
               )

      assert_receive {:queue_item_restored, ^identifier}, 1000
      refute_received {:queue_item_consumed, ^identifier}
      refute_received {:queue_item_failed, ^identifier, _reason}

      test_pid = self()

      assert :ok =
               QueueDrain.drain_operator_messages(
                 %{backend: "muse", thread_id: "replacement-native-session"},
                 issue,
                 fn _message -> :ok end,
                 orchestrator,
                 nil,
                 run_turn: fn session, text, _issue, _opts ->
                   send(test_pid, {:muse_replacement_turn, session.thread_id, text})
                   {:ok, session}
                 end
               )

      assert_receive {:muse_replacement_turn, "replacement-native-session", "survive Muse closed start"}, 1000
      assert_receive {:queue_item_consumed, ^identifier}, 1000
      refute_received {:queue_item_failed, ^identifier, _reason}
      refute_received {:muse_replacement_turn, "replacement-native-session", "survive Muse closed start"}
    end
  end

  setup do
    original_log_file = Application.get_env(:aiur, :log_file)
    log_root = Aiur.TestSupport.tmp_root!("aiur-queue-drain")
    Application.put_env(:aiur, :log_file, Path.join(log_root, "aiur.log"))
    Aiur.TestSupport.put_runtime_state_dir!(log_root)

    on_exit(fn ->
      if original_log_file do
        Application.put_env(:aiur, :log_file, original_log_file)
      else
        Application.delete_env(:aiur, :log_file)
      end

      # A late log writer can recreate an entry between rm_rf's directory
      # listing and final rmdir under CI load. As documented in #461/#480,
      # tolerate that race for this unique test root instead of raising.
      Aiur.TestCleanup.rm_rf!(log_root, unset: [:runtime_state_dir])
    end)

    %{log_root: log_root}
  end

  # Like FakeQueueOrchestrator, but the first `unavailable_left` restore RPCs
  # answer `{:error, :unavailable}` (a briefly overloaded queue GenServer)
  # before the restore confirms. Used to prove the recovery boundary retries
  # the restore instead of stranding the item or crashing on a MatchError.

  defp queue_identity(identifier) do
    %TrackerIdentity{
      status: :joinable,
      kind: :github,
      owner: "owner",
      repository: "repo",
      provider_id: "provider-#{identifier}",
      identifier: identifier,
      reason: nil
    }
  end
end
