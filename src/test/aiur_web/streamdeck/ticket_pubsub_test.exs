defmodule AiurWeb.Streamdeck.TicketPubsubTest do
  use AiurWeb.StreamdeckChannelCase

  test "repeated focus and unfocus retain one bounded Build index subscription" do
    socket = joined_socket()
    channel = socket.channel_pid
    %{assigns: %{fleet_latch: latch}} = :sys.get_state(channel)

    for id <- ~w(77 88 99 101 102) do
      assert_reply(push(socket, "focus", %{"identifier" => id}), :ok, %{"focused" => ^id}, 1_500)
      assert_push("chat", %{"id" => ^id}, 1_500)
      assert_reply(push(socket, "unfocus", %{}), :ok, %{"focused" => nil}, 1_500)
      :sys.get_state(channel)
    end

    registrations = Registry.lookup(Aiur.PubSub, "build-home:index") |> Enum.filter(fn {pid, _metadata} -> pid == channel end)
    assert registrations == [{channel, {:fleet_refresh, latch}}]
  end
end
