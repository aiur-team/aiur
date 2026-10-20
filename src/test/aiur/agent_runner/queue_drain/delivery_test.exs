defmodule Aiur.AgentRunner.QueueDrain.DeliveryTest do
  use ExUnit.Case, async: false
  @moduletag :r7_characterization

  alias Aiur.AgentRunner.QueueDrain
  alias Aiur.AgentRunner.ToolExecutor
  alias Aiur.Events.Exchange
  alias Aiur.Issue
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
    test "correlated pause and resume preserve drain options" do
      parent = self()
      identifier = "QD-control-#{System.unique_integer([:positive])}"
      worker_issue_id = "gid-#{identifier}"
      issue = %Issue{id: worker_issue_id, identifier: identifier}
      item = %{category: :operator_message, id: 1, body: %{text: "queued message"}}
      {:ok, orchestrator} = FakeQueueOrchestrator.start_link(item, parent)

      task =
        Task.async(fn ->
          receive do
            :start ->
              QueueDrain.drain_operator_messages(
                %{backend: "codex", thread_id: "queue-thread"},
                issue,
                fn _message -> :ok end,
                orchestrator,
                parent,
                telemetry_attempt_id: 8,
                run_turn: fn _session, _text, _issue, opts ->
                  send(parent, {:queue_drain_opts, opts})
                  opts[:on_provider_delivery].(%{turn_id: "queued-provider-turn"})
                  {:ok, %{session_id: "queued-session"}}
                end
              )
          end
        end)

      send(task.pid, {:pause_agent, 51, 101})
      send(task.pid, :start)

      assert_receive {:worker_control_state, ^worker_issue_id, :paused, %{request_id: 51, generation: 101}}, 1000

      send(task.pid, {:resume_agent, 52, 101})

      assert_receive {:worker_control_state, ^worker_issue_id, :working, %{request_id: 52, generation: 101}}, 1000
      assert_receive {:queue_drain_opts, opts}, 1_000
      assert is_function(opts[:tool_executor], 2)
      assert is_function(opts[:on_provider_delivery], 1)
      assert_receive {:provider_delivered, 1, %{turn_id: "queued-provider-turn"}}, 1000
      assert_receive {:queue_item_consumed, ^identifier}, 1000
      assert :ok = Task.await(task, 1_000)
    end

    test "a deferred check-in is delivered as exactly one follow-up turn after the parent turn completes" do
      parent = self()
      identifier = "QD-followup-#{System.unique_integer([:positive])}"
      issue = %Issue{id: "gid-#{identifier}", identifier: identifier}
      item = %{category: :operator_message, id: 7, body: %{text: "deferred check-in"}}
      {:ok, orchestrator} = FakeQueueOrchestrator.start_link(item, parent)

      run_turn = fn _session, text, _issue, opts ->
        send(parent, {:follow_up_turn, text})
        opts[:on_provider_delivery].(%{turn_id: "follow-up-turn"})
        {:ok, %{session_id: "follow-up-session"}}
      end

      assert :ok =
               QueueDrain.drain_operator_messages(
                 %{backend: "codex", thread_id: "queue-thread"},
                 issue,
                 fn _message -> :ok end,
                 orchestrator,
                 nil,
                 telemetry_attempt_id: 7,
                 run_turn: run_turn
               )

      # The deferred item reaches the agent as exactly one sequential follow-up
      # turn once the parent turn has ended — never overlapping a live turn.
      assert_receive {:follow_up_turn, "deferred check-in"}, 1000
      assert_receive {:provider_delivered, 7, %{turn_id: "follow-up-turn"}}, 1000
      assert_receive {:queue_item_consumed, ^identifier}, 1000
      refute_receive {:follow_up_turn, _other}, 100
    end

    # #2697: a paused-then-resumed or queued turn runs in a live session, so
    # dispatch's before_run check never sees it. The turn must repair the
    # workspace's agent GitHub support first, or refuse with a named reason.
    test "a queued turn repairs a workspace that lost its gh shim, gh config and quota dir", %{log_root: log_root} do
      parent = self()
      identifier = "QD-2697-repair-#{System.unique_integer([:positive])}"
      issue = %Issue{id: "gid-#{identifier}", identifier: identifier}
      item = %{category: :operator_message, id: 26, body: %{text: "resume after pause"}}
      {:ok, orchestrator} = FakeQueueOrchestrator.start_link(item, parent)
      workspace = Path.join(log_root, "ws-repair")
      File.mkdir_p!(Path.join(workspace, ".aiur-runtime/build-bin"))

      run_turn = fn _session, _text, _issue, _opts ->
        send(parent, {:turn_saw_missing, Aiur.AgentGitHubGuard.missing_workspace_support(workspace)})
        {:ok, %{session_id: "repaired-session"}}
      end

      assert :ok =
               QueueDrain.drain_operator_messages(
                 %{backend: "claude", workspace: workspace, worker_host: nil},
                 issue,
                 fn _message -> :ok end,
                 orchestrator,
                 nil,
                 run_turn: run_turn
               )

      assert_receive {:turn_saw_missing, []}, 1000
      assert_receive {:queue_item_consumed, ^identifier}, 1000
    end

    test "a queued turn refuses to start when the gh config dir is an unrepairable symlink", %{log_root: log_root} do
      parent = self()
      identifier = "QD-2697-refuse-#{System.unique_integer([:positive])}"
      issue = %Issue{id: "gid-#{identifier}", identifier: identifier}
      item = %{category: :operator_message, id: 27, body: %{text: "resume after pause"}}
      {:ok, orchestrator} = FakeQueueOrchestrator.start_link(item, parent)
      workspace = Path.join(log_root, "ws-refuse")
      operator_config = Path.join(log_root, "operator-gh")
      File.mkdir_p!(Path.join(workspace, ".aiur-runtime"))
      File.mkdir_p!(operator_config)
      File.ln_s!(operator_config, Path.join(workspace, ".aiur-runtime/gh"))

      run_turn = fn _session, _text, _issue, _opts ->
        send(parent, :turn_started)
        {:ok, %{session_id: "must-not-run"}}
      end

      assert {:error, {:agent_support_repair_failed, ^workspace, missing, {:agent_gh_config_dir_unavailable, _, _}}} =
               QueueDrain.drain_operator_messages(
                 %{backend: "claude", workspace: workspace, worker_host: nil},
                 issue,
                 fn _message -> :ok end,
                 orchestrator,
                 nil,
                 run_turn: run_turn
               )

      assert ".aiur-runtime/gh" in missing
      refute_received :turn_started
      # The turn never started: the operator message goes back to the queue.
      assert_receive {:queue_item_restored, ^identifier}, 1000
      refute_received {:queue_item_failed, ^identifier, _reason}
    end

    test "a provider active-turn (-32_003) rejection restores the queued message instead of failing it" do
      identifier = "QD-active-turn-#{System.unique_integer([:positive])}"
      issue = %Issue{id: "gid-#{identifier}", identifier: identifier}
      item = %{category: :operator_message, id: 3, body: %{text: "active turn retry"}}
      {:ok, orchestrator} = FakeQueueOrchestrator.start_link(item, self())

      # aiur-claude rejected the turn-boundary `turn/start` because it still
      # considers the thread active; the durable item must be restored to
      # pending, never marked failed.
      assert :ok =
               QueueDrain.drain_operator_messages(
                 %{backend: "codex", thread_id: "active-thread"},
                 issue,
                 fn _message -> :ok end,
                 orchestrator,
                 nil,
                 telemetry_attempt_id: 3,
                 run_turn: fn _session, _text, _issue, _opts ->
                   {:error, {:turn_start_failed, {:response_error, %{"code" => -32_003}}}}
                 end
               )

      assert_receive {:queue_item_restored, ^identifier}, 1000
      refute_receive {:queue_item_failed, ^identifier, _reason}, 100
      refute_receive {:queue_item_consumed, ^identifier}, 100
    end

    test "queued turns preserve lifecycle attempts in emitted observations" do
      identifier = "QD-observation-#{System.unique_integer([:positive])}"

      {:ok, identity} =
        TrackerIdentity.from_github(
          %{"node_id" => "I_kwDOQueueObservation", "number" => 42},
          {"owner", "repo"},
          {"owner", "repo"}
        )

      issue = %Issue{identifier: identifier, tracker_identity: identity}
      item = %{category: :operator_message, id: 1, body: %{text: "queued message"}}
      {:ok, orchestrator} = FakeQueueOrchestrator.start_link(item, self())
      :ok = Exchange.subscribe("ticket.#{identifier}.agent.progress.checkin")

      run_turn = fn _session, _text, _issue, opts ->
        executor = Keyword.fetch!(opts, :tool_executor)

        assert ToolExecutor.execute(
                 executor,
                 "emit_event",
                 %{"name" => "progress.checkin", "message" => "private", "payload" => %{"percent" => 60}},
                 "queued-tool"
               )["success"] == true

        {:ok, %{session_id: "queued-session"}}
      end

      assert :ok =
               QueueDrain.drain_operator_messages(
                 %{backend: "codex", thread_id: "queue-thread"},
                 issue,
                 fn _message -> :ok end,
                 orchestrator,
                 nil,
                 telemetry_attempt_id: 7,
                 run_turn: run_turn
               )

      assert_receive {:event, %{ticket_observation: observation}}, 2_000
      assert observation.tracker_identity == identity
      assert observation.provenance.attempt == 7
      assert observation.provenance.session_id == "queue-thread"
      assert observation.provenance.source_event_id == "queued-tool"
      assert_receive {:queue_item_consumed, ^identifier}, 1000
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
