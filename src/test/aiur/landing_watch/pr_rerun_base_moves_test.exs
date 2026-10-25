defmodule Aiur.LandingWatch.PrRerunBaseMovesTest do
  use ExUnit.Case, async: true

  alias Aiur.LandingWatch.PrRerunClassifier

  test "future regression guard: two main moves without a passing check do not refresh a mergeable PR" do
    started = DateTime.utc_now() |> DateTime.to_unix(:millisecond)

    history = [
      %{completed_at: started - 60_000, checks: [%{name: "required CI", conclusion: "failure"}]},
      %{completed_at: started + 60_000, checks: [%{name: "required CI", conclusion: "failure"}]},
      %{completed_at: started + 120_000, checks: [%{name: "required CI", conclusion: "failure"}]}
    ]

    failed_run = %{"name" => "required CI", "conclusion" => "failure", "started_at" => DateTime.from_unix!(started, :millisecond) |> DateTime.to_iso8601()}

    refute PrRerunClassifier.stale_merge_ref?(failed_run, main_history_fun: fn -> history end)
  end
end
