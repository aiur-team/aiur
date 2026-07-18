defmodule Aiur.AppServer.AdapterTest do
  use ExUnit.Case, async: true

  alias Aiur.AppServer.Adapter
  alias Aiur.Codex.{Interrupts, TurnLoop}

  defmodule StubBackend do
    @behaviour Aiur.AppServer.Adapter

    def backend_label, do: "Stub"
    def send_frame(_port, _frame), do: :ok
    def metadata_from_message(_port, _payload), do: %{}
    def loop_state_extras(_session), do: %{}
    def handle_interrupt_error(_state, error), do: {:error, error}
    def handle_malformed(state, _payload_string, _port), do: {:continue, state}

    def start_turn(session, _prompt, _issue) do
      session.start_turn_result
    end

    def handle_method(_session, _state, %{"method" => "turn/completed"}, _payload_string, _method) do
      {:ok, :turn_completed}
    end

    def handle_method(_session, _state, %{"method" => "pause"}, _payload_string, _method) do
      {:paused, %{request_id: 1}}
    end

    def handle_method(_session, _state, %{"method" => "fail"}, _payload_string, _method) do
      {:error, :failed}
    end
  end

  defmodule DeferredIdlePauseBackend do
    @behaviour Aiur.AppServer.Adapter

    def backend_label, do: "Codex"

    def send_frame(port, %{"id" => request_id, "method" => "turn/interrupt"} = frame) do
      send(self(), {:frame, frame})

      idle = %{"method" => "thread/status/changed", "params" => %{"status" => %{"type" => "idle"}}}
      no_active_turn = %{"id" => request_id, "error" => %{"code" => -32_600, "message" => "no active turn"}}

      frames =
        case Process.get({__MODULE__, :interrupt_event_order}, :idle_first) do
          :idle_first -> [idle, no_active_turn]
          :response_first -> [no_active_turn, idle]
          :response_only -> [no_active_turn]
          :idle_then_ack -> [idle, %{"id" => request_id, "result" => %{}}]
          :ack_then_idle -> [%{"id" => request_id, "result" => %{}}, idle]
        end

      Enum.each(frames, fn payload ->
        send(self(), {port, {:data, {:eol, Jason.encode!(payload)}}})
      end)

      :ok
    end

    def metadata_from_message(_port, _payload), do: %{}
    def start_turn(session, _prompt, _issue), do: session.start_turn_result

    def loop_state_extras(_session) do
      %{
        active_turn_ids: MapSet.new(),
        accepted_turn_ids: MapSet.new(),
        retired_turn_ids: MapSet.new(),
        anonymous_completion_consumed?: false,
        auto_approve_requests: true,
        turn_started?: true,
        interrupt_acknowledged?: false,
        interrupt_idle_seen?: false
      }
    end

    def handle_interrupt_error(state, error), do: Interrupts.handle_interrupt_error(state, error)

    def handle_method(session, state, payload, payload_string, method) do
      TurnLoop.handle_method(session, state, payload, payload_string, method)
    end

    def handle_malformed(state, payload_string, port) do
      TurnLoop.handle_malformed(state, payload_string, port)
    end
  end

  defmodule CodexLifecycleBackend do
    @behaviour Aiur.AppServer.Adapter

    def backend_label, do: "Codex"
    def send_frame(_port, _frame), do: :ok
    def metadata_from_message(_port, _payload), do: %{}
    def start_turn(session, _prompt, _issue), do: session.start_turn_result

    def loop_state_extras(_session) do
      %{
        active_turn_ids: MapSet.new(),
        accepted_turn_ids: MapSet.new(),
        retired_turn_ids: MapSet.new(),
        anonymous_completion_consumed?: false,
        auto_approve_requests: true,
        turn_started?: false,
        interrupt_acknowledged?: false,
        interrupt_idle_seen?: false,
        pending_operator_requests: Process.get({__MODULE__, :pending_operator_requests}, %{}),
        timeout_ms: 100
      }
    end

    def handle_interrupt_error(state, error), do: Interrupts.handle_interrupt_error(state, error)

    def handle_method(session, state, payload, payload_string, method) do
      TurnLoop.handle_method(session, state, payload, payload_string, method)
    end

    def handle_malformed(state, payload_string, port) do
      TurnLoop.handle_malformed(state, payload_string, port)
    end
  end

  test "run_turn returns success with session identifiers" do
    port = cat_port()
    send(self(), {port, {:data, {:eol, Jason.encode!(%{"method" => "turn/completed"})}}})

    assert {:ok, result} = Adapter.run_turn(StubBackend, session(port), "prompt", issue(), [])
    assert result.result == :turn_completed
    assert result.thread_id == "thread-1"
    assert result.turn_id == "turn-1"
    assert result.session_id == "thread-1-turn-1"
  end

  test "acknowledges provider delivery only after turn/start succeeds" do
    port = cat_port()
    parent = self()
    send(self(), {port, {:data, {:eol, Jason.encode!(%{"method" => "turn/completed"})}}})

    assert {:ok, _result} =
             Adapter.run_turn(StubBackend, session(port), "prompt", issue(),
               on_provider_delivery: fn metadata ->
                 send(parent, {:provider_delivered, metadata})
               end
             )

    assert_receive {:provider_delivered, %{transport: :app_server, turn_id: "turn-1"}}

    failed_session = session(port, %{start_turn_result: {:error, :boom}})

    assert {:error, {:turn_start_failed, :boom}} =
             Adapter.run_turn(StubBackend, failed_session, "prompt", issue(), on_provider_delivery: fn _metadata -> send(parent, :unexpected_delivery) end)

    refute_receive :unexpected_delivery, 50
  end

  test "run_turn passes paused payload through with session_id" do
    port = cat_port()
    send(self(), {port, {:data, {:eol, Jason.encode!(%{"method" => "pause"})}}})

    assert {:paused, %{request_id: 1, session_id: "thread-1-turn-1"}} =
             Adapter.run_turn(StubBackend, session(port), "prompt", issue(), [])
  end

  test "run_turn preserves pause after idle and a no-active-turn interrupt response" do
    assert_deferred_idle_pause(:idle_first, 41)
  end

  test "run_turn preserves pause when a no-active-turn interrupt response precedes idle" do
    assert_deferred_idle_pause(:response_first, 42)
  end

  test "run_turn preserves pause when no idle follows a no-active-turn interrupt response" do
    assert_deferred_idle_pause(:response_only, 43)
  end

  test "run_turn reconciles a successful pause acknowledgement after idle" do
    assert_deferred_idle_pause(:idle_then_ack, 44)
  end

  test "run_turn reconciles idle after a successful pause acknowledgement" do
    assert_deferred_idle_pause(:ack_then_idle, 45)
  end

  test "run_turn does not promote accepted steering response IDs without turn/started" do
    port = cat_port()
    parent = self()

    Process.put(
      {CodexLifecycleBackend, :pending_operator_requests},
      pending_operator_request(77, parent)
    )

    response = %{
      "id" => 77,
      "result" => %{"turn" => %{"id" => "turn-accepted-only", "status" => "inProgress"}}
    }

    parent_completed = turn_completed("turn-1")
    send_frames(port, [response, parent_completed])

    assert {:ok, %{result: :turn_completed}} =
             Adapter.run_turn(CodexLifecycleBackend, session(port), "prompt", issue(), [])

    assert_receive {:accepted, "turn-accepted-only"}
  end

  test "run_turn completes from a terminal response without a later lifecycle frame" do
    port = cat_port()
    parent = self()

    Process.put(
      {CodexLifecycleBackend, :pending_operator_requests},
      pending_operator_request(79, parent)
    )

    terminal_response = %{
      "id" => 79,
      "result" => %{"turn" => %{"id" => "turn-1", "status" => "completed"}}
    }

    send_frames(port, [terminal_response])

    assert {:ok, %{result: :turn_completed}} =
             Adapter.run_turn(CodexLifecycleBackend, session(port), "prompt", issue(), [])

    assert_receive {:accepted, "turn-1"}
  end

  test "run_turn exits after two operator deliveries and provider idle/completed" do
    port = cat_port()
    parent = self()

    pending_operator_requests =
      Map.merge(
        pending_operator_request(80, parent),
        pending_operator_request(81, parent)
      )

    Process.put(
      {CodexLifecycleBackend, :pending_operator_requests},
      pending_operator_requests
    )

    response = fn request_id, turn_id ->
      %{
        "id" => request_id,
        "result" => %{"turn" => %{"id" => turn_id, "status" => "inProgress"}}
      }
    end

    started = fn turn_id ->
      %{
        "method" => "turn/started",
        "params" => %{"turn" => %{"id" => turn_id, "status" => "inProgress"}}
      }
    end

    idle = %{
      "method" => "thread/status/changed",
      "params" => %{"status" => %{"type" => "idle"}}
    }

    send_frames(port, [
      response.(80, "turn-child-1"),
      response.(81, "turn-child-2"),
      started.("turn-child-1"),
      started.("turn-child-2"),
      idle,
      turn_completed("turn-1")
    ])

    assert {:ok, %{result: :turn_completed}} =
             Adapter.run_turn(CodexLifecycleBackend, session(port), "prompt", issue(), [])

    assert_receive {:accepted, "turn-child-1"}
    assert_receive {:accepted, "turn-child-2"}
    refute_receive {:failed, _reason}
  end

  test "run_turn rejects late response and start registration for a retired ID" do
    port = cat_port()
    parent = self()

    Process.put(
      {CodexLifecycleBackend, :pending_operator_requests},
      pending_operator_request(78, parent)
    )

    completed_before_registration = turn_completed("turn-late")

    late_response = %{
      "id" => 78,
      "result" => %{"turn" => %{"id" => "turn-late", "status" => "inProgress"}}
    }

    late_started = %{
      "method" => "turn/started",
      "params" => %{"turn" => %{"id" => "turn-late", "status" => "inProgress"}}
    }

    send_frames(port, [completed_before_registration, late_response, late_started, turn_completed("turn-1")])

    assert {:ok, %{result: :turn_completed}} =
             Adapter.run_turn(CodexLifecycleBackend, session(port), "prompt", issue(), [])

    assert_receive {:failed, {:provider_turn_retired, "turn-late"}}
    refute_receive {:accepted, "turn-late"}
  end

  test "run_turn consumes duplicate anonymous completions only once" do
    port = cat_port()
    parent = self()

    child_started = %{
      "method" => "turn/started",
      "params" => %{"turn" => %{"id" => "turn-child", "status" => "inProgress"}}
    }

    anonymous_completed = %{"method" => "turn/completed", "params" => %{"turn" => %{"status" => "completed"}}}

    send_frames(port, [
      child_started,
      anonymous_completed,
      anonymous_completed,
      turn_completed("turn-child")
    ])

    assert {:ok, %{result: :turn_completed}} =
             Adapter.run_turn(
               CodexLifecycleBackend,
               session(port),
               "prompt",
               issue(),
               on_message: fn message -> send(parent, {:lifecycle_event, message.event}) end
             )

    assert_receive {:lifecycle_event, :turn_completed}
    assert_receive {:lifecycle_event, :turn_completed}
    assert_receive {:lifecycle_event, :turn_completed}
  end

  defp assert_deferred_idle_pause(order, request_id) do
    port = cat_port()
    Process.put({DeferredIdlePauseBackend, :interrupt_event_order}, order)
    send(self(), {:pause_agent, request_id})

    assert {:paused,
            %{
              request_id: ^request_id,
              turn_id: "turn-1",
              session_id: "thread-1-turn-1"
            }} = Adapter.run_turn(DeferredIdlePauseBackend, session(port), "prompt", issue(), [])

    assert_receive {:frame, %{"method" => "turn/interrupt"}}
  end

  test "run_turn emits turn_ended_with_error on loop error" do
    port = cat_port()
    parent = self()
    send(self(), {port, {:data, {:eol, Jason.encode!(%{"method" => "fail"})}}})

    assert {:error, :failed} =
             Adapter.run_turn(StubBackend, session(port), "prompt", issue(), on_message: fn msg -> send(parent, msg) end)

    assert_receive %{event: :turn_ended_with_error, reason: :failed}
  end

  test "start_turn failure emits startup_failed" do
    port = cat_port()
    parent = self()
    session = session(port, %{start_turn_result: {:error, :boom}})

    assert {:error, {:turn_start_failed, :boom}} =
             Adapter.run_turn(StubBackend, session, "prompt", issue(), on_message: fn msg -> send(parent, msg) end)

    assert_receive %{event: :startup_failed, reason: :boom}
  end

  test "start_port/2 starts bash in the requested workspace" do
    assert {:ok, port} = Adapter.start_port(File.cwd!(), "printf '%s\\n' ready")
    assert_receive {^port, {:data, {:eol, "ready"}}}, 1_000
  end

  test "start_port/4 accepts string-valued launch environment" do
    assert {:ok, port} =
             Adapter.start_port(
               File.cwd!(),
               "printf '%s\\n' \"$CLAUDE_CODE_ENABLE_TELEMETRY\"",
               fn _port -> :ok end,
               env: [{"CLAUDE_CODE_ENABLE_TELEMETRY", "1"}]
             )

    assert_receive {^port, {:data, {:eol, "1"}}}, 1_000
  end

  test "registers a spawned port before start_port returns" do
    parent = self()

    assert {:ok, port} =
             Adapter.start_port(File.cwd!(), "sleep 600", fn spawned_port ->
               send(parent, {:port_registered_at_spawn, spawned_port})
               :ok
             end)

    try do
      assert_received {:port_registered_at_spawn, ^port}
    after
      Port.close(port)
    end
  end

  test "start_port/2 caps schedulers for an agent-launched Mix VM" do
    mix = System.find_executable("mix") || flunk("mix executable unavailable")
    elixir = System.find_executable("elixir") || flunk("elixir executable unavailable")
    path = Path.dirname(elixir) <> ":" <> System.get_env("PATH")
    expression = ~S|IO.puts("#{System.get_env("AIUR_AGENT_MIX_SCHEDULERS")}:#{System.schedulers_online()}")|

    assert {:ok, port} =
             Adapter.start_port(
               File.cwd!(),
               "PATH=#{Aiur.Shell.escape(path)} #{Aiur.Shell.escape(mix)} run --no-compile --no-deps-check --no-start -e #{Aiur.Shell.escape(expression)}"
             )

    assert_receive {^port, {:data, {:eol, "4:4"}}}, 20_000
  end

  defp session(port, overrides \\ %{}) do
    Map.merge(
      %{
        port: port,
        metadata: %{backend: :stub},
        thread_id: "thread-1",
        start_turn_result: {:ok, "turn-1"}
      },
      overrides
    )
  end

  defp issue, do: %{id: 123, identifier: "ISSUE-1", title: "Test issue"}

  defp pending_operator_request(request_id, parent) do
    %{
      request_id => %{
        on_success: fn payload -> send(parent, {:accepted, payload.turn_id}) end,
        on_failure: fn reason -> send(parent, {:failed, reason}) end
      }
    }
  end

  defp turn_completed(turn_id) do
    %{
      "method" => "turn/completed",
      "params" => %{"turn" => %{"id" => turn_id, "status" => "completed"}}
    }
  end

  defp send_frames(port, frames) do
    Enum.each(frames, fn payload ->
      send(self(), {port, {:data, {:eol, Jason.encode!(payload)}}})
    end)
  end

  defp cat_port do
    port =
      Port.open({:spawn_executable, String.to_charlist(System.find_executable("cat"))}, [
        :binary,
        :exit_status,
        line: 64_000
      ])

    on_exit(fn ->
      try do
        Port.close(port)
      rescue
        ArgumentError -> :ok
      end
    end)

    port
  end
end
