defmodule Aiur.Capacity.PeriodSpendTest do
  @moduledoc "Per-period USD spend per source from the usage aggregate, and the hard limits it feeds (#7958)."

  use ExUnit.Case, async: true

  alias Aiur.Capacity.PeriodSpend
  alias Aiur.CodingAgent.CapacityGate
  alias Aiur.ProviderAccountGeneration.Snapshot
  alias Aiur.TestSupport.GroupedScopes, as: Support
  alias Aiur.TestSupport.UsageAggregate, as: Aggregate
  alias Aiur.Usage.Headless.{Context, DeepSeek}

  @today ~D[2026-11-11]
  @candidate %{backend: "deepseek", account: nil, route: "deepseek"}

  defp record(position, date, tokens \\ %{input: 1_000_000}), do: Support.deepseek_record(position, pricing_date: date, tokens: tokens)

  defp policy(limits), do: %{sources: %{"deepseek" => %{billing: "metered", limits: limits}}}

  defp spend(policy, records), do: PeriodSpend.spend(policy, usage_source: Support.source(records), today: @today)

  defp verdict(limit, records) do
    opts = [capacity_policy: policy(%{daily_usd: limit}), usage_source: Support.source(records), today: @today, ledger_store: nil, usage_floor: 0]
    [entry] = CapacityGate.evaluate([@candidate], %{}, opts).entries
    {entry.verdict, entry.reason}
  end

  test "a source with a daily limit dispatches under its recorded spend and holds once it reaches the limit" do
    one_turn = spend(policy(%{daily_usd: 100}), [record(1, @today)])["deepseek"].daily_usd
    assert is_float(one_turn) and one_turn > 0

    limit = one_turn * 2
    assert verdict(limit, [record(1, @today)]) == {:allow, nil}
    assert verdict(limit, [record(1, @today), record(2, @today)]) == {:hold, :limit_daily}
    # Yesterday's spend is not today's.
    assert verdict(limit, [record(1, @today), record(2, Date.add(@today, -1))]) == {:allow, nil}
  end

  test "days, Monday-start weeks and calendar months each count their own spend" do
    # 2026-11-11 is a Wednesday: the week starts 11-09, the month 11-01.
    records = [record(1, @today), record(2, ~D[2026-11-09]), record(3, ~D[2026-11-02]), record(4, ~D[2026-10-31])]
    one = spend(policy(%{daily_usd: 1}), [record(1, @today)])["deepseek"].daily_usd

    assert %{daily_usd: d, weekly_usd: w, monthly_usd: m} = spend(policy(%{daily_usd: 1}), records)["deepseek"]
    assert_in_delta d, one, 1.0e-9
    assert_in_delta w, one * 2, 1.0e-9
    assert_in_delta m, one * 3, 1.0e-9
  end

  test "global spend sums metered and prepaid sources only" do
    policy = %{
      sources: %{"deepseek" => %{billing: "prepaid"}, "openrouter" => %{billing: "subscription"}},
      limits: %{daily_usd: 1}
    }

    one = spend(policy(%{daily_usd: 1}), [record(1, @today)])["deepseek"].daily_usd
    records = [record(1, @today), Support.openrouter_record(2, pricing_date: @today, tokens: %{input: 1_000_000})]
    assert_in_delta spend(policy, records).global.daily_usd, one, 1.0e-9
  end

  test "an unavailable aggregate is unknown spend, and no limit reads nothing" do
    assert spend(policy(%{daily_usd: 1}), []) == %{"deepseek" => %{daily_usd: 0.0, weekly_usd: 0.0, monthly_usd: 0.0}}
    assert PeriodSpend.spend(policy(%{daily_usd: 1}), usage_source: nil, today: @today)["deepseek"].daily_usd == :unknown
    assert PeriodSpend.spend(%{sources: %{"deepseek" => %{billing: "metered"}}}, usage_source: nil) == %{}
  end

  test "ticket_usd is the ticket's own spend, unknown without an identity" do
    one = spend(policy(%{daily_usd: 1}), [record(1, @today)])["deepseek"].daily_usd

    source =
      Support.source([
        Support.deepseek_record(1, ticket: 1, pricing_date: @today, tokens: %{input: 1_000_000}),
        Support.deepseek_record(2, ticket: 2, pricing_date: @today, tokens: %{input: 1_000_000})
      ])

    assert_in_delta PeriodSpend.ticket_usd(Support.identity(1), usage_source: source), one, 1.0e-9
    assert PeriodSpend.ticket_usd(nil, usage_source: source) == :unknown
  end

  test "stop_new_turns? applies source and machine-wide limits; unknown spend under a limit stops" do
    metered = %{sources: %{"deepseek" => %{billing: "metered", limits: %{weekly_usd: 10}}}, limits: %{daily_usd: 3}}

    refute PeriodSpend.stop_new_turns?("deepseek", metered, %{"deepseek" => %{weekly_usd: 9.0}, global: %{daily_usd: 2.0}})
    assert PeriodSpend.stop_new_turns?("deepseek", metered, %{"deepseek" => %{weekly_usd: 10.0}, global: %{daily_usd: 2.0}})
    assert PeriodSpend.stop_new_turns?("deepseek", metered, %{"deepseek" => %{weekly_usd: 9.0}, global: %{daily_usd: 3.0}})
    assert PeriodSpend.stop_new_turns?("deepseek", metered, %{"deepseek" => %{weekly_usd: :unknown}, global: %{daily_usd: 2.0}})
    # A subscription has no USD cost: neither its own limits nor the machine-wide ones stop it.
    subscription = %{sources: %{"claude" => %{billing: "subscription", limits: %{daily_usd: 1}}}, limits: %{daily_usd: 3}}
    refute PeriodSpend.stop_new_turns?("claude", subscription, %{"claude" => %{daily_usd: 5.0}, global: %{daily_usd: 5.0}})
  end

  test "a subscription source is not measured even with a limits block" do
    assert PeriodSpend.spend(%{sources: %{"claude" => %{billing: "subscription", limits: %{daily_usd: 1}}}}, usage_source: nil) == %{}
  end

  test "undated usage of a measured provider makes every period unknown, and holds a limited source" do
    undated = update_in(record(2, @today), [:envelope], &%{&1 | occurred_at: nil, pricing_effective_date: nil})
    records = [record(1, @today), undated]

    assert spend(policy(%{daily_usd: 1}), records)["deepseek"] == %{daily_usd: :unknown, weekly_usd: :unknown, monthly_usd: :unknown}
    assert verdict(1_000, records) == {:hold, :spend_unknown}
    # Another provider's undated usage does not touch this source.
    other = update_in(Support.openrouter_record(3, pricing_date: @today), [:envelope], &%{&1 | occurred_at: nil, pricing_effective_date: nil})
    assert verdict(1_000, [record(1, @today), other]) == {:allow, nil}
  end

  test "a completed OpenAI-compatible request becomes dated, priced spend for its source and ticket" do
    completed_at = ~U[2026-11-11 09:30:00Z]

    payload = %{
      "request_id" => "req-1",
      "model" => "deepseek-v4-flash",
      "completed_at" => completed_at,
      "usage" => %{"prompt_tokens" => 1_000_000, "completion_tokens" => 0, "total_tokens" => 1_000_000}
    }

    assert [{:ok, envelope}] = DeepSeek.RequestUsage.extract(payload, nil, context(Support.identity(5)), DateTime.add(completed_at, 1))
    assert envelope.pricing_effective_date == @today
    source = Support.source([Aggregate.record(1, envelope, %{tokens: %{input: 1_000_000}})])

    daily = PeriodSpend.spend(policy(%{daily_usd: 1}), usage_source: source, today: @today)["deepseek"].daily_usd
    assert is_float(daily) and daily > 0
    assert_in_delta PeriodSpend.ticket_usd(Support.identity(5), usage_source: source), daily, 1.0e-9
  end

  defp context(identity) do
    %Context{
      run_id: "run-1",
      tracker_identity: identity,
      agent_family: :deepseek,
      backend: :openai_compat,
      transport: :openai_compat,
      auth_mode: :api_key,
      requested_model: "deepseek-v4-flash",
      resolved_model: "deepseek-v4-flash",
      account_generation: Context.project_generation(Snapshot.unavailable(:deepseek, :openai_compat), :deepseek, :openai_compat),
      source_sequence: 1
    }
  end
end
