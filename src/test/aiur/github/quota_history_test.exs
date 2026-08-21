defmodule Aiur.GitHub.QuotaHistoryTest do
  @moduledoc """
  The quota sampler's contract: it records measurements, bounds them, and stays
  silent about anything it has not observed.
  """

  use ExUnit.Case, async: true

  alias Aiur.GitHub.QuotaHistory

  @now ~U[2030-01-01 12:00:00Z]
  @reset ~U[2030-01-01 12:30:00Z]

  test "records nothing at all while the meter has observed no window" do
    history = start(fn -> %{state: :unknown, windows: %{}} end)

    QuotaHistory.sample(history)
    QuotaHistory.sample(history)

    # Empty means "the sampler has not observed anything". A row of zeroes here
    # would draw a flat line under a budget that may be exhausted.
    assert QuotaHistory.samples(history) == []
  end

  test "a meter that goes silent stops the ring rather than fabricating a point" do
    {:ok, agent} = Agent.start_link(fn -> :observed end)
    history = start(fn -> if Agent.get(agent, & &1) == :observed, do: snapshot(), else: %{} end)

    QuotaHistory.sample(history)
    recorded = length(QuotaHistory.samples(history))

    Agent.update(agent, fn _state -> :gone end)
    QuotaHistory.sample(history)

    assert length(QuotaHistory.samples(history)) == recorded
  end

  test "survives a meter that raises or is not running" do
    raising = start(fn -> raise "no meter" end)
    exiting = start(fn -> exit(:noproc) end)

    QuotaHistory.sample(raising)
    QuotaHistory.sample(exiting)

    assert QuotaHistory.samples(raising) == []
    assert QuotaHistory.samples(exiting) == []
    assert Process.alive?(raising)
    assert Process.alive?(exiting)
  end

  test "keeps a bounded ring, oldest dropped first" do
    counter = :counters.new(1, [])

    history =
      start(fn -> snapshot() end,
        capacity: 3,
        clock: fn ->
          :counters.add(counter, 1, 1)
          DateTime.add(@now, :counters.get(counter, 1), :second)
        end
      )

    for _sample <- 1..6, do: QuotaHistory.sample(history)

    samples = QuotaHistory.samples(history)
    assert length(samples) == 3
    assert Enum.map(samples, & &1.t_ms) == Enum.sort(Enum.map(samples, & &1.t_ms))
  end

  test "samples carry the per-caller breakdown and the unissued remainder" do
    history = start(fn -> snapshot() end)
    QuotaHistory.sample(history)

    graphql = history |> QuotaHistory.samples() |> List.last() |> Map.fetch!(:budgets) |> Map.fetch!("graphql")

    assert graphql.attributed == 93
    assert graphql.outside == 4_907
    assert Enum.map(graphql.callers, & &1.caller) == ["comment_poll_batch"]
  end

  # The page's central claim is that viewing costs nothing, and a sampler that
  # could fetch would break it on a timer rather than on a click. The constraint
  # is structural, so it is asserted structurally.
  test "the sampler cannot reach a GitHub client at all" do
    code =
      "../../../lib/aiur/github/quota_history.ex"
      |> Path.expand(__DIR__)
      |> File.read!()
      |> String.replace(~r/@moduledoc\s+"""(.|\n)*?"""/, "")

    refute code =~ "Aiur.GitHub.Client"
    refute code =~ "Req."
    refute code =~ "token"
    refute code =~ "HTTP"
  end

  defp start(snapshot_fun, opts \\ []) do
    start_supervised!(
      {QuotaHistory,
       Keyword.merge(
         [name: nil, interval_ms: 0, clock: fn -> @now end, snapshot_fun: snapshot_fun],
         opts
       )},
      id: {:quota_history, System.unique_integer([:positive])}
    )
  end

  defp snapshot do
    %{
      state: :observed,
      windows: %{"graphql" => %{limit: 5_000, remaining: 0, used: 5_000, reset_at: @reset}},
      callers: [
        %{caller: :comment_poll_batch, resource: "graphql", points: 93, calls: 9, points_per_hour: 1.0, estimated?: false}
      ],
      coverage: %{resources: %{"graphql" => %{attributed: 93, spend: 5_000}}},
      reconciliation: %{"graphql" => %{direction: :shortfall}}
    }
  end
end
