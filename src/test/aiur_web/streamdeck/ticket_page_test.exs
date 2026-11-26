defmodule AiurWeb.Streamdeck.TicketPageTest do
  use AiurWeb.StreamdeckChannelCase
  alias Aiur.BuildOrder.Index
  alias Aiur.TestSupport.EndpointStubs
  alias AiurWeb.Streamdeck.Deck.TicketPage

  defmodule Source do
    alias Aiur.BuildOrder.Index
    alias Aiur.TrackerIdentity
    def subscribe(_opts), do: Index.subscribe()
    def ticket(id, opts), do: Agent.get(opts[:fixture], &Map.fetch(&1, id))

    def unit_row(id, _opts) do
      {:ok,
       %{
         identity: %TrackerIdentity{status: :joinable, kind: :github, owner: "acme", repository: "aiur", provider_id: "NODE-77", database_id: 77, identifier: id},
         lifecycle: :active,
         terminal?: false,
         replacement_boundary?: false,
         reasons: %{pause: nil},
         runtime: %{bucket: :running, work_state: :working, tracker_paused?: false}
       }}
    end
  end

  setup do
    {:ok, fixture} = start_supervised({Agent, fn -> %{"77" => row("ci_wait")} end})
    source = {Source, fixture: fixture}
    EndpointStubs.put(streamdeck_build_source: source, dashboard_writable: false)
    %{fixture: fixture, source: source}
  end

  test "focus pushes the desktop Build label and open PR, and shared changes refresh it", %{fixture: fixture} do
    socket = joined_socket()
    assert_reply(push(socket, "focus", %{"identifier" => "77"}), :ok, %{"focused" => "77"})
    assert_push("ticket", %{"id" => "77", "status" => %{"label" => "Waiting for CI"}, "pr" => %{"num" => 88, "ci" => "pr_opened"}}, 1_500)

    Agent.update(fixture, &Map.put(&1, "77", row("ci-red")))
    Index.broadcast(%{})
    assert_push("ticket", %{"id" => "77", "status" => %{"label" => "agent:ci-red"}}, 1_500)

    Agent.update(fixture, &Map.put(&1, "77", row("merge-queued")))
    send(socket.channel_pid, :fleet_changed)
    assert_push("ticket", %{"status" => %{"label" => "agent:merge-queued"}}, 1_000)

    assert_reply(push(socket, "unfocus", %{}), :ok, %{"focused" => nil})
    Index.broadcast(%{})
    :sys.get_state(socket.channel_pid)
    refute_push("ticket", _, 50)
  end

  test "DTO preserves missing PR and agent facts, read-only control and observation time", %{fixture: fixture, source: source} do
    Agent.update(fixture, &Map.put(&1, "77", %{row("parked") | pr: nil, agent: nil}))
    dto = TicketPage.read("77", build_source: source, now: 1234)
    assert dto["pr"] == nil
    assert dto["agent"] == nil
    assert dto["status"] == %{"label" => "State unknown", "tone" => "idle", "agent_state" => nil}
    assert dto["observed_at"] == 1234
    assert dto["control"]["state"] == "disabled"
    assert dto["control"]["title"] == "Dashboard is read-only"
    EndpointStubs.put(dashboard_writable: true)
    assert TicketPage.read("77", build_source: source)["control"]["state"] == "enabled"
  end

  test "unavailable source does not invent status or PR", %{source: source} do
    dto = TicketPage.read("missing", build_source: source)
    assert dto["pr"] == nil
    assert dto["title"] == nil
    assert dto["status"]["label"] == "State unknown"
  end

  defp row(state) do
    %{
      id: "77",
      title: "Shared ticket",
      sec: "now",
      qpos: nil,
      pct: 72,
      start: 123,
      agent: %{state: state, model: "codex", name: "Codex", effort: "high"},
      pr: %{num: 88, state: "open", ci: "pr_opened"}
    }
  end
end
