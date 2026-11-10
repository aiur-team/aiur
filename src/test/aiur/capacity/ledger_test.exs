defmodule Aiur.Capacity.LedgerTest do
  use ExUnit.Case, async: true

  alias Aiur.Capacity.Ledger

  @t0 ~U[2026-11-09 12:00:00Z]

  defp at(seconds), do: DateTime.add(@t0, seconds, :second)
  defp claude(ticket, created_at, estimate), do: %{ticket: ticket, backend: "claude", account: "default", kind: :window, estimate: estimate, rate: 4.0, created_at: created_at}
  defp reserve(ledger, attrs, reading), do: Ledger.claim(ledger, attrs, reading, threshold: 30, fail_closed: true)

  describe "claim/4" do
    test "two claims inside one poll interval cannot both pass a reserve the reading alone would let both pass" do
      reading = %{remaining: 35, observed_at: @t0}

      # The reading alone (35 > 30) lets each claim pass on its own.
      assert {:allow, _} = reserve(Ledger.new(), claude(2, at(60), 8), reading)

      assert {:allow, ledger} = reserve(Ledger.new(), claude(1, at(30), 8), reading)
      assert {{:hold, :reserve}, held} = reserve(ledger, claude(2, at(60), 8), reading)
      assert Map.keys(held.holds) == [1]
    end

    test "an unknown estimate on a reserved account holds further workers until the next reading" do
      reading = %{remaining: 80, observed_at: @t0}
      assert {:allow, ledger} = reserve(Ledger.new(), claude(1, at(30), :unknown), reading)
      assert {{:hold, :reading_unknown}, _} = reserve(ledger, claude(2, at(60), 8), reading)

      # Unreserved: recorded but not subtracted.
      assert {:allow, ledger} = Ledger.claim(Ledger.new(), claude(1, at(30), :unknown), reading)
      assert Ledger.projected_remaining(ledger, {"claude", "default"}, reading, false) == 80
    end

    test "an unknown reading holds a fail-closed scope and allows an open one" do
      reading = %{remaining: :unknown, observed_at: nil}
      assert {{:hold, :reading_unknown}, _} = reserve(Ledger.new(), claude(1, @t0, 8), reading)
      assert {:allow, _} = Ledger.claim(Ledger.new(), claude(1, @t0, 8), reading)
    end

    test "usd holds count against the source and the total limit" do
      usd = fn ticket, backend, est -> %{ticket: ticket, backend: backend, kind: :usd, estimate: est, created_at: at(10)} end
      spend = %{remaining: 5.0, observed_at: @t0}

      assert {:allow, ledger} = Ledger.claim(Ledger.new(), usd.(1, "openrouter", 3.0), spend, reason: :limit_daily)
      assert {:allow, ledger} = Ledger.claim(ledger, usd.(2, "deepseek", 1.5), spend, reason: :limit_daily)
      assert {{:hold, :limit_daily}, _} = Ledger.claim(ledger, usd.(3, "openrouter", 3.0), %{spend | remaining: 3.0}, reason: :limit_daily)
      assert Ledger.projected_remaining(ledger, :usd_total, spend, true) == 0.5
    end
  end

  describe "observe_reading/4" do
    test "a fresh reading folds older holds and reconciles each with estimate and actual" do
      ledger =
        Ledger.new()
        |> Ledger.observe_reading("claude", "default", %{used_percent: 50, observed_at: @t0})
        |> Ledger.hold(claude(1, @t0, 8))
        |> Ledger.hold(claude(2, at(3600), 8))

      reading = %{remaining: 50, observed_at: @t0}
      assert Ledger.projected_remaining(ledger, {"claude", "default"}, reading, true) == 42

      # One hour later: ticket 1 ran 1h, ticket 2 0h; used rose by 6 → 6%/agent-hour.
      ledger = Ledger.observe_reading(ledger, "claude", "default", %{used_percent: 56, observed_at: at(3600)})
      assert Ledger.projected_remaining(ledger, {"claude", "default"}, %{remaining: 44, observed_at: at(3600)}, true) == 44

      assert [%{ticket: t2, estimate: 4.0, actual: 6.0}, %{ticket: t1, estimate: 4.0, actual: 6.0}] = ledger.reconciles
      assert Enum.sort([t1, t2]) == [1, 2]
      assert Ledger.learned_burn(ledger, "claude", "default") == 6.0

      # A later reading does not reconcile the same holds again; it updates the EWMA.
      ledger = Ledger.observe_reading(ledger, "claude", "default", %{used_percent: 60, observed_at: at(7200)})
      assert length(ledger.reconciles) == 2
      assert_in_delta Ledger.learned_burn(ledger, "claude", "default"), 0.3 * 2.0 + 0.7 * 6.0, 1.0e-9
    end

    test "a window reset records an unknown actual and learns nothing" do
      ledger =
        Ledger.new()
        |> Ledger.observe_reading("claude", "default", %{used_percent: 90, observed_at: @t0})
        |> Ledger.hold(claude(1, at(10), 8))
        |> Ledger.observe_reading("claude", "default", %{used_percent: 5, observed_at: at(3600)})

      assert [%{ticket: 1, actual: :unknown}] = ledger.reconciles
      assert Ledger.learned_burn(ledger, "claude", "default") == nil
    end
  end

  test "turn_ended replaces a usd estimate with the recorded spend and reconciles" do
    ledger = Ledger.hold(Ledger.new(), %{ticket: 7, backend: "openrouter", kind: :usd, estimate: 2.0, created_at: at(10)})
    ledger = Ledger.turn_ended(ledger, 7, 0.75, at(600))

    assert ledger.holds[7].estimate == 0.75
    assert [%{ticket: 7, kind: :usd, estimate: 2.0, actual: 0.75, at: ended}] = ledger.reconciles
    assert ended == at(600)
  end

  test "restart rebuilds holds from running agents" do
    running = [
      %{ticket: 1, backend: "claude", account: "default", kind: :window, created_at: at(-600)},
      %{ticket: 2, backend: "openrouter", kind: :usd, created_at: at(-60)}
    ]

    ledger =
      Ledger.rebuild(running, fn
        %{kind: :window} -> Ledger.window_estimate(nil, 5, 2)
        %{kind: :usd} -> {Ledger.usd_estimate([1.0, 3.0, 2.0], 9.0), nil}
      end)

    assert %{1 => %{estimate: 10, rate: 5, created_at: started}, 2 => %{estimate: 2.0}} = ledger.holds
    assert started == at(-600)

    # The rebuilt holds subtract from a reading older than them and fold into a newer one.
    assert Ledger.projected_remaining(ledger, {"claude", "default"}, %{remaining: 40, observed_at: at(-900)}, true) == 30
    assert Ledger.projected_remaining(ledger, {"claude", "default"}, %{remaining: 40, observed_at: @t0}, true) == 40
  end

  test "release closes a stopped agent's hold" do
    ledger = Ledger.new() |> Ledger.hold(claude(1, at(10), 8)) |> Ledger.release(1)
    assert ledger.holds == %{}
  end

  test "a hard USD limit stops new turns once crossed or when spend is unknown" do
    refute Ledger.stop_new_turns?(4.99, 5)
    assert Ledger.stop_new_turns?(5.0, 5)
    assert Ledger.stop_new_turns?(:unknown, 5)
    refute Ledger.stop_new_turns?(:unknown, nil)
  end
end
