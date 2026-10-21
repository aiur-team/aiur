defmodule AiurWeb.Build.NowRowsTest do
  use ExUnit.Case, async: true
  alias Aiur.TrackerIdentity
  alias AiurWeb.Build.{NowRows, Payload}
  @repo {"owner", "repo"}
  @time "2026-10-07T21:20:00Z"
  @ms 1_791_408_000_000

  test "state precedence covers every table row and unknown command count" do
    cases = [
      {row(%{runtime: %{bucket: :running, work_state: :error}}), "error"},
      {row(%{runtime: %{bucket: :running, work_state: :paused}, open_command_count: 2}), "command"},
      {row(%{reasons: %{pause: :ci_wait}}), "parked"},
      {row(%{reasons: %{pause: :operator_pause}}), "paused"},
      {row(%{open_command_count: nil}), "active"},
      {row(%{runtime: %{bucket: :running, work_state: :deactivated}}), nil}
    ]

    for {input, expected} <- cases do
      result = facts(input)
      assert result.agent.state == expected
      assert result.status == if(expected == "error", do: "failed", else: if(expected == "retrying", do: "queued", else: "running"))
    end
  end

  test "policy stuck reasons beat command and paused; retry backoff stays distinct from failure" do
    for waiting <- [:tracker_unavailable, :backing_off, :unresponsive] do
      assert facts(row(%{reasons: %{waiting: waiting, pause: :operator_pause}, open_command_count: 1})).agent.state == "error"
    end

    retrying = facts(row(%{runtime: %{bucket: :retrying, work_state: :retrying}}))
    assert retrying.agent.state == "retrying"
    assert retrying.status == "queued"
    assert facts(row(%{reasons: %{waiting: :waiting_for_human}})).agent.state == "command"
    assert facts(row(%{runtime: %{bucket: :running, work_state: :starting}})).agent.state == "active"
  end

  test "parked reasons use the orchestrator predicate; cooperative pauses stay paused" do
    for reason <- [:ci_wait, :blocker_dependency, :max_agent_duration, :usage_limit_exhausted, :github_budget_hold] do
      assert facts(row(%{reasons: %{pause: reason}})).agent.state == "parked"
    end

    for reason <- [:operator_pause, :global_pause, :label_override, :agent_pause_request] do
      assert facts(row(%{reasons: %{pause: reason}})).agent.state == "paused"
    end

    assert facts(row(%{runtime: %{bucket: :running, work_state: :sleeping}})).agent.state == "paused"
  end

  test "queued, finished, replacement and unjoinable identities are excluded" do
    inputs = [
      row(%{runtime: %{bucket: :idle}, reasons: %{waiting: :awaiting_dispatch}}),
      row(%{terminal?: true}),
      row(%{replacement_boundary?: true}),
      row(%{runtime: %{bucket: :idle}, reasons: %{waiting: :latched_lifetime}}),
      row(%{identity: nil}),
      row(%{runtime: %{bucket: :idle}, reasons: %{waiting: :waiting_for_human}, open_command_count: 1})
    ]

    assert NowRows.build(catalog(inputs), repository: @repo).rows == %{}
  end

  test "spent lifetime retries with no live agent are excluded from Now" do
    retry = row(%{runtime: %{bucket: :idle}, reasons: %{waiting: :latched_lifetime}})
    assert NowRows.build(catalog([retry]), repository: @repo).rows == %{}
  end

  test "repository matching is case insensitive and excludes same-number foreign tickets" do
    assert NowRows.build(catalog([row()]), repository: {"OWNER", "REPO"}).rows["1"].num == 1
    assert NowRows.build(catalog([row()]), repository: {"other", "repo"}).rows == %{}
  end

  test "unknown progress stays nil including absent field; numeric progress rounds only in range" do
    for input <- [row(%{progress: %{status: :unknown}}), Map.delete(row(), :progress)] do
      assert Map.fetch!(facts(input), :pct) == nil
    end

    for {value, expected} <- [{70.5, 71}, {0, 0}, {100, 100}, {140, nil}, {-0.1, nil}, {"50", nil}] do
      assert facts(row(%{progress: %{status: :known, percent: value, freshness: :stale}})).pct == expected
    end
  end

  test "unknown model has no fabricated label; registry families and product efforts survive" do
    assert facts(row(%{agent_family: nil, backend: nil, resolved_model: "claude-opus-5-1"})).agent ==
             %{model: nil, name: nil, state: "active", effort: nil}

    assert facts(row(%{agent_family: "muse"})).agent.model == "muse"
    assert facts(row(%{agent_family: "muse"})).agent.name == "Muse"
    assert facts(row(%{agent_family: nil, backend: "codex"})).agent.name == "Codex"
    assert facts(row(%{agent_family: :bogus, backend: "codex"})).agent.model == "codex"
    assert facts(row(%{agent_family: :bogus, backend: "codex"})).agent.name == "Codex"
    for value <- ~w(none minimal low medium high xhigh max), do: assert(facts(row(%{effort: value})).agent.effort == value)
    assert facts(row(%{effort: :high})).agent.effort == "high"
    assert facts(row(%{effort: "<b>"})).agent.effort == nil
  end

  test "start is parsed in milliseconds with no clock fallback" do
    assert facts(row(%{timestamps: %{started_at: @time}})).start == @ms
    assert facts(row(%{timestamps: %{started_at: DateTime.from_unix!(div(@ms, 1000))}})).start == @ms
    for time <- [nil, "garbage"], do: assert(facts(row(%{timestamps: %{started_at: time}})).start == nil)
    assert facts(Map.delete(row(), :timestamps)).start == nil
  end

  test "all 25 agents are emitted with numeric ordering" do
    rows = for n <- 1..25, do: row(%{identity: identity(n)})
    output = NowRows.build(catalog(rows), repository: @repo).rows
    assert map_size(output) == 25
    for n <- 1..25, do: assert(output[to_string(n)].ord == n)
  end

  test "empty, unavailable, stale and truncated catalogs preserve source truth" do
    empty = NowRows.build(catalog([], :empty), repository: @repo)
    assert empty == %{rows: %{}, source: %{state: "ok", observed_at: @ms, reason: nil}}

    assert NowRows.build(catalog([row()], :unavailable), repository: @repo) ==
             %{rows: %{}, source: %{state: "unavailable", observed_at: nil, reason: "fleet_unavailable"}}

    stale = NowRows.build(catalog([row()], :stale), repository: @repo)
    assert map_size(stale.rows) == 1
    assert stale.source == %{state: "stale", observed_at: @ms, reason: "fleet_stale"}
    assert NowRows.build(Map.put(catalog([]), :truncated?, true), repository: @repo).source.reason == "membership_truncated"

    for freshness <- [%{status: :unknown}, %{status: %{observed_at: "garbage"}}, %{}] do
      input = put_in(catalog([]), [:snapshot, :freshness], freshness)
      assert NowRows.build(input, repository: @repo).source.observed_at == nil
    end
  end

  test "bad catalog or missing/malformed repository is unavailable without raising" do
    for input <- [nil, %{}, catalog([], :bogus)] do
      assert NowRows.build(input, repository: @repo) ==
               %{rows: %{}, source: %{state: "unavailable", observed_at: nil, reason: "fleet_unavailable"}}
    end

    for repo <- [nil, "owner/repo", {"", "repo"}, {"owner/repo", "repo"}, {7, "repo"}] do
      assert NowRows.build(catalog([row()]), repository: repo) ==
               %{rows: %{}, source: %{state: "unavailable", observed_at: nil, reason: "repository_unknown"}}
    end
  end

  test "eight design agents match data parity and validate after joining" do
    fixture = File.read!(Path.expand("../../fixtures/build_home/live.json", __DIR__)) |> Jason.decode!()
    expected_rows = Enum.reject(fixture["sections"]["now"], &(&1["agent"]["state"] == "retries"))
    inputs = Enum.map(expected_rows, &design_row/1)
    output = NowRows.build(catalog(inputs), repository: @repo).rows
    assert map_size(output) == 7

    joined =
      Enum.map(expected_rows, fn expected ->
        actual = Payload.scrub(output[expected["id"]])
        assert Map.take(actual, ~w(agent pct)) == Map.take(expected, ~w(agent pct))
        assert abs(actual["start"] - expected["start"]) <= 1
        merged = Map.merge(expected, actual)
        assert Payload.row(merged) == {:ok, merged}
        merged
      end)

    assert Payload.validate(put_in(fixture, ["sections", "now"], joined)) == :ok
  end

  test "a retry-backoff agent row validates inside a full snapshot" do
    fixture = File.read!(Path.expand("../../fixtures/build_home/live.json", __DIR__)) |> Jason.decode!()
    [first | rest] = fixture["sections"]["now"]
    built = row(%{identity: identity(first["num"]), runtime: %{bucket: :retrying, work_state: :retrying}})
    actual = Payload.scrub(NowRows.build(catalog([built]), repository: @repo).rows[first["id"]])
    assert actual["agent"]["state"] == "retrying"
    message = Payload.snapshot(put_in(fixture, ["sections", "now"], [Map.merge(first, actual) | rest]), "epoch", 0)
    assert Payload.validate(message) == :ok
  end

  defp design_row(expected) do
    base =
      row(%{
        identity: identity(expected["num"]),
        agent_family: expected["agent"]["model"],
        effort: expected["agent"]["effort"],
        progress: %{status: :known, percent: expected["pct"]},
        timestamps: %{started_at: DateTime.from_unix!(expected["start"], :millisecond)}
      })

    case expected["agent"]["state"] do
      "error" -> %{base | runtime: %{bucket: :running, work_state: :error}}
      "retries" -> %{base | runtime: %{bucket: :idle}, reasons: %{waiting: :latched_lifetime}, timestamps: %{}}
      "command" -> %{base | open_command_count: 1}
      "parked" -> %{base | reasons: %{pause: :ci_wait}}
      "paused" -> %{base | reasons: %{pause: :operator_pause}}
      "active" -> base
    end
  end

  defp facts(row), do: NowRows.build(catalog([row]), repository: @repo).rows["1"]
  defp catalog(rows, status \\ :ready), do: %{status: status, truncated?: false, snapshot: %{rows: rows, freshness: %{status: %{observed_at: @time}}}}

  defp row(attrs \\ %{}),
    do:
      Map.merge(
        %{
          identity: identity(1),
          terminal?: false,
          replacement_boundary?: false,
          runtime: %{bucket: :running, work_state: :working},
          reasons: %{},
          open_command_count: 0,
          agent_family: :codex,
          effort: nil
        },
        attrs
      )

  defp identity(n) do
    {:ok, identity} = TrackerIdentity.from_github(%{"node_id" => "I_#{n}", "number" => n}, @repo, @repo)
    identity
  end
end
