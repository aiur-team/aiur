defmodule Aiur.Capacity.PolicyTest do
  use ExUnit.Case, async: true

  alias Aiur.Capacity.Policy

  defp candidate(route, account, used_percent \\ 50, extra \\ %{}) do
    reading = if used_percent, do: Map.merge(%{windows: %{"five_hour" => used_percent}}, extra)
    %{route: route, account: account, reading: reading}
  end

  defp verdicts(candidates, policy, opts \\ []) do
    for {candidate, verdict} <- Policy.decide(candidates, policy, opts), do: {candidate.route, candidate.account, verdict}
  end

  defp reserve(percent, accounts \\ nil),
    do: %{sources: %{"claude" => %{reserve: %{percent: percent, accounts: accounts}}}}

  describe "no capacity config" do
    test "every candidate the floor allows is allowed, including unknown and stale readings" do
      candidates = [
        candidate("codex", "default", 40),
        candidate("claude", "default", nil),
        candidate("claude", "work", 99, %{stale: true}),
        candidate("openrouter", nil, nil)
      ]

      assert Enum.all?(verdicts(candidates, %{}, floor_percent: 5), &match?({_, _, :allow}, &1))
      assert Enum.all?(verdicts(candidates, %{sources: nil}), &match?({_, _, :allow}, &1))
    end

    test "today's floor still holds a route at or below it" do
      assert [{"codex", "default", {:hold, :floor}}] =
               verdicts([candidate("codex", "default", 96)], %{}, floor_percent: 5)
    end
  end

  describe "reserve" do
    test "holds a reserved account at or below its reserve, allows it above" do
      assert [{_, _, {:hold, :reserve}}] = verdicts([candidate("claude", "default", 70)], reserve(30))
      assert [{_, _, {:hold, :reserve}}] = verdicts([candidate("claude", "default", 80)], reserve(30))
      assert [{_, _, :allow}] = verdicts([candidate("claude", "default", 69)], reserve(30))
    end

    test "holds a reserved account on an unknown or stale reading" do
      assert [{_, _, {:hold, :reading_unknown}}] = verdicts([candidate("claude", "default", nil)], reserve(30))

      assert [{_, _, {:hold, :reading_unknown}}] =
               verdicts([candidate("claude", "default", 10, %{stale: true})], reserve(30))

      assert [{_, _, {:hold, :reading_unknown}}] =
               verdicts([%{route: "claude", account: "default", reading: %{windows: %{}}}], reserve(30))
    end

    test "open holds lower the projected remaining; an unknown estimate holds" do
      holds = [%{route: "claude", account: "default", estimate_percent: 5}]
      assert [{_, _, {:hold, :reserve}}] = verdicts([candidate("claude", "default", 66)], reserve(30), holds: holds)

      other = [%{route: "claude", account: "work", estimate_percent: 5}]
      assert [{_, _, :allow}] = verdicts([candidate("claude", "default", 66)], reserve(30), holds: other)

      unknown = [%{route: "claude", account: "default", estimate_percent: nil}]

      assert [{_, _, {:hold, :reading_unknown}}] =
               verdicts([candidate("claude", "default", 10)], reserve(30), holds: unknown)
    end

    test "covers only the listed accounts" do
      candidates = [candidate("claude", "default", 90), candidate("claude", "work", 90)]

      assert [{_, "default", {:hold, :reserve}}, {_, "work", :allow}] =
               verdicts(candidates, reserve(30, ["default"]))
    end
  end

  describe "last resort" do
    @policy %{sources: %{"openrouter" => %{last_resort: true}}}

    test "is deferred while any other candidate is allowed" do
      candidates = [candidate("codex", "default"), candidate("openrouter", nil)]

      assert [{"codex", _, :allow}, {"openrouter", _, {:defer, :last_resort}}] = verdicts(candidates, @policy)
    end

    test "is used when no other candidate is allowed" do
      policy = Map.update!(@policy, :sources, &Map.merge(&1, reserve(30).sources))
      candidates = [candidate("claude", "default", 90), candidate("openrouter", nil)]

      assert [{"claude", _, {:hold, :reserve}}, {"openrouter", _, :allow}] = verdicts(candidates, policy)
    end
  end

  describe "hard limits" do
    @limited %{sources: %{"openrouter" => %{billing: :prepaid, limits: %{daily_usd: 5, monthly_usd: 40}}}}

    test "unknown spend under a set limit holds" do
      assert [{_, _, {:hold, :spend_unknown}}] = verdicts([candidate("openrouter", nil)], @limited)

      assert [{_, _, {:hold, :spend_unknown}}] =
               verdicts([candidate("openrouter", nil)], @limited, spend: %{"openrouter" => %{daily_usd: 1}})
    end

    test "unknown spend with no limit allows" do
      policy = %{sources: %{"openrouter" => %{billing: :prepaid}}}
      assert [{_, _, :allow}] = verdicts([candidate("openrouter", nil)], policy)
    end

    test "a reached limit holds with its period; spend under every limit allows" do
      spend = fn daily, monthly -> [spend: %{"openrouter" => %{daily_usd: daily, monthly_usd: monthly}}] end

      assert [{_, _, {:hold, :limit_daily}}] = verdicts([candidate("openrouter", nil)], @limited, spend.(5, 10))
      assert [{_, _, {:hold, :limit_monthly}}] = verdicts([candidate("openrouter", nil)], @limited, spend.(1, 40))
      assert [{_, _, :allow}] = verdicts([candidate("openrouter", nil)], @limited, spend.(4.99, 39))
    end

    test "the machine-wide limit applies to metered and prepaid sources only" do
      policy = %{
        limits: %{weekly_usd: 20},
        sources: %{"openrouter" => %{billing: "metered"}, "codex" => %{billing: :subscription}}
      }

      candidates = [candidate("codex", "default"), candidate("openrouter", nil)]

      assert [{"codex", _, :allow}, {"openrouter", _, {:hold, :limit_global}}] =
               verdicts(candidates, policy, spend: %{global: %{weekly_usd: 20}})

      assert [{"codex", _, :allow}, {"openrouter", _, {:hold, :spend_unknown}}] = verdicts(candidates, policy)
    end

    test "a limit is checked before the reserve" do
      policy = %{sources: %{"claude" => %{reserve: %{percent: 30}, limits: %{daily_usd: 1}}}}
      assert [{_, _, {:hold, :spend_unknown}}] = verdicts([candidate("claude", "default", 90)], policy)
    end
  end

  describe "serves" do
    test "a source that does not serve the work kind is held" do
      policy = %{sources: %{"codex" => %{serves: [:review]}}}
      assert [{_, _, {:hold, :not_served}}] = verdicts([candidate("codex", "default")], policy)
      assert [{_, _, :allow}] = verdicts([candidate("codex", "default")], policy, kind: :review)
      assert [{_, _, {:hold, :not_served}}] = verdicts([candidate("claude", "default")], %{}, kind: :review)
    end
  end

  test "the module reads no config, process state or files" do
    source = File.read!(Path.join(File.cwd!(), "lib/aiur/capacity/policy.ex"))

    for impure <- ~w(Application. File. Process. :persistent_term :ets GenServer. Agent. Aiur.Config System.) do
      refute source =~ impure, "Aiur.Capacity.Policy references #{impure}"
    end
  end
end
