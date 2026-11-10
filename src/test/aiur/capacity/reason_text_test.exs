defmodule Aiur.Capacity.ReasonTextTest do
  use ExUnit.Case, async: true

  alias Aiur.Capacity.ReasonText

  @codes ~w(preferred only_allowed last_resort_used pinned reserve limit_daily limit_weekly limit_monthly
            limit_global balance_exhausted spend_unknown reading_unknown floor limited not_served)

  test "each reason code renders its own text" do
    texts = Enum.map(@codes, &ReasonText.reason/1)
    assert length(Enum.uniq(texts)) == length(@codes)
    assert Enum.all?(texts, &(&1 not in @codes or &1 in ["preferred", "pinned", "limited"]))
    assert ReasonText.reason(:reserve) == "Executor reserve"
  end

  test "the chosen source shows its reason and reading" do
    record = %{
      "chosen" => %{"route" => "codex", "account" => "default", "reason" => "preferred"},
      "candidates" => [%{"route" => "codex", "account" => "default", "verdict" => "allow", "reading" => %{"remaining_percent" => 62, "age_s" => 40}}]
    }

    assert ReasonText.chosen(record) == "codex/default (preferred; 62% left, 40s old)"
    assert ReasonText.waiting(record) == nil
  end

  test "an unknown reading renders unknown with its age, never a number" do
    record = %{
      chosen: %{route: "claude", account: "max", reason: :only_allowed},
      candidates: [%{route: "claude", account: "max", verdict: :allow, reading: %{remaining_percent: nil, age_s: 900}}]
    }

    text = ReasonText.chosen(record)
    assert text == "claude/max (only allowed source; usage unknown, 15m old)"
    refute text =~ ~r/\d+%/
  end

  test "a last-resort choice names why every other source was passed over" do
    record = %{
      chosen: %{route: "openrouter", account: nil, reason: "last_resort_used"},
      candidates: [
        %{route: "claude", account: "default", verdict: "hold", reason: "reserve", detail: "projected 27% <= reserve 30%"},
        %{route: "codex", account: "default", verdict: "hold", reason: "limited", detail: "until 18:00"},
        %{route: "openrouter", account: nil, verdict: "allow"}
      ]
    }

    assert ReasonText.chosen(record) ==
             "openrouter (last resort; claude/default Executor reserve (projected 27% <= reserve 30%); codex/default limited (until 18:00))"
  end

  test "a queued ticket with every source held lists one clause per source" do
    record = %{
      chosen: nil,
      candidates: [
        %{route: "claude", account: "default", verdict: "hold", reason: "reserve", detail: "projected 27% <= reserve 30%"},
        %{route: "codex", account: "default", verdict: "hold", reason: "reading_unknown", reading: %{remaining_percent: nil, age_s: nil}},
        %{route: "openrouter", account: nil, verdict: "hold", reason: "limit_daily"}
      ]
    }

    assert ReasonText.chosen(record) == nil

    assert ReasonText.waiting(record) ==
             "waiting: no authorized source: claude/default Executor reserve (projected 27% <= reserve 30%); " <>
               "codex/default usage unknown (usage unknown, never read); openrouter daily spend limit reached"
  end

  test "a headroom row's flat reading renders, and unknown stays unknown" do
    record = %{
      chosen: %{route: "codex", account: nil, reason: :preferred},
      candidates: [
        %{route: "codex", account: nil, verdict: :allow, remaining_percent: 62, age_seconds: 40},
        %{route: "claude", account: "max", verdict: :allow, remaining_percent: nil, age_seconds: 3600}
      ]
    }

    assert ReasonText.chosen(record) == "codex (preferred; 62% left, 40s old)"
    assert ReasonText.chosen(%{record | chosen: %{route: "claude", account: "max", reason: :preferred}}) == "claude/max (preferred; usage unknown, 60m old)"
  end

  test "a limited candidate counts as held although its verdict is allow" do
    record = %{
      candidates: [
        %{route: "codex", account: nil, verdict: :allow, reason: :limited, detail: "usage-limited"},
        %{route: "claude", account: "default", verdict: :hold, reason: :reserve}
      ]
    }

    assert ReasonText.waiting(record) == "waiting: no authorized source: codex limited (usage-limited); claude/default Executor reserve"
  end

  test "no record renders nothing" do
    assert ReasonText.chosen(nil) == nil
    assert ReasonText.waiting(%{candidates: []}) == nil
  end
end
