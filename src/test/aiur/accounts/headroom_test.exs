defmodule Aiur.Accounts.HeadroomTest do
  use ExUnit.Case, async: true

  alias Aiur.Accounts.Headroom

  @codex %{backend: "codex", account: nil}
  @claude_default %{backend: "claude", account: "default"}
  @claude_everdred %{backend: "claude", account: "everdred"}
  # agent.priority order: claude first, then codex.
  @candidates [@claude_default, @claude_everdred, @codex]

  defp used(percent_by_window), do: %{windows: percent_by_window}

  defp readings(overrides) do
    Map.merge(
      %{
        {"codex", nil} => used(%{"weekly" => 95}),
        {"claude", "default"} => used(%{"five_hour" => 0, "seven_day" => 0}),
        {"claude", "everdred"} => used(%{"five_hour" => 10, "seven_day" => 36})
      },
      overrides
    )
  end

  defp chosen(candidates \\ @candidates, overrides) do
    {:ok, %{candidate: candidate}, _ranked} = Headroom.select(candidates, readings(overrides))
    candidate
  end

  describe "issue #3960 acceptance" do
    test "unknown usage ranks ahead of known accounts so it can be observed" do
      assert chosen(%{{"codex", nil} => nil}) == @codex
    end

    test "with Claude/default exhausted it picks Claude/everdred" do
      assert chosen(%{{"claude", "default"} => used(%{"five_hour" => 100, "seven_day" => 40})}) == @claude_everdred
    end

    test "with all Claude exhausted it picks Codex" do
      assert chosen(%{
               {"claude", "default"} => %{limited: true},
               {"claude", "everdred"} => used(%{"seven_day" => 100})
             }) == @codex
    end

    test "the score is headroom, not list order: the last candidate wins when it has the most left" do
      assert chosen([@codex, @claude_everdred, @claude_default], %{}) == @claude_default

      assert chosen(%{
               {"codex", nil} => used(%{"weekly" => 1}),
               {"claude", "default"} => used(%{"seven_day" => 50})
             }) == @codex
    end
  end

  describe "ranking" do
    test "the binding window is the most-used window" do
      [first | _] = Headroom.rank([@claude_everdred], readings(%{}))

      assert first.binding_window == "seven_day"
      assert_in_delta first.remaining, 0.64, 0.0001
      assert first.status == :known
    end

    test "unknown usage ranks above known usage at or below 10% left and above exhausted" do
      candidates = [@codex, @claude_default, @claude_everdred]

      ranked =
        Headroom.rank(candidates, %{
          {"codex", nil} => used(%{"weekly" => 95}),
          {"claude", "default"} => nil,
          {"claude", "everdred"} => %{limited: true}
        })

      assert Enum.map(ranked, &{&1.candidate, &1.status}) == [
               {@claude_default, :unknown},
               {@codex, :low},
               {@claude_everdred, :exhausted}
             ]
    end

    test "a recently explored unknown account ranks below every healthy known account" do
      ranked =
        Headroom.rank(@candidates, %{
          {"codex", nil} => %{limited: true},
          {"claude", "default"} => %{explored: true},
          {"claude", "everdred"} => used(%{"seven_day" => 74})
        })

      assert Enum.map(ranked, &{&1.candidate, &1.status}) == [
               {@claude_everdred, :known},
               {@claude_default, :unknown},
               {@codex, :exhausted}
             ]
    end

    test "an exhausted candidate is never chosen" do
      assert {:error, :all_exhausted, ranked} =
               Headroom.select(@candidates, %{
                 {"codex", nil} => %{limited: true},
                 {"claude", "default"} => used(%{"five_hour" => 100}),
                 {"claude", "everdred"} => used(%{"seven_day" => 120})
               })

      assert Enum.all?(ranked, &(&1.status == :exhausted))
      assert {:error, :all_exhausted, []} = Headroom.select([], %{})
    end

    test "ties keep the input (priority) order" do
      tie = used(%{"seven_day" => 20})
      readings = %{{"claude", "default"} => tie, {"claude", "everdred"} => tie, {"codex", nil} => tie}

      assert {:ok, %{candidate: @claude_default}, _} = Headroom.select(@candidates, readings)
      assert {:ok, %{candidate: @codex}, _} = Headroom.select([@codex | @candidates -- [@codex]], readings)
    end
  end

  describe "explanation" do
    test "the summary names the choice and every alternative's score, and says unknown instead of a number" do
      {:ok, chosen, ranked} = Headroom.select(@candidates, readings(%{{"codex", nil} => nil}))

      assert Headroom.summary(chosen, ranked) ==
               "headroom: codex=unknown; alternatives claude/default=100%, claude/everdred=64%"
    end

    test "the summary for an all-exhausted claim lists every candidate" do
      {:error, :all_exhausted, ranked} = Headroom.select([@codex], %{{"codex", nil} => %{limited: true}})
      assert Headroom.summary(nil, ranked) == "headroom: no candidate has usage left (codex=exhausted)"
    end

    test "remaining_percent/1 reports the binding window, or nil when unknown" do
      assert Headroom.remaining_percent(used(%{"five_hour" => 30, "seven_day" => 64})) == 36
      assert Headroom.remaining_percent(%{limited: true}) == 0
      assert Headroom.remaining_percent(nil) == nil
      assert Headroom.remaining_percent(used(%{"seven_day" => nil})) == nil
    end
  end
end
