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
end
