defmodule AiurWeb.Streamdeck.Deck.FeaturesProjectionTest do
  use AiurWeb.StreamdeckChannelCase
  alias Aiur.TestSupport.EndpointStubs
  alias AiurWeb.StreamdeckProjection

  test "one Build read supplies feature keys, navigation frames and member ticket actions" do
    owner = self()

    window = %{
      sources: %{agents: %{state: "ok"}},
      sections: %{
        now: [],
        plan: [
          %{id: "1", num: 1, title: "Outsider", sec: "plan", epic: "other", qpos: 0},
          %{id: "88", num: 88, title: "Member", sec: "plan", epic: "lane", qpos: 1}
        ],
        nq: []
      },
      order: ["lane"],
      features: %{"parent" => %{label: "Parent", epics: ["lane"]}},
      feature_progress: %{
        observed_at: System.system_time(:millisecond) - 120_000,
        features: %{"lane" => %{feature: "parent", label: "Lane", closed: 12, open: 5, unpublished: 3, ci_wait: 0, total: 20}}
      }
    }

    EndpointStubs.put(
      streamdeck_build_window_fun: fn _, _, _ ->
        send(owner, :window_read)
        {:ok, window}
      end
    )

    assert [%{"id" => "parent", "pct" => 60, "tickets" => [%{"id" => "88"}]}] = StreamdeckProjection.snapshot()["grid"]["features"]
    assert_received :window_read
    refute_received :window_read
    socket = joined_socket()
    assert_reply(push(socket, "input", %{"kind" => "dial_press", "index" => 3}), :ok, reply)
    assert reply["view"] == "feature"
    assert hd(reply["frame"].keys).svg =~ ">60%</text>"
    assert hd(reply["frame"].strip).svg =~ "age 2m"
    assert_reply(push(socket, "input", %{"kind" => "key_press", "index" => 0}), :ok, reply)
    assert hd(reply["frame"].keys).label =~ "Member"
    assert_reply(push(socket, "input", %{"kind" => "key_press", "index" => 0}), :ok)
    assert :sys.get_state(socket.channel_pid).assigns.deck_effects == [{:open_ticket, "88"}]
    EndpointStubs.put(streamdeck_build_queue_fun: fn -> %{status: :disabled, queues: []} end)
    assert_reply(push(socket, "input", %{"kind" => "dial_turn", "index" => 1, "ticks" => -1}), :error, priority)
    assert hd(priority.frame.keys).label =~ "Member"
    assert hd(priority.frame.strip).label == "queue disabled"
    assert_reply(push(socket, "input", %{"kind" => "dial_long_press", "index" => 3}), :ok, reply)
    assert hd(reply["frame"].keys).svg =~ ">60%</text>"
  end
end
