defmodule AiurWeb.Streamdeck.TicketUpdatesTest do
  use AiurWeb.StreamdeckChannelCase
  alias Aiur.TestSupport.EndpointStubs

  defmodule BlockingSource do
    def subscribe(opts) do
      send(opts[:observer], {:ticket_subscriber, opts[:subscriber]})
      :ok
    end

    def ticket(id, opts) do
      send(opts[:observer], {:ticket_reader, self(), id})

      receive do
        :release -> {:ok, %{id: id, title: "Ticket #{id}", sec: "now", agent: %{state: "ci_wait"}, pr: nil, pct: nil, start: nil, qpos: nil}}
      end
    end

    def unit_row(_id, _opts), do: {:error, :not_found}
  end

  setup do
    EndpointStubs.put(streamdeck_build_source: {BlockingSource, observer: self()})
    :ok
  end

  test "a blocked ticket read leaves Commands and unfocus responsive, and cannot push after unfocus" do
    socket = joined_socket()
    assert_reply(push(socket, "focus", %{"identifier" => "77"}), :ok, %{"focused" => "77"})
    assert_receive {:ticket_subscriber, owner}, 1_500
    assert owner == socket.channel_pid
    assert_receive {:ticket_reader, reader, "77"}, 1_500
    assert_push("commands", _page, 1_500)

    assert_reply(push(socket, "unfocus", %{}), :ok, %{"focused" => nil})
    %{assigns: %{ticket_task: %{task: task}}} = :sys.get_state(socket.channel_pid)
    monitor = Process.monitor(task.pid)
    send(reader, :release)
    assert_receive {:DOWN, ^monitor, :process, _pid, :normal}, 1_500
    :sys.get_state(socket.channel_pid)
    refute_push("ticket", _, 50)
  end

  test "refresh bursts coalesce behind one read and stale focus results cannot replace the new ticket" do
    socket = joined_socket()
    assert_reply(push(socket, "focus", %{"identifier" => "77"}), :ok, %{"focused" => "77"})
    assert_receive {:ticket_reader, first, "77"}, 1_500
    for _ <- 1..5, do: send(socket.channel_pid, {:build_changes, %{}})
    assert_reply(push(socket, "focus", %{"identifier" => "88"}), :ok, %{"focused" => "88"})
    :sys.get_state(socket.channel_pid)
    refute_received {:ticket_reader, _reader, "88"}
    send(first, :release)
    assert_receive {:ticket_reader, second, "88"}, 1_500
    refute_push("ticket", %{"id" => "77"}, 50)
    send(second, :release)
    assert_push("ticket", %{"id" => "88", "status" => %{"label" => "Waiting for CI"}}, 1_500)
    refute_receive {:ticket_reader, _reader, _id}, 50
  end

  test "refocusing the same id cannot publish a result from the previous focus token" do
    socket = joined_socket()
    assert_reply(push(socket, "focus", %{"identifier" => "77"}), :ok, %{"focused" => "77"})
    assert_receive {:ticket_reader, first, "77"}, 1_500
    assert_reply(push(socket, "focus", %{"identifier" => "77"}), :ok, %{"focused" => "77"})
    :sys.get_state(socket.channel_pid)
    send(first, :release)
    assert_receive {:ticket_reader, second, "77"}, 1_500
    refute_push("ticket", %{"id" => "77"}, 50)
    send(second, :release)
    assert_push("ticket", %{"id" => "77"}, 1_500)
  end

  test "a failed reader emits unknown facts and channel termination cancels an owned read" do
    socket = joined_socket()
    assert_reply(push(socket, "focus", %{"identifier" => "77"}), :ok, %{"focused" => "77"})
    assert_receive {:ticket_reader, _reader, "77"}, 1_500
    %{assigns: %{ticket_task: %{task: task}}} = :sys.get_state(socket.channel_pid)
    Process.exit(task.pid, :kill)
    assert_push("ticket", %{"id" => "77", "pr" => nil, "agent" => nil, "status" => %{"label" => "State unknown"}}, 1_500)

    send(socket.channel_pid, {:build_changes, %{}})
    assert_receive {:ticket_reader, _reader, "77"}, 1_500
    %{assigns: %{ticket_task: %{task: task}}} = :sys.get_state(socket.channel_pid)
    monitor = Process.monitor(task.pid)
    send(socket.channel_pid, :streamdeck_auth_expired)
    assert_receive {:DOWN, ^monitor, :process, _pid, :killed}, 1_500
  end
end
