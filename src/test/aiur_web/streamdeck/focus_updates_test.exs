defmodule AiurWeb.Streamdeck.FocusUpdatesTest do
  use AiurWeb.StreamdeckChannelCase

  setup do
    owner = self()

    put_endpoint_config(
      streamdeck_focus_load_fun: fn
        :logs, _id ->
          %{"transcript" => []}

        :commands, id ->
          send(owner, {:focus_projection_started, id, self()})

          receive do
            :release -> %{"identifier" => id, "items" => []}
          end
      end
    )

    :ok
  end

  test "blocked focus projection leaves input responsive and channel termination cancels its owned task" do
    socket = joined_socket()
    assert_reply(push(socket, "focus", %{"identifier" => "AIUR-1"}), :ok, %{"focused" => "AIUR-1"}, 1_500)
    assert_receive {:focus_projection_started, "AIUR-1", reader}, 1_500
    on_exit(fn -> Process.exit(reader, :kill) end)
    %{assigns: %{focus_task: %{task: task}}} = :sys.get_state(socket.channel_pid)
    assert task.pid == reader
    monitor = Process.monitor(reader)

    assert_reply(push(socket, "input", %{"kind" => "dial_press", "index" => 3}), :ok, %{"view" => "feature"})
    send(socket.channel_pid, :streamdeck_auth_expired)
    assert_receive {:DOWN, ^monitor, :process, ^reader, :killed}, 1_500
  end

  test "superseding focus cancels the previous task and refuses stale data before clearing the completed slot" do
    socket = joined_socket()
    assert_reply(push(socket, "focus", %{"identifier" => "AIUR-1"}), :ok, %{"focused" => "AIUR-1"}, 1_500)
    assert_receive {:focus_projection_started, "AIUR-1", first}, 1_500
    on_exit(fn -> Process.exit(first, :kill) end)
    old_token = :sys.get_state(socket.channel_pid).assigns.focus_token
    first_monitor = Process.monitor(first)

    assert_reply(push(socket, "focus", %{"identifier" => "AIUR-2"}), :ok, %{"focused" => "AIUR-2"})
    assert_receive {:DOWN, ^first_monitor, :process, ^first, :killed}, 1_500
    assert_receive {:focus_projection_started, "AIUR-2", second}, 1_500
    on_exit(fn -> Process.exit(second, :kill) end)
    assert second != first
    assert :sys.get_state(socket.channel_pid).assigns.focus_task.task.pid == second

    send(socket.channel_pid, {:streamdeck_focus_logs, "AIUR-1", old_token, %{"marker" => "stale"}})
    :sys.get_state(socket.channel_pid)
    refute_push("logs", %{"marker" => "stale"}, 50)
    send(second, :release)
    assert_push("commands", %{"identifier" => "AIUR-2", "items" => []}, 1_500)
    assert :sys.get_state(socket.channel_pid).assigns.focus_task == nil
  end

  test "live projection data cannot be overwritten by delayed initial data for the same focus" do
    owner = self()
    identifier = write_transcript("FOCUS-FRESH", "old history", "freshness-turn")
    decision = command_decision(identifier)
    store = start_supervised!(%{id: :focus_commands, start: {FakeDecisionStore, :start_link, [decision, owner]}})

    put_endpoint_config(
      decision_store: store,
      streamdeck_focus_load_fun: fn
        :logs, id ->
          previous = id |> AiurWeb.StreamdeckLogs.load() |> AiurWeb.StreamdeckLogs.wire()
          send(owner, {:initial_focus_read, :logs, self()})

          receive do
            :release_logs -> previous
          end

        :commands, id ->
          previous = AiurWeb.StreamdeckChannel.CommandAnswers.commands_projection(id)
          send(owner, {:initial_focus_read, :commands, self()})

          receive do
            :release_commands -> previous
          end
      end
    )

    socket = joined_socket()
    assert_reply(push(socket, "focus", %{"identifier" => identifier}), :ok, %{"focused" => ^identifier}, 1_500)
    assert_receive {:initial_focus_read, :logs, reader}, 1_500
    on_exit(fn -> Process.exit(reader, :kill) end)
    monitor = Process.monitor(reader)
    path = Aiur.IssueLog.transcript_path(identifier)
    File.write!(path, String.replace(File.read!(path), "old history", "new history"))
    send(socket.channel_pid, {:streamdeck_transcript, identifier, AgentEvents.transcript_event(:assistant, "new history")})
    assert_push("logs", fresh_logs, 1_500)
    assert Enum.any?(fresh_logs["transcript"], &(&1["body"] == "new history"))
    send(reader, :release_logs)
    assert_receive {:initial_focus_read, :commands, ^reader}, 1_500
    :sys.get_state(socket.channel_pid)
    refute_push("logs", _, 50)

    :sys.replace_state(store, fn state -> %{state | decision: %{state.decision | question: "Fresh command", version: state.decision.version + 1}} end)
    send(socket.channel_pid, {:decision_changed, decision.decision_id, 2})
    assert_push("commands", fresh_commands, 1_500)
    assert Enum.any?(fresh_commands["items"], &(&1["question"] == "Fresh command"))
    send(reader, :release_commands)
    assert_receive {:DOWN, ^monitor, :process, ^reader, :normal}, 1_500
    :sys.get_state(socket.channel_pid)
    refute_push("commands", _, 50)
  end
end
