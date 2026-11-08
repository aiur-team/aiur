defmodule AiurWeb.Streamdeck.TicketActionsTest do
  use AiurWeb.StreamdeckChannelCase
  alias Aiur.TestSupport.EndpointStubs

  defmodule Source do
    def subscribe(_), do: :ok
    def ticket(_, _), do: {:ok, %{title: "A ticket", pr: %{num: 88, state: "open"}}}

    def unit_row(id, _) do
      {:ok,
       %{
         identity: %Aiur.TrackerIdentity{status: :joinable, kind: :github, owner: "acme", repository: "aiur", provider_id: "NODE-77", database_id: 77, identifier: id},
         lifecycle: :active,
         terminal?: false,
         replacement_boundary?: false,
         reasons: %{pause: nil},
         runtime: %{bucket: :running, work_state: :working, tracker_paused?: false}
       }}
    end
  end

  setup do
    {:ok, queue} = start_supervised({Agent, fn -> [11, 22, 77] end})

    EndpointStubs.put(
      streamdeck_build_queue_fun: fn ->
        items = Agent.get(queue, & &1) |> Enum.with_index() |> Enum.map(fn {n, i} -> %{number: n, position: i} end)
        %{status: :running, queues: [%{kind: :list, queue_id: "ops", set_rank: 0, progress: %{total: 0}, name: "ops", items: items}]}
      end,
      streamdeck_reorder_fun: fn id, at ->
        Agent.update(queue, fn ids -> List.insert_at(Enum.reject(ids, &(to_string(&1) == id)), at, String.to_integer(id)) end)
        :ok
      end,
      dashboard_writable: true
    )

    %{queue: queue}
  end

  test "channel emits configured PR and modal links" do
    EndpointStubs.put(streamdeck_build_source: Source)
    socket = joined_socket()
    assert_reply(push(socket, "focus", %{"identifier" => "77"}), :ok, %{"focused" => "77"})
    assert_push("ticket", %{"links" => links, "actions" => actions}, 1_500)
    assert links["pr"] == "https://github.com/acme/aiur/pull/88"
    assert links["modal"] == AiurWeb.Endpoint.url() <> "/build?ticket=77"
    assert actions["priority_up"] == "enabled"
    assert actions["priority_down"] == "disabled"
  end

  test "priority key moves qpos 3 to 2 through the existing queue service", %{queue: queue} do
    socket = joined_socket()
    assert_reply(push(socket, "focus", %{"identifier" => "77"}), :ok, %{"focused" => "77"})
    assert_reply(push(socket, "priority", %{"identifier" => "77", "direction" => "up"}), :ok, %{"position" => 1}, 1_500)
    assert Agent.get(queue, & &1) == [11, 77, 22]
    assert_reply(push(socket, "priority", %{"identifier" => "22", "direction" => "up"}), :error, %{reason: "unavailable"})
    EndpointStubs.put(dashboard_writable: false)
    assert_reply(push(socket, "priority", %{"identifier" => "77", "direction" => "up"}), :error, %{reason: "unavailable"})
    assert Agent.get(queue, & &1) == [11, 77, 22]
  end

  test "read-only, unqueued and missing PR keys expose no mutations" do
    alias AiurWeb.Streamdeck.Deck.TicketActions
    EndpointStubs.put(dashboard_writable: false)
    assert TicketActions.availability("77", %{state: :disabled}) == %{pause: "disabled", priority_up: "disabled", priority_down: "disabled", mic: "disabled"}
    EndpointStubs.put(dashboard_writable: true)
    assert TicketActions.availability("99", nil) == %{pause: "disabled", priority_up: "disabled", priority_down: "disabled", mic: "enabled"}
    assert TicketActions.links("77", nil, nil).pr == nil
  end
end
