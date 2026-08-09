defmodule AiurWeb.StreamdeckProjectionTest do
  use ExUnit.Case, async: true

  alias Aiur.CodingAgent
  alias AiurWeb.StreamdeckProjection

  @now ~U[2026-08-09 12:00:00Z]

  test "keeps distinct session and weekly readings for every registry provider" do
    meters = %{
      claude: observed_meter("five_hour", 30, 300, "seven_day", 47, 10_080),
      codex: observed_meter("primary", 50, 60, "secondary", 75, 10_080),
      kimi: observed_meter("session", 10, 120, "weekly", 20, 10_080)
    }

    view = StreamdeckProjection.provider_meters(meters, @now)

    assert Map.keys(view) |> Enum.sort() == CodingAgent.provider_families() |> Enum.map(&Atom.to_string/1) |> Enum.sort()
    assert Map.has_key?(view, "claude")
    assert Map.has_key?(view, "codex")
    assert Map.has_key?(view, "kimi")

    assert get_in(view, ["claude", "windows", "session", "used_percent"]) == 30
    assert get_in(view, ["claude", "windows", "weekly", "used_percent"]) == 47
    assert get_in(view, ["codex", "windows", "session", "used_percent"]) == 50
    assert get_in(view, ["codex", "windows", "weekly", "used_percent"]) == 75
    assert get_in(view, ["kimi", "windows", "session", "used_percent"]) == 10
    assert get_in(view, ["kimi", "windows", "weekly", "used_percent"]) == 20
  end

  test "marks retained readings stale from their observation age without trusting freshness" do
    observed_at = DateTime.add(@now, -601, :second)

    view =
      StreamdeckProjection.provider_meters(
        %{codex: observed_meter("primary", 80, 60, "secondary", 90, 10_080, observed_at: observed_at, freshness: :fresh)},
        @now
      )

    assert view["codex"]["age_seconds"] == 601
    assert view["codex"]["freshness"] == "stale"
    assert get_in(view, ["codex", "windows", "session", "freshness"]) == "stale"
    assert get_in(view, ["codex", "windows", "weekly", "freshness"]) == "stale"
  end

  test "retains an observed meter for a configured provider without a dispatchable backend" do
    view = StreamdeckProjection.provider_meters(%{kimi: observed_meter("session", 25, 120, "weekly", 45, 10_080)}, @now)

    assert view["kimi"]["state"] == "observed"
    assert get_in(view, ["kimi", "windows", "session", "used_percent"]) == 25
    assert get_in(view, ["kimi", "windows", "weekly", "used_percent"]) == 45
  end

  defp observed_meter(session_id, session_percent, session_duration, weekly_id, weekly_percent, weekly_duration, opts \\ []) do
    observed_at = Keyword.get(opts, :observed_at, @now)
    freshness = Keyword.get(opts, :freshness, :fresh)

    %{
      state: :observed,
      observed_at: observed_at,
      freshness: freshness,
      windows: %{
        session_id => rate_window(session_percent, session_duration, observed_at, freshness),
        weekly_id => rate_window(weekly_percent, weekly_duration, observed_at, freshness)
      }
    }
  end

  defp rate_window(used_percent, duration_minutes, observed_at, freshness) do
    %{
      kind: :rate_limit,
      used_percent: used_percent,
      duration_minutes: duration_minutes,
      observed_at: observed_at,
      freshness: freshness
    }
  end
end
