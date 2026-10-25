defmodule Aiur.BuildOrder.History.ClassificationCostTest do
  use ExUnit.Case, async: true

  alias Aiur.BuildOrder.History.ClassificationCost, as: Cost
  alias Aiur.UsageEnvelope

  defp pilot, do: %{node_id: "I_pilot", number: 123, repo: {"aiur-team", "aiur"}, actor_label: "ws-123"}
  defp now, do: ~U[2026-10-25 00:00:00Z]

  defp summary do
    %{
      health: :healthy,
      scope: %{rejected_tickets: 0},
      coverage: %{selected_cells: 3, projection: %{partial_records: 2}},
      totals: %{tokens: %{input: 900, output: 120}},
      groups: %{by_model: %{"pilot-model" => %{}}}
    }
  end

  defp actor(label, core), do: %{consumer_label: label, consumer_key: "ws-123", core: %{used: core}, graphql: %{used: 2}, search: %{used: 0}}

  defp read(overrides \\ [], pilot \\ pilot()) do
    opts = [
      query_fun: fn %{tickets: [%Aiur.TrackerIdentity{identifier: "123", owner: "aiur-team"}]} -> summary() end,
      usage_fun: fn -> %{actors: [actor("daemon", 99), actor("ws-123", 7)]} end,
      enabled_fun: fn -> true end,
      now: now(),
      dispatched_at: now()
    ]

    Cost.read_sample(pilot, Keyword.merge(opts, overrides))
  end

  defp inputs(overrides \\ %{}),
    do: Map.merge(%{population: 250, sample_size: 100, feature_writes_in_sample: {:known, 80}, epic_writes_in_sample: {:known, 20}, ceilings_per_hour: [60, 125]}, overrides)

  defp hourly(minutes, core), do: %{github: %{core: {:known, core}, graphql: {:known, 0}, search: {:known, 0}}, observed_at: DateTime.add(now(), minutes * 60), dispatched_at: now()}

  test "healthy tokens preserve dimensions and absent dimensions are none_recorded" do
    sample = read()
    assert sample.tokens.input == {:known, 900}
    assert sample.tokens.output == {:known, 120}
    assert sample.tokens.reasoning_output == :none_recorded
    assert Enum.sort(Map.keys(sample.tokens)) == Enum.sort(UsageEnvelope.token_dimensions())
    assert sample.partial_records == 2
    assert sample.model == "pilot-model"
    assert sample.observed_at == now()
    assert sample.dispatched_at == now()
  end

  test "no usage cells or empty token totals are unknown" do
    for summary <- [put_in(summary(), [:coverage, :selected_cells], 0), put_in(summary(), [:totals, :tokens], %{})] do
      assert read(query_fun: fn _ -> summary end).tokens.input == {:unknown, [:no_usage_recorded]}
    end
  end

  test "unhealthy aggregates preserve unknown rather than available totals" do
    for health <- [{:degraded, :recovering}, {:unavailable, :ledger}] do
      assert read(query_fun: fn _ -> %{summary() | health: health} end).tokens.output == {:unknown, [:aggregate_unhealthy]}
    end
  end

  test "rejected and unjoinable pilot identities cannot read known usage" do
    rejected = put_in(summary(), [:scope, :rejected_tickets], 1)
    assert read(query_fun: fn _ -> rejected end).tokens.input == {:unknown, [:ticket_rejected]}
    assert read([query_fun: fn _ -> flunk("unjoinable ticket must not query") end], %{pilot() | node_id: nil}).tokens.input == {:unknown, [:unjoinable_ticket]}
  end

  test "pilot token cells remain known when its own records increase partial coverage" do
    alias Aiur.UsageAggregate.{Projection, Query}
    import Aiur.TestSupport.UsageAggregate, only: [envelope: 1, record: 3]

    {:ok, identity} = Aiur.TrackerIdentity.from_github(%{"node_id" => pilot().node_id, "number" => pilot().number}, pilot().repo, pilot().repo)

    envelope =
      envelope(%{
        occurred_at: nil,
        attribution: %{tracker_identity: identity, run_id: "pilot-run"},
        account_generation: %{provider: :codex, backend: :app_server, generation: nil, freshness: :unknown, health: :unknown, reason: :never_observed}
      })

    baseline = Projection.new()
    projection = Projection.apply_record(baseline, record(1, envelope, %{tokens: %{input: 900, output: 120}}))
    assert baseline.coverage.partial_records == 0
    assert projection.coverage.partial_records == 1
    assert MapSet.member?(projection.coverage.reasons, :missing_trusted_occurrence_time)
    assert MapSet.member?(projection.coverage.reasons, :unknown_account_generation)

    state = %{projection: projection, health: :healthy, freshness: %{}, source_coverage: %{}}
    query = fn scope -> Query.summary(state, scope) end
    sample = read(query_fun: query)
    assert sample.partial_records == 1
    assert sample.tokens.input == {:known, 900}
    assert sample.tokens.output == {:known, 120}
    assert sample.tokens.reasoning_output == :none_recorded
  end

  test "unavailable and disabled broker figures are unknown" do
    assert read(usage_fun: fn -> %{actors: []} end).github.core == {:unknown, [:broker_unavailable]}
    assert read(enabled_fun: fn -> false end, usage_fun: fn -> flunk("disabled broker read") end).github.search == {:unknown, [:broker_disabled]}
  end

  test "actor matching uses label then key and sums matching credentials only" do
    assert read().github == %{core: {:known, 7}, graphql: {:known, 2}, search: {:known, 0}}
    assert read(usage_fun: fn -> %{actors: [actor("", 7)]} end).github.core == {:known, 7}
    assert read(usage_fun: fn -> %{actors: [actor("daemon", 99)]} end).github.core == {:known, 0}
    assert read(usage_fun: fn -> %{actors: [actor("ws-123", 7), actor("ws-123", 4)]} end).github.core == {:known, 11}
  end

  test "future regression guard: each existing reader is called once" do
    {:ok, calls} = Agent.start_link(fn -> [] end)
    record = fn name -> Agent.update(calls, &[name | &1]) end

    read(
      query_fun: fn _ ->
        record.(:query)
        summary()
      end,
      enabled_fun: fn ->
        record.(:enabled)
        true
      end,
      usage_fun: fn ->
        record.(:usage)
        %{actors: [actor("ws-123", 7)]}
      end
    )

    assert Agent.get(calls, &Enum.sort/1) == [:enabled, :query, :usage]
    Agent.stop(calls)
  end

  test "empty population is known zero even when pilot inputs are unknown" do
    sample = read(enabled_fun: fn -> false end)
    assert {:ok, projection} = Cost.project(sample, inputs(%{population: 0, feature_writes_in_sample: {:unknown, [:unmeasured]}}))
    assert projection.runs == 0
    assert Enum.uniq(Map.values(projection.tokens)) == [{:known, 0}]
    assert Enum.uniq(Map.values(projection.per_ticket)) == [{:known, 0}]
    assert Enum.uniq(Map.values(projection.github)) == [{:known, 0}]
    assert projection.feature_writes == {:known, 0}
    assert projection.epic_writes == {:known, 0}
    assert projection.hours == [{:known, 0}, {:known, 0}]
  end

  test "small population equals one measured run and retains model mix" do
    summary = put_in(summary(), [:groups, :by_model], %{"b" => %{}, "a" => %{}})
    sample = read(query_fun: fn _ -> summary end)
    assert sample.model == ["a", "b"]
    assert {:ok, projection} = Cost.project(sample, inputs(%{population: 40, sample_size: 40}))
    assert projection.runs == 1
    assert projection.tokens == sample.tokens
  end

  test "unknown token github or write figure makes projection unknown" do
    sample = read()
    assert Cost.project(put_in(sample, [:tokens, :input], {:unknown, [:aggregate_unhealthy]}), inputs()) == {:unknown, [:aggregate_unhealthy]}
    assert Cost.project(put_in(sample, [:github, :core], {:unknown, [:sampling_gap]}), inputs()) == {:unknown, [:sampling_gap]}
    assert Cost.project(read(), inputs(%{epic_writes_in_sample: {:unknown, [:unmeasured]}})) == {:unknown, [:unmeasured]}
    assert Cost.project(%{sample | tokens: %{}}, inputs()) == {:unknown, [:missing_figures]}
  end

  test "projection rounds runs and each dimension independently" do
    assert {:ok, projection} = Cost.project(read(), inputs())
    assert projection.runs == 3
    assert projection.tokens.input == {:known, 2700}
    assert projection.tokens.output == {:known, 360}
    assert projection.tokens.reasoning_output == :none_recorded
    assert projection.per_ticket.input == {:known, 9}
    assert projection.per_ticket.output == {:known, 2}
    assert projection.github.core == {:known, 21}
    assert projection.feature_writes == {:known, 200}
    assert projection.epic_writes == {:known, 50}
  end

  test "label writes count each label and round hours up" do
    assert {:ok, projection} = Cost.project(read(), inputs(%{population: 100, feature_writes_in_sample: {:known, 101}}))
    assert projection.feature_writes == {:known, 101}
    assert projection.epic_writes == {:known, 20}
    assert projection.hours == [{:known, 2}, {:known, 1}]
    assert projection.hours_with_epic_labels == [{:known, 3}, {:known, 1}]
  end

  test "sampling gaps including the first hour are unknown" do
    assert Cost.github_total([hourly(60, 3), hourly(120, 4), hourly(185, 5)], 3_600_000).core == {:unknown, [:sampling_gap]}
    assert Cost.github_total([hourly(66, 3)], 3_600_000).core == {:unknown, [:sampling_gap]}
    assert Cost.github_total([], 3_600_000).core == {:unknown, [:no_samples]}
    assert Cost.github_total([Map.delete(hourly(60, 3), :dispatched_at)], 3_600_000).core == {:unknown, [:no_dispatch_time]}
  end

  test "hourly samples sum in time order and overlapping samples are upper bounds" do
    total = Cost.github_total([hourly(180, 5), hourly(60, 3), hourly(120, 4)], 3_600_000)
    assert total.core == {:known, 12}
    assert total.bound == :window_sum
    overlap = Cost.github_total([hourly(60, 3), hourly(90, 4)], 3_600_000)
    assert overlap.core == {:known, 7}
    assert overlap.bound == :upper_bound
    unknown = put_in(hourly(120, 4), [:github, :search], {:unknown, [:broker_unavailable]})
    assert Cost.github_total([hourly(60, 3), unknown], 3_600_000).search == {:unknown, [:broker_unavailable]}
  end

  test "invalid projection sizes and ceilings cannot produce figures" do
    assert Cost.project(read(), inputs(%{sample_size: 0})) == {:unknown, [:invalid_population_or_sample_size]}
    assert Cost.project(read(), inputs(%{ceilings_per_hour: [0]})) == {:unknown, [:invalid_ceiling]}
  end
end
