defmodule AiurWeb.Build.NativeHoldTest do
  use ExUnit.Case, async: true

  alias Aiur.BuildOrder.TicketStatus
  alias Aiur.TrackerIdentity
  import Aiur.TestSupport.BuildHome.IndexParts
  alias AiurWeb.Build.{IndexReader, NowRows, Payload, URLState}
  alias AiurWeb.Streamdeck.Deck.{Counts, Fleet, TicketActions, Tickets}
  alias AiurWeb.Streamdeck.Render
  alias AiurWeb.StreamdeckLive.CommandKeys

  test "held unit reaches the Build wire and deck key with age and Command navigation, then returns to running" do
    now = DateTime.utc_now()
    {:ok, identity} = TrackerIdentity.from_github(%{"node_id" => "NODE-77", "number" => 77}, {"owner", "repo"}, {"owner", "repo"})
    hold = %{decision_id: "decision-held", since: DateTime.add(now, -420, :second)}
    row = %{identity: identity, runtime: %{bucket: :running, work_state: :working}, reasons: %{native_hold: hold}, open_command_count: 0}
    project = fn row -> NowRows.build(%{status: :ready, snapshot: %{rows: [row]}}, repository: {"owner", "repo"}).rows["77"] end
    held = project.(row)
    assert held.agent.state == "native_question"
    assert held.agent.native_hold == %{decision_id: "decision-held", since: DateTime.to_unix(hold.since, :millisecond)}
    assert TicketStatus.encode(held).label == "Waiting for your answer"

    fixture = File.read!(Path.expand("../../fixtures/build_home/live.json", __DIR__)) |> Jason.decode!()
    [first | rest] = fixture["sections"]["now"]
    message = Payload.snapshot(put_in(fixture, ["sections", "now"], [Map.put(first, "agent", Payload.scrub(held.agent)) | rest]), "held", 0)
    assert Payload.validate(message) == :ok
    assert hd(message["sections"]["now"])["agent"]["native_hold"]["decision_id"] == "decision-held"

    [key] = Tickets.keys(%{now: [held]})
    assert key.bucket == :alert
    counts = Counts.read(window: {:ok, %{sources: %{agents: %{state: "ok"}}, sections: %{now: [held], plan: [], nq: []}}})
    assert Counts.categories(counts).command == 1
    assert Counts.categories(counts).active == 0
    fleet = Fleet.read(window: {:ok, %{sources: %{agents: %{state: "ok"}}, sections: %{now: [held], plan: [], nq: []}}}, global_pause: false)
    needs_command = Enum.find(fleet.keys, &(&1.cat == :command))
    assert needs_command.count == 1
    assert Enum.map(needs_command.tickets, & &1.id) == ["77"]
    image = Render.key(key)
    assert image.label =~ "Waiting for your answer"
    assert image.svg =~ "for 7 min"
    links = TicketActions.links("77", held, nil)
    assert links.modal == AiurWeb.Endpoint.url() <> "/commands/decision-held"
    keys = CommandKeys.ticket_keys(%{"actions" => %{}, "control" => %{}, "links" => %{"modal" => links.modal}, "agent" => %{"native_hold" => hold}}, false)
    assert Enum.at(keys, 5).label == "Open Command"
    assert Enum.at(keys, 5).url == links.modal

    released = project.(put_in(row, [:reasons, :native_hold], nil))
    assert released.agent.state == "active"
    assert released.agent.native_hold == nil
    assert TicketStatus.encode(released).label == "Running"
    [key] = Tickets.keys(%{now: [released]})
    assert Render.key(key).label =~ "Running"
    refute Render.key(key).svg =~ "for 7 min"
    assert TicketActions.links("77", released, nil).modal == AiurWeb.Endpoint.url() <> "/build?ticket=77"
  end

  test "cold fleet fallback preserves a native hold and waiting filters include it" do
    {:ok, identity} = TrackerIdentity.from_github(%{"node_id" => "NODE-77", "number" => 77}, {"owner", "repo"}, {"owner", "repo"})
    hold = %{decision_id: "cold-hold", since: DateTime.utc_now()}

    read =
      IndexReader.read(:all, parts(),
        repository_fun: fn -> {:ok, {"owner", "repo"}} end,
        units_fun: fn -> %{status: :empty, snapshot: %{rows: []}} end,
        running_rows_fun: fn _ -> {:ok, %{statuses: [%{identifier: "77", state: :running, work_state: :working, tracker_identity: identity}], running: [%{identifier: "77", native_hold: hold}]}} end
      )

    assert read.now.rows["77"].agent.state == "native_question"
    assert read.now.rows["77"].agent.native_hold.decision_id == "cold-hold"
    assert "native_question" in URLState.parse(URLState.legacy_preset(%{"conditions" => "alert"})).astate
    assert URLState.parse(%{"astate" => "native_question"}).astate == ["native_question"]
  end

  test "held question with an unknown start renders unavailable duration on the deck" do
    row = %{id: "77", num: 77, sec: "now", agent: %{state: "native_question", native_hold: %{decision_id: "held", since: nil}}}
    [key] = Tickets.keys(%{now: [row]})
    assert Render.key(key).svg =~ "duration unavailable"
    refute Render.key(key).svg =~ "for 0 min"
  end
end
