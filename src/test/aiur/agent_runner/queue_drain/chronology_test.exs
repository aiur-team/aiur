defmodule Aiur.AgentRunner.QueueDrain.ChronologyTest do
  use ExUnit.Case, async: false
  @moduletag :r7_characterization

  alias Aiur.AgentRunner.QueueDrain
  alias Aiur.Issue
  alias Aiur.PauseContainment

  @active_turn_mismatch %{
    "code" => -32_600,
    "message" => "expected active turn id queued-turn but found prior-turn"
  }

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

  defmodule FlakyRestoreQueueOrchestrator do
    use GenServer

    def start_link(item, report, unavailable_restores),
      do:
        GenServer.start_link(
          __MODULE__,
          %{item: item, delivered: nil, report: report, unavailable_left: unavailable_restores}
        )

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

    def handle_call({:restore_delivered_queue_items, identifier}, _from, %{unavailable_left: n} = state)
        when n > 0 do
      send(state.report, {:restore_unavailable, identifier})
      {:reply, {:error, :unavailable}, %{state | unavailable_left: n - 1}}
    end

    def handle_call({:restore_delivered_queue_items, identifier}, _from, %{delivered: delivered} = state) do
      send(state.report, {:queue_item_restored, identifier})
      {:reply, :ok, %{state | item: delivered, delivered: nil}}
    end

    def handle_call({:fail_delivered_queue_items, identifier, reason}, _from, state) do
      send(state.report, {:queue_item_failed, identifier, reason})
      {:reply, :ok, %{state | delivered: nil}}
    end
  end

  describe "drain_operator_messages/6" do
    # Future-regression guard: this behavior already held before Muse recovery.
    test "Muse transport exit after admission fails a queued message rather than replaying it" do
      identifier = "QD-muse-accepted-port-exit-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      item = %{category: :operator_message, id: 53, body: %{text: "uncertain outcome"}}
      {:ok, orchestrator} = FakeQueueOrchestrator.start_link(item, self())

      assert {:error, {:native_port_exit, 9}} =
               QueueDrain.drain_operator_messages(
                 %{backend: "muse", thread_id: "accepted-native-session"},
                 issue,
                 fn _message -> :ok end,
                 orchestrator,
                 nil,
                 run_turn: fn _session, _text, _issue, _opts -> {:error, {:native_port_exit, 9}} end
               )

      assert_receive {:queue_item_failed, ^identifier, {:native_port_exit, 9}}, 1000
      refute_received {:queue_item_restored, ^identifier}
    end

    test "a paused queued turn confirms containment before waiting for resume" do
      identifier = "QD-paused-containment-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      item = %{category: :operator_message, id: 51, body: %{text: "pause this follow-up"}}
      {:ok, orchestrator} = FakeQueueOrchestrator.start_link(item, self())
      fake_pid = 2_147_483_647
      assert {:ok, containment} = PauseContainment.register(identifier, fake_pid, fake_pid)
      on_exit(fn -> PauseContainment.unregister(containment) end)
      assert {:ok, ^containment} = PauseContainment.arm(identifier)

      {:ok, worker} =
        Task.start(fn ->
          QueueDrain.drain_operator_messages(
            %{backend: "muse", thread_id: "native-thread", containment: containment},
            issue,
            fn _message -> :ok end,
            orchestrator,
            nil,
            run_turn: fn _session, _text, _issue, _opts ->
              {:paused, %{control: %{request_id: 51, generation: containment.generation}}}
            end
          )
        end)

      on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)
      assert_receive {:queue_item_restored, ^identifier}, 1000
      assert %{^identifier => %{mode: :paused}} = :sys.get_state(PauseContainment).entries
      refute_received {:queue_item_failed, ^identifier, _reason}
    end

    test "a queued Muse turn completed during pause is consumed before waiting for resume" do
      identifier = "QD-muse-completed-pause-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      item = %{category: :operator_message, id: 52, body: %{text: "apply once"}}
      {:ok, orchestrator} = FakeQueueOrchestrator.start_link(item, self())
      fake_pid = 2_147_483_647
      assert {:ok, containment} = PauseContainment.register(identifier, fake_pid, fake_pid)
      on_exit(fn -> PauseContainment.unregister(containment) end)
      assert {:ok, ^containment} = PauseContainment.arm(identifier)

      {:ok, worker} =
        Task.start(fn ->
          QueueDrain.drain_operator_messages(
            %{backend: "muse", thread_id: "native-thread", containment: containment},
            issue,
            fn _message -> :ok end,
            orchestrator,
            nil,
            run_turn: fn _session, _text, _issue, _opts ->
              {:paused, %{native_terminal: :completed, control: %{request_id: 52, generation: containment.generation}}}
            end
          )
        end)

      on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)
      assert_receive {:queue_item_consumed, ^identifier}, 1_000
      refute_received {:queue_item_restored, ^identifier}
      assert %{item: nil, delivered: nil} = :sys.get_state(orchestrator)
      assert %{^identifier => %{mode: :paused}} = :sys.get_state(PauseContainment).entries
    end

    test "a transient unavailable restore is confirmed before replacement, without stranding or failing the item" do
      identifier = "QD-restore-unavailable-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      item = %{category: :operator_message, id: 8, body: %{text: "survive unavailable restore"}}
      {:ok, orchestrator} = FlakyRestoreQueueOrchestrator.start_link(item, self(), 1)

      # The follow-up turn hits a closed port and the first restore RPC answers
      # `{:error, :unavailable}`. The boundary must retry the restore (no
      # MatchError abnormal exit, no failed-delivery), confirm it, then return
      # the recoverable error so the runner clean-exits for a fresh transport.
      assert {:error, {:turn_start_failed, :port_closed}} =
               QueueDrain.drain_operator_messages(
                 %{backend: "codex", thread_id: "retired-thread"},
                 issue,
                 fn _message -> :ok end,
                 orchestrator,
                 nil,
                 restore_confirm_backoff_ms: 0,
                 run_turn: fn _session, _text, _issue, _opts ->
                   {:error, {:turn_start_failed, :port_closed}}
                 end
               )

      assert_receive {:restore_unavailable, ^identifier}, 1000
      assert_receive {:queue_item_restored, ^identifier}, 1000
      refute_receive {:queue_item_failed, ^identifier, _reason}, 100
      refute_receive {:queue_item_consumed, ^identifier}, 100

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

      assert_receive {:replacement_turn, "replacement-thread", "survive unavailable restore"}, 1000
      refute_receive {:replacement_turn, "replacement-thread", "survive unavailable restore"}, 100
      assert_receive {:queue_item_consumed, ^identifier}, 1000
      refute_receive {:queue_item_restored, ^identifier}, 100
    end

    test "active-turn mismatch restores the queued message without failing it" do
      identifier = "QD-turn-mismatch-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      item = %{category: :operator_message, id: 6, body: %{text: "preserve mismatch work"}}
      {:ok, orchestrator} = FakeQueueOrchestrator.start_link(item, self())

      assert {:error, {:turn_interrupt_failed, @active_turn_mismatch}} =
               QueueDrain.drain_operator_messages(
                 %{backend: "codex", thread_id: "desynchronized-thread"},
                 issue,
                 fn _message -> :ok end,
                 orchestrator,
                 nil,
                 run_turn: fn _session, _text, _issue, _opts ->
                   {:error, {:turn_interrupt_failed, @active_turn_mismatch}}
                 end
               )

      assert_receive {:queue_item_restored, ^identifier}, 1000
      refute_receive {:queue_item_consumed, ^identifier}, 100
      refute_receive {:queue_item_failed, ^identifier, {:turn_interrupt_failed, @active_turn_mismatch}}, 100
    end

    test "genuine provider turn/start failures still fail the queued delivery" do
      identifier = "QD-provider-rejected-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      item = %{category: :operator_message, id: 7, body: %{text: "hard failure"}}
      {:ok, orchestrator} = FakeQueueOrchestrator.start_link(item, self())

      assert {:error, {:turn_start_failed, :provider_rejected}} =
               QueueDrain.drain_operator_messages(
                 %{backend: "codex", thread_id: "provider-rejected-thread"},
                 issue,
                 fn _message -> :ok end,
                 orchestrator,
                 nil,
                 run_turn: fn _session, _text, _issue, _opts ->
                   {:error, {:turn_start_failed, :provider_rejected}}
                 end
               )

      assert_receive {:queue_item_failed, ^identifier, {:turn_start_failed, :provider_rejected}}, 1000
      refute_receive {:queue_item_restored, ^identifier}, 100
    end

    test "Claude provider exits retain the existing failed-delivery behavior" do
      identifier = "QD-claude-port-exit-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      item = %{category: :operator_message, id: 3, body: %{text: "do not replay"}}
      {:ok, orchestrator} = FakeQueueOrchestrator.start_link(item, self())

      assert {:error, {:port_exit, 9}} =
               QueueDrain.drain_operator_messages(
                 %{backend: "claude", thread_id: "claude-thread"},
                 issue,
                 fn _message -> :ok end,
                 orchestrator,
                 nil,
                 run_turn: fn _session, _text, _issue, _opts -> {:error, {:port_exit, 9}} end
               )

      assert_receive {:queue_item_failed, ^identifier, {:port_exit, 9}}, 1000
      refute_receive {:queue_item_restored, ^identifier}, 100
    end

    test "Claude closed ports retain the existing failed-delivery behavior" do
      identifier = "QD-claude-port-closed-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      item = %{category: :operator_message, id: 4, body: %{text: "do not replay"}}
      {:ok, orchestrator} = FakeQueueOrchestrator.start_link(item, self())

      assert {:error, :port_closed} =
               QueueDrain.drain_operator_messages(
                 %{backend: "claude", thread_id: "claude-thread"},
                 issue,
                 fn _message -> :ok end,
                 orchestrator,
                 nil,
                 run_turn: fn _session, _text, _issue, _opts -> {:error, :port_closed} end
               )

      assert_receive {:queue_item_failed, ^identifier, :port_closed}, 1000
      refute_receive {:queue_item_restored, ^identifier}, 100
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
end
