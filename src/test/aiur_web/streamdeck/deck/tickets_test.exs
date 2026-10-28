defmodule AiurWeb.Streamdeck.Deck.TicketsTest do
  use ExUnit.Case, async: true
  alias AiurWeb.Build.PayloadSchema
  alias AiurWeb.Streamdeck.Deck
  alias AiurWeb.Streamdeck.Deck.{Input, Nav, Tickets}
  alias AiurWeb.Streamdeck.Render
  alias AiurWeb.StreamdeckLive.Surface

  test "attention order, numeric ties, reason states, unknown, then queue order with no duplicate or unfiled ticket" do
    now = Enum.with_index(~w(paused parked usage_limited ci_wait active retrying command error merge-queued mystery), 10) |> Enum.map(fn {s, n} -> row(n, s) end)
    now = [row(3, "error"), row(20, nil) | now]
    plan = [queued(30, 2), queued(10, 0), queued(31, 1), %{queued(99, 3) | num: nil}]
    keys = Tickets.keys(%{now: now, plan: plan, nq: [row(90, nil)]})
    assert Enum.map(keys, & &1.id) == ~w(3 17 16 15 14 13 12 11 10 18 19 20 31 30)
    assert Enum.map(Enum.take(keys, -2), &{&1.state, &1.label, &1.face}) == [{:queued, "Queued #1", :queued}, {:queued, "Queued #2", :queued}]
    assert Enum.count(keys, &(&1.id == "10")) == 1
  end

  test "every schema state and nil has the shared Build label and face, including reason and unknown states" do
    {:nullable, {:object, agent, _}} = PayloadSchema.row()["agent"]
    {:nullable, {:enum, states}} = agent["state"]
    taxonomy = File.read!("priv/static/build-home/ticket-status.json") |> Jason.decode!()

    for state <- states ++ [nil, "mystery"] do
      [key] = Tickets.keys(%{now: [row(1, state)]})
      expected = taxonomy["agent"][state] || taxonomy["unknown"]
      assert key.label == expected["label"]
      image = Render.key(key)
      assert image.svg =~ key.label
      assert image.label =~ key.label
      colors = %{active: "#9fd0ff", stuck: "#ff9a90", idle: "#c2c6cf", queued: "#9096a4", unknown: "#c2c6cf"}
      assert image.svg =~ Map.fetch!(colors, key.face)
      [emulator | _] = Surface.key_descriptors([key], 0)
      assert emulator.style =~ "--sd-accent: #{Map.fetch!(colors, key.face)}"
      expected_face = if expected["cls"], do: String.to_existing_atom(expected["cls"]), else: :unknown
      assert key.face == expected_face
      if state in [nil, "mystery"], do: assert(key.face == :unknown)
    end

    assert [%{label: "agent:merge-queued"}] = Tickets.keys(%{now: [row(1, "merge-queued")]})
    assert [%{label: "State unknown", face: :unknown}] = Tickets.keys(%{now: [row(1, "mystery")]})
  end

  test "unknown progress has no bar or zero while a measured zero remains visible" do
    [key] = Tickets.keys(%{now: [row(1, "ci_wait")]})
    assert key.pct == nil
    assert key.progress_percent == nil
    assert key.model == "Codex"
    image = Render.key(key)
    refute image.svg =~ "progress-track"
    refute image.svg =~ "progress-fill"
    refute image.label =~ "0%"
    [zero] = Tickets.keys(%{now: [Map.put(row(1, "active"), :pct, 0)]})
    assert zero.pct == 0
    assert Render.key(zero).svg =~ "progress-fill"
    assert Render.key(zero).label =~ "0%"
  end

  test "filters retain global ordering and Now ownership, and key presses open the projected ticket" do
    sections = %{now: [row(10, "ci_wait"), row(2, "command")], plan: [queued(10, 1), queued(30, 2)]}
    assert Enum.map(Tickets.keys(sections, {:feature, "deck"}), & &1.id) == ~w(2 10 30)
    assert Tickets.keys(sections, {:epic, "other"}) == []
    assert Enum.map(Tickets.keys(sections, {:epic, "ui"}), & &1.id) == ~w(2 10 30)
    assert Enum.map(Tickets.keys(sections, {:state, "ci_wait"}), & &1.id) == ["10"]
    assert Enum.map(Tickets.keys(sections, {:state, :queued}), & &1.id) == ["30"]
    grid = %{agents: Tickets.keys(sections)}
    assert {%Nav{selected: "2"}, [{:open_ticket, "2"}]} = Input.reduce(%Nav{}, %{"kind" => "key_press", "index" => 0}, Deck.navigation(grid))
    wire = sections |> Jason.encode!() |> Jason.decode!()
    assert Tickets.keys(wire) == Tickets.keys(sections)
  end

  test "queue positions do not replace Now state labels and update backlog labels" do
    [now, queued] = Tickets.keys(%{now: [row(10, "ci_wait")], plan: [queued(30, 2)]})

    for key <- [now, queued] do
      image = key |> Map.put(:queue_position, 0) |> Render.key()
      expected = if key.state == :queued, do: "Queued #1", else: key.label
      assert image.label =~ expected
      assert image.svg =~ expected
    end
  end

  defp row(num, state), do: %{id: to_string(num), num: num, sec: "now", title: "Ticket #{num}", feature: "deck", epic: "ui", pct: nil, agent: %{state: state, model: "codex", name: nil}}
  defp queued(num, pos), do: row(num, nil) |> Map.merge(%{sec: "plan", qpos: pos, agent: nil})
end
