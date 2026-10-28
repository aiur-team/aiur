defmodule AiurWeb.Streamdeck.DeckBuildOrderTest do
  use AiurWeb.StreamdeckChannelCase

  alias Aiur.TestSupport.EndpointStubs
  alias AiurWeb.Streamdeck.Deck

  test "snapshot selects lowest rank then queue id and preserves partial progress" do
    lanes = [lane("later", 2), lane("z", 1), lane("a", 1)]
    EndpointStubs.put(streamdeck_build_queue_fun: fn -> %{status: :running, queues: lanes} end)
    grid = StreamdeckProjection.snapshot()["grid"]
    assert grid["build_status"] == "ok"

    assert grid["build"] == %{
             "queue_id" => "a",
             "name" => "X",
             "kind" => "build_order",
             "completed" => nil,
             "resolved" => 9,
             "total" => 22,
             "percent" => 41,
             "resolution" => "partial",
             "eta_seconds" => nil
           }
  end

  test "empty and zero total lanes are none while failed reads are unavailable" do
    for queues <- [[], [put_in(lane("zero", 1).progress.total, 0)]] do
      EndpointStubs.put(streamdeck_build_queue_fun: fn -> %{status: :running, queues: queues} end)
      assert Deck.read().build_order == %{build: nil, build_status: "none"}
    end

    for read <- [fn -> %{status: :disabled} end, fn -> raise "failed" end, fn -> exit(:unavailable) end] do
      EndpointStubs.put(streamdeck_build_queue_fun: read)
      grid = StreamdeckProjection.snapshot()["grid"]
      assert grid["build"] == nil
      assert grid["build_status"] == "unavailable"
    end
  end

  test "held focus lane retains unknown percent and completed counts" do
    queue = lane("held", 1) |> Map.put(:held, true) |> put_in([:progress, :percent], nil)
    EndpointStubs.put(streamdeck_build_queue_fun: fn -> %{status: :running, queues: [queue]} end)
    assert Deck.read().build_order.build.percent == nil
    assert Deck.read().build_order.build.completed == nil
  end

  test "build topic bursts cause one coalesced read and fleet push" do
    test_pid = self()

    EndpointStubs.put(
      streamdeck_build_queue_fun: fn ->
        send(test_pid, :build_read)
        %{status: :running, queues: []}
      end
    )

    joined_socket()
    assert_receive :build_read, 500

    EndpointStubs.put(
      streamdeck_build_queue_fun: fn ->
        send(test_pid, :build_read)
        %{status: :running, queues: [lane("updated", 1)]}
      end
    )

    for _ <- 1..5 do
      Phoenix.PubSub.broadcast(Aiur.PubSub, "build_progress", {:build_progress_changed, %{}})
      Process.sleep(20)
    end

    assert_push("fleet", %{"grid" => %{build: %{queue_id: "updated", percent: 41}}}, 500)
    assert_receive :build_read, 500
    refute_receive :build_read, 300
    refute_push("fleet", _, 50)

    Phoenix.PubSub.broadcast(Aiur.PubSub, "build_queue:changed", {:build_queue_changed, :running})
    assert_push("fleet", %{"grid" => %{build_status: "ok"}}, 500)
  end

  defp lane(id, rank) do
    %{queue_id: id, set_rank: rank, name: "X", kind: :build_order, progress: %{completed: nil, resolved: 9, total: 22, percent: 41, resolution: :partial}}
  end
end
