defmodule AiurWeb.Streamdeck.DeckCountsTest do
  use AiurWeb.StreamdeckChannelCase
  alias Aiur.BuildOrder.Index, as: BuildIndex
  alias Aiur.TestSupport.EndpointStubs
  alias AiurWeb.Streamdeck.Deck.Counts

  test "counts NowRows and planned sections preserving unknown and reason states" do
    stub(window())
    assert Counts.read() == %{status: "ok", observed_at: 123, agents: 3, live: 2, queued: 5, not_queued: 2, by_state: %{"active" => 2, "ci_wait" => 1}}
    stub(put_in(window(), [:sections, :now], [%{"agent" => %{"state" => nil}}, %{agent: %{state: "merge-queued"}}]))
    assert %{agents: 2, live: 0, by_state: %{"unknown" => 1, "merge-queued" => 1}} = Counts.read()
  end

  test "failed unavailable and crashed reads retain unknown numbers" do
    for read <- [
          fn _, _, _ -> {:error, :offline} end,
          fn _, _, _ -> {:ok, put_in(window(), [:sources, :agents, :state], "unavailable")} end,
          fn _, _, _ -> raise "offline" end,
          fn _, _, _ -> exit(:offline) end
        ] do
      EndpointStubs.put(streamdeck_build_window_fun: read)
      assert Counts.read() == %{status: "unavailable", observed_at: nil, agents: nil, live: nil, queued: nil, not_queued: nil, by_state: nil}
    end
  end

  test "stale numbers reach snapshot" do
    stub(put_in(window(), [:sources, :agents, :state], "stale"))
    counts = StreamdeckProjection.snapshot()["grid"]["counts"]
    assert counts["status"] == "stale"
    assert counts["live"] == 2
    assert counts["agents"] == 3
    assert counts["observed_at"] == 123
  end

  test "index updates coalesce to one counts read and fleet push" do
    owner = self()

    EndpointStubs.put(
      streamdeck_build_window_fun: fn _, _, _ ->
        send(owner, :counts_read)
        {:ok, window()}
      end
    )

    socket = joined_socket()
    receive_barrier(:counts_read)
    for _ <- 1..5, do: BuildIndex.broadcast(%{index_generation: 2})
    state = :sys.get_state(socket.channel_pid)
    token = state.assigns.fleet_flush
    send(socket.channel_pid, {:flush_fleet, token})
    :sys.get_state(socket.channel_pid)
    assert_push("fleet", %{"grid" => %{counts: %{agents: 3, live: 2, queued: 5}}})
    assert_received :counts_read
    refute_received :counts_read
  end

  defp stub(data), do: EndpointStubs.put(streamdeck_build_window_fun: fn _, _, _ -> {:ok, data} end)

  defp window do
    %{
      sources: %{agents: %{state: "ok", observed_at: 123}},
      sections: %{now: [%{agent: %{state: "active"}}, %{agent: %{state: "active"}}, %{agent: %{state: "ci_wait"}}], plan: List.duplicate(%{}, 5), nq: List.duplicate(%{}, 2)}
    }
  end
end
