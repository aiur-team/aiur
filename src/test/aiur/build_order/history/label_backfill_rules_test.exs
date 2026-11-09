defmodule Aiur.BuildOrder.History.LabelBackfill.RulesTest do
  use ExUnit.Case, async: true
  alias Aiur.BuildOrder.History.LabelBackfill.Rules

  defp candidate(fields \\ %{}), do: Map.merge(%{kind: :feature, confirmed: true, projection: :held_backfill, label: "feature:history"}, fields)
  defp row(fields \\ %{}), do: Map.merge(%{labels: [], lifecycle: %{state: :closed}}, fields)

  test "eligibility requires confirmation, a held join, closed lifecycle and known facts" do
    settings = %{history_state: :healthy}
    assert Rules.eligible(candidate(), row(), settings) == :write
    assert Rules.eligible(candidate(%{confirmed: false}), row(), settings) == {:skip, :unconfirmed}
    for state <- [:exempt, :pending_label, nil], do: assert(Rules.eligible(candidate(%{projection: state}), row(), settings) == :not_item)
    assert Rules.eligible(candidate(), row(), Map.put(settings, :registry_unknown, true)) == {:defer, :registry_unknown}
    assert Rules.eligible(candidate(), :unknown, settings) == {:defer, :history_unknown}
    assert Rules.eligible(candidate(), row(), %{history_state: :unavailable}) == {:defer, :history_unknown}
    assert Rules.eligible(candidate(), row(%{lifecycle: %{state: :unknown}}), settings) == {:defer, :state_unknown}
    assert Rules.eligible(candidate(), row(%{lifecycle: %{state: :open}}), settings) == {:skip, :open}
    assert Rules.eligible(candidate(), row(%{labels: :unknown}), settings) == {:defer, :labels_unknown}
    assert Rules.eligible(candidate(), row(%{labels: ["Feature:History"]}), settings) == {:done, :already_present}
    assert Rules.eligible(candidate(), row(%{labels_complete: false}), settings) == :write
  end

  test "holds parse each error shape and missing or malformed resets wait fifteen minutes" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    later = DateTime.add(now, 600)

    for reason <- [
          {:github, :local_hold, %{hold: %{reset_at: later}}},
          {:github, :transport, %{reason: {:aiur, :locally_held, %{reset_at: later}}}},
          {:github_api_request, {:aiur, :locally_held, %{reset_at: later}}},
          {:github, :rate_limited, %{reset_at: DateTime.to_iso8601(later)}}
        ],
        do: assert(Rules.on_result({:error, reason}, now) == {:hold, later})

    for reason <- [
          {:github, :local_hold, %{reason: :github_budget_broker_timeout}},
          {:github, :rate_limited, %{reset_at: "bad"}},
          {:github, :rate_limited, %{reset_at: nil}},
          {:github_api_status, 429, %{}},
          {:github_api_request, :github_budget_broker_timeout}
        ],
        do: assert(Rules.on_result({:error, reason}, now) == {:hold, DateTime.add(now, 900)})

    assert Rules.on_result({:error, {:github, :rate_limited, %{retry_after: 90, reset_at: nil}}}, now) == {:hold, DateTime.add(now, 90)}
  end

  test "auth forbidden unsupported gone and transient failures have distinct outcomes" do
    now = DateTime.utc_now()
    assert Rules.on_result(:ok, now) == :written
    assert Rules.on_result({:error, {:github, :auth, %{status: 401}}}, now) == {:stop, :auth}
    assert Rules.on_result({:error, {:github, :http, %{status: 403}}}, now) == {:stop, :forbidden}
    assert Rules.on_result({:error, {:github_api_status, 401, %{}}}, now) == {:stop, :auth}
    assert Rules.on_result({:error, {:github_api_status, 403, %{}}}, now) == {:stop, :forbidden}
    assert Rules.on_result({:error, :unsupported}, now) == {:stop, :unsupported}
    for status <- [404, 410], do: assert(Rules.on_result({:error, {:github, :http, %{status: status}}}, now) == {:failed, :gone})
    assert {:retry, error} = Rules.on_result({:error, {:github, :http, %{status: 500}}}, now)
    assert error =~ "500"
  end

  test "rolling hour includes every recent reservation and maximum uses half the effective agent limit" do
    now = DateTime.utc_now()
    assert Rules.max_per_hour(250) == 125
    assert Rules.max_per_hour(0) == 125
    assert Rules.max_per_hour(100) == 50
    refute Rules.window_allows?([now, DateTime.add(now, -3599)], 2, 20, now)
    assert Rules.window_allows?([now, DateTime.add(now, -3600)], 2, 20, now)
  end
end
