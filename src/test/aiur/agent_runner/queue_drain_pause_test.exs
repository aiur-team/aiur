defmodule Aiur.AgentRunner.QueueDrainPauseTest do
  use ExUnit.Case, async: false

  import Aiur.TestSupport, only: [receive_barrier: 1]

  alias Aiur.AgentRunner.QueueDrain
  alias Aiur.{AlertFeed, Issue, PauseContainment}

  setup do
    original_log_file = Application.get_env(:aiur, :log_file)
    log_root = Aiur.TestSupport.tmp_root!("aiur-queue-drain-pause")
    Application.put_env(:aiur, :log_file, Path.join(log_root, "aiur.log"))
    Aiur.TestSupport.put_runtime_state_dir!(log_root)

    on_exit(fn ->
      if original_log_file do
        Application.put_env(:aiur, :log_file, original_log_file)
      else
        Application.delete_env(:aiur, :log_file)
      end

      File.rm_rf(log_root)
    end)

    %{log_root: log_root}
  end

  # Queue orchestrator double whose consume/restore/fail replies can be forced to an error.
  defmodule FakeQueueOrchestrator do
    use GenServer

    def start_link(item, report, bookkeeping \\ %{}), do: GenServer.start_link(__MODULE__, %{item: item, delivered: nil, report: report, bookkeeping: bookkeeping})

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:claim_next_queue_item, _identifier}, _from, %{item: item} = state) when is_map(item) do
      {:reply, {:ok, item}, %{state | item: nil, delivered: item}}
    end

    def handle_call({:claim_next_queue_item, _identifier}, _from, state), do: {:reply, :empty, state}

    def handle_call({:consume_delivered_queue_items, identifier}, _from, state) do
      send(state.report, {:queue_item_consumed, identifier})
      bookkeeping_reply(state, :consume, %{state | delivered: nil})
    end

    def handle_call({:restore_delivered_queue_items, identifier}, _from, %{delivered: delivered} = state) do
      send(state.report, {:queue_item_restored, identifier})
      bookkeeping_reply(state, :restore, %{state | item: delivered, delivered: nil})
    end

    def handle_call({:fail_delivered_queue_items, identifier, reason}, _from, state) do
      send(state.report, {:queue_item_failed, identifier, reason})
      bookkeeping_reply(state, :fail, %{state | delivered: nil})
    end

    def handle_call({:acknowledge_queue_item_delivery, item_id, provider_metadata}, _from, state) do
      send(state.report, {:provider_delivered, item_id, provider_metadata})
      {:reply, :ok, state}
    end

    defp bookkeeping_reply(state, op, updated) do
      case Map.get(state.bookkeeping, op, :ok) do
        :ok -> {:reply, :ok, updated}
        error -> {:reply, error, state}
      end
    end
  end

  for entry <- [:drain_operator_messages, :wait_for_operator_message], correlated <- [true, false] do
    test "#{entry} confirms containment and preserves the queued message (correlated=#{correlated})", %{log_root: log_root} do
      parent = self()
      identifier = "QD-between-pause-#{System.unique_integer([:positive])}"
      issue = %Issue{id: "gid-#{identifier}", identifier: identifier}
      item = %{category: :operator_message, id: 61, body: %{text: "deliver after resume"}}
      {:ok, orchestrator} = FakeQueueOrchestrator.start_link(item, parent)
      assert {:ok, containment} = PauseContainment.register(identifier, 2_147_483_647, 2_147_483_647)
      on_exit(fn -> PauseContainment.unregister(containment) end)
      assert {:ok, ^containment} = PauseContainment.arm(identifier)
      session = %{backend: "codex", thread_id: "between-thread", containment: containment}

      opts = [
        run_turn: fn _session, text, _issue, _opts ->
          send(parent, {:delivered_after_resume, text})
          {:ok, %{session_id: "resumed-session"}}
        end
      ]

      task =
        Task.async(fn ->
          receive do
            :start -> apply(QueueDrain, unquote(entry), [session, issue, fn _ -> :ok end, orchestrator, parent, opts])
          end
        end)

      on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)
      pause = if unquote(correlated), do: {:pause_agent, 61, containment.generation}, else: {:pause_agent, 61}
      send(task.pid, pause)
      send(task.pid, :start)

      if unquote(correlated) do
        receive_barrier({:worker_control_state, _, :paused, _})
      else
        receive_barrier({:worker_control_state, _, :paused})
      end

      assert %{^identifier => %{mode: :paused, generation: generation, deadline_ref: nil}} = :sys.get_state(PauseContainment).entries
      assert generation == containment.generation
      assert %{item: ^item, delivered: nil} = :sys.get_state(orchestrator)
      refute_received {:delivered_after_resume, _}
      assert AlertFeed.list(roots: [], log_roots: [log_root], needs_attention: true) == []

      send(task.pid, {:resume_agent, 62})
      assert :ok = Task.await(task)
      assert_received {:delivered_after_resume, "deliver after resume"}
      refute_received {:delivered_after_resume, _}
      assert %{item: nil, delivered: nil} = :sys.get_state(orchestrator)
    end
  end

  for {label, result, op} <- [
        {"completed", {:ok, %{session_id: "completed-session"}}, :consume},
        {"completed while pausing", {:paused, %{native_terminal: :completed}}, :consume},
        {"interrupted", {:paused, %{}}, :restore},
        {"failed", {:error, {:turn_start_failed, :provider_rejected}}, :fail}
      ] do
    test "bookkeeping error does not crash a #{label} queued turn" do
      parent = self()
      identifier = "QD-bookkeeping-#{System.unique_integer([:positive])}"
      issue = %Issue{id: "gid-#{identifier}", identifier: identifier}
      item = %{category: :operator_message, id: 71, body: %{text: "keep durable evidence"}}
      {:ok, orchestrator} = FakeQueueOrchestrator.start_link(item, parent, %{unquote(op) => {:error, :unavailable}})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          task =
            Task.async(fn ->
              QueueDrain.drain_operator_messages(
                %{backend: "codex", thread_id: "bookkeeping-thread"},
                issue,
                fn _ -> :ok end,
                orchestrator,
                parent,
                run_turn: fn _session, _text, _issue, _opts -> unquote(Macro.escape(result)) end
              )
            end)

          on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)

          if unquote(op) == :restore or unquote(label) == "completed while pausing" do
            receive_barrier({:worker_control_state, _, :paused, _})
            assert Process.alive?(task.pid)
            send(task.pid, {:resume_agent, 72})
          end

          expected = if unquote(op) == :fail, do: unquote(Macro.escape(result)), else: :ok
          assert Task.await(task) == expected
        end)

      assert log =~ "Orchestrator #{unquote(op)}_delivered_queue_items unavailable"
      assert log =~ "continuing without crashing the agent"
      assert %{item: nil, delivered: ^item} = :sys.get_state(orchestrator)
    end
  end
end
