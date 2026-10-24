defmodule AiurWeb.OperatorControlCenter.AccountUsagePresenterTest do
  use ExUnit.Case, async: true

  alias AiurWeb.OperatorControlCenter.AccountUsagePresenter

  defp reading(weekly), do: %{windows: [%{window: "seven_day", used_percent: weekly, resets_at: nil}]}

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  # #5747: an entry recorded `:fresh` keeps saying so forever if nothing
  # probes again. Past the headroom max age dispatch treats it as unknown, so
  # the Models card must mark it stale too.
  test "a reading older than the max age is stale even though it was fresh when recorded" do
    %{accounts: [account]} =
      AccountUsagePresenter.present(%{"default" => %{reading: reading(40), observed_at: ago(13_000), freshness: :fresh, reason: nil}})

    assert account.freshness == :stale
    assert account.percent == 40
  end

  test "a reading within the max age keeps its own freshness" do
    %{accounts: [account]} =
      AccountUsagePresenter.present(%{"default" => %{reading: reading(40), observed_at: ago(60), freshness: :fresh, reason: nil}})

    assert account.freshness == :fresh
    assert account.last_error == nil
  end

  test "a failing account shows the age of its last real observation and the error" do
    %{accounts: [account], title: title} =
      AccountUsagePresenter.present(%{
        "default" => %{reading: nil, observed_at: ago(0), freshness: :unavailable, reason: :rate_limited, last_observed_at: ago(3_600)}
      })

    assert account.freshness == :stale
    assert account.age_seconds >= 3_600
    assert account.last_error == :rate_limited
    assert title =~ "last error rate_limited"
  end
end
