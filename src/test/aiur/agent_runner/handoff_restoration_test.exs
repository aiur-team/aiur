defmodule Aiur.AgentRunner.HandoffRestorationTest do
  use Aiur.TestSupport

  alias Aiur.AgentRunner.{Handoff, SessionLifecycle}
  alias Aiur.AgentRunner.Handoff.ProviderState
  alias Aiur.Claude.CodingAgent.Methods
  alias Aiur.Claude.DisplayTailer
  alias Aiur.Codex.NotificationPolicy
  alias Aiur.Codex.TurnLoopTestSupport
  alias Aiur.Issue

  test "portable provider sessions regain callable clocks and handle notifications after adoption" do
    issue = %Issue{id: "clock", identifier: "CLOCK-1"}
    port = TurnLoopTestSupport.open_cat_port()

    try do
      for backend <- ["codex", "claude"] do
        original = %{backend: backend, workspace: File.cwd!(), metadata: %{}, clock: &DateTime.utc_now/0}
        session = original |> Handoff.encode() |> Handoff.decode() |> Map.put(:port, port) |> ProviderState.restore_session(issue)
        assert is_function(session.clock, 0)
        assert %DateTime{} = session.clock.()

        if backend == "codex" do
          assert %DateTime{} = NotificationPolicy.reset_opts(session)[:now]
          assert :handled = session.account_generation_notification_handler.(%{"method" => "account/updated", "params" => %{"authMode" => "chatgpt"}})
        else
          params = %{"provider_error" => %{"error" => "model_not_found"}}
          payload = %{"method" => "turn/failed", "params" => params}
          state = %{pending_operator_requests: %{}, on_message: fn _ -> :ok end}
          assert {:error, {:turn_failed, ^params}} = Methods.handle_method(session, state, payload, Jason.encode!(payload), "turn/failed")
        end
      end
    after
      TurnLoopTestSupport.close_port(port)
    end
  end

  test "a fresh VM safely decodes private provider atoms after loading application modules" do
    encoded = Handoff.encode(%{interrupt_idle_seen?: true})

    script = """
    Code.ensure_loaded!(Aiur.AgentRunner.Handoff)
    [encoded] = System.argv()
    baseline = try do
      :erlang.binary_to_term(Base.decode64!(encoded), [:safe])
      "unexpected-safe"
    rescue
      ArgumentError -> "cold-missing"
    end
    decoded = Aiur.AgentRunner.Handoff.decode(encoded)
    IO.write(baseline <> ":" <> to_string(Map.fetch!(decoded, String.to_existing_atom("interrupt_idle_seen?"))))
    """

    paths = Enum.flat_map(:code.get_path(), fn path -> ["-pa", to_string(path)] end)
    assert {"cold-missing:true", 0} = System.cmd(System.find_executable("elixir"), paths ++ ["-e", script, encoded], env: [{"ERL_FLAGS", "+S 2:2 +SDio 1 +SDcpu 1"}], stderr_to_stdout: true)
  end

  @tag :tmp_dir
  test "an adopted display tailer restores its source and renders newly appended agent prose", %{tmp_dir: root} do
    identifier = "DISPLAY-#{System.unique_integer([:positive])}"
    path = Path.join(root, "transcript.jsonl")
    File.write!(path, assistant_line("Before restart"))
    old = start_supervised!({DisplayTailer, identifier: identifier, on_message: fn _ -> :ok end, interval_ms: nil})
    send(old, {:claude_hook, identifier, %{transcript_path: path, session_id: "kept-session"}})
    assert {:ok, 1} = DisplayTailer.poll(old)
    saved = old |> DisplayTailer.handoff_state() |> Handoff.encode() |> Handoff.decode()
    assert saved.path == path
    assert saved.cursor.offset == byte_size(assistant_line("Before restart"))
    :ok = stop_supervised(DisplayTailer)
    :ok = Aiur.AgentPubSub.subscribe_agent(identifier)
    session = %{backend: "claude-repl", remote_control: true, thread_id: "kept-session"}
    issue = %Issue{id: identifier, identifier: identifier}
    {tailer, opts} = SessionLifecycle.start_adopted_display(session, issue, handoff_display_state: saved)

    try do
      assert is_pid(tailer)
      assert opts[:live_conversation_authority] == :display_tailer
      assert opts[:live_conversation_source_resolver].() == "kept-session"
      File.write!(path, assistant_line("Agent output after daemon restart"), [:append])
      assert {:ok, count} = DisplayTailer.poll(tailer)
      assert count >= 1
      assert_receive {:transcript_event, %{role: :assistant, body: "Agent output after daemon restart"}}, 1_000
      refute_receive {:transcript_event, %{body: "Before restart"}}, 50
    after
      SessionLifecycle.stop_display_tailer(tailer)
    end
  end

  defp assistant_line(text) do
    Jason.encode!(%{"type" => "assistant", "message" => %{"content" => [%{"type" => "text", "text" => text}]}, "timestamp" => "2026-10-14T12:00:00Z"}) <> "\n"
  end
end
