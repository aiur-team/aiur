defmodule Aiur.AppServer.AdapterTest do
  use ExUnit.Case, async: true

  alias Aiur.AppServer.Adapter

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

  test "run_turn returns success with session identifiers" do
    port = cat_port()
    send(self(), {port, {:data, {:eol, Jason.encode!(%{"method" => "turn/completed"})}}})

    assert {:ok, result} = Adapter.run_turn(StubBackend, session(port), "prompt", issue(), [])
    assert result.result == :turn_completed
    assert result.thread_id == "thread-1"
    assert result.turn_id == "turn-1"
    assert result.session_id == "thread-1-turn-1"
  end

  test "run_turn passes paused payload through with session_id" do
    port = cat_port()
    send(self(), {port, {:data, {:eol, Jason.encode!(%{"method" => "pause"})}}})

    assert {:paused, %{request_id: 1, session_id: "thread-1-turn-1"}} =
             Adapter.run_turn(StubBackend, session(port), "prompt", issue(), [])
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

  test "registers a spawned port before start_port returns" do
    parent = self()

    assert {:ok, port} =
             Adapter.start_port(File.cwd!(), "sleep 600", fn spawned_port ->
               send(parent, {:port_registered_at_spawn, spawned_port})
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
