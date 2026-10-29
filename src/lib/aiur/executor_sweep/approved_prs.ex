defmodule Aiur.ExecutorSweep.ApprovedPrs do
  @moduledoc false

  alias Aiur.ExecutorSweep.{FailureCause, LatestChecks}

  @type finding :: %{kind: String.t(), priority: pos_integer(), action: String.t(), message: String.t()}

  @spec findings(map(), DateTime.t(), pos_integer()) :: [finding()]
  def findings(snapshot, now, max_age_ms) do
    snapshot
    |> Map.get(:pull_requests, [])
    |> Enum.flat_map(&findings_for_pr(&1, snapshot, now, max_age_ms))
  end

  defp findings_for_pr(pr, snapshot, now, max_age_ms) do
    base_checks = Map.get(snapshot, :base_checks, [])
    failures = LatestChecks.red_required(value(pr, :required_checks, []))

    if failures != [] do
      age = live_ci_age(pr, now)
      if fresh_age?(age, max_age_ms), do: approved_pr_findings(pr, failures, base_checks, age, max_age_ms), else: []
    else
      age = cache_age(snapshot, value(pr, :number, nil))
      approved_pr_findings(pr, failures, base_checks, age, max_age_ms)
    end
  end

  defp approved_pr_findings(pr, failures, base_checks, observed_age_ms, max_age_ms) do
    # A cached row can keep "open" after the merge; merged_at is the landing proof (#5119).
    if approved_current_and_open?(pr) and (failures != [] or approved_pr_not_landing?(pr)) do
      [approved_pr_finding(pr, failures, base_checks, observed_age_ms, max_age_ms)]
    else
      []
    end
  end

  defp approved_current_and_open?(pr) do
    value(pr, :state, "open") == "open" and is_nil(value(pr, :merged_at, nil)) and approved_current_head?(pr)
  end

  defp approved_pr_not_landing?(pr) do
    landing = value(pr, :in_merge_queue, false) or value(pr, :auto_merge, false)
    landing_known = value(pr, :landing_state_known?, Map.has_key?(pr, :in_merge_queue) and Map.has_key?(pr, :auto_merge))

    landing_known and not landing and value(pr, :mergeable, nil) != "CONFLICTING"
  end

  defp approved_current_head?(pr) do
    value(pr, :review_decision, "") == "APPROVED" and
      (is_nil(value(pr, :head_sha, nil)) or value(pr, :approved_head_sha, nil) == value(pr, :head_sha, nil))
  end

  defp approved_pr_finding(pr, failures, base_checks, observed_age_ms, max_age_ms) do
    red = failures != []
    kind = if red, do: "approved_pr_red", else: "approved_pr_not_landing"

    classifications = classify_failures(pr, failures, base_checks, observed_age_ms, max_age_ms)

    cause = classifications |> Enum.map(& &1.class) |> Enum.uniq() |> single_or_mixed()
    checks = Enum.map_join(classifications, ", ", &"#{&1.name} (#{display_failure_class(&1.class)})")

    problem =
      if red,
        do: "#{LatestChecks.problem(failures, cause, true)}; checks: #{checks}",
        else: LatestChecks.problem(failures, cause, false)

    stale? = not fresh_age?(observed_age_ms, max_age_ms)
    verification = if stale?, do: "unverified", else: "verified"
    age_source = if red, do: "CI observation age", else: "GitHub cache age"

    action = finding_action(stale?, cause)

    finding(kind, action, "Approved PR ##{value(pr, :number, "?")} #{problem}; #{verification} (#{age_source}: #{age(observed_age_ms)}).",
      pull_request: value(pr, :number, nil),
      failure_class: cause,
      failed_checks: classifications,
      cache_age_ms: observed_age_ms,
      verification: verification
    )
  end

  defp classify_failures(pr, failures, base_checks, observed_age_ms, max_age_ms) do
    {base_sha, base_checks} = if fresh_age?(observed_age_ms, max_age_ms), do: {value(pr, :base_sha, nil), base_checks}, else: {nil, []}
    Enum.map(failures, &FailureCause.classify(&1, base_sha, base_checks))
  end

  defp finding_action(true, _cause), do: "Verify the PR and its checks in GitHub before taking action."
  defp finding_action(false, "caused_by_pr"), do: "Inspect the PR-caused failure or restore merge queue/auto-merge progress."
  defp finding_action(false, _cause), do: "Inspect the check cause or restore merge queue/auto-merge progress."

  defp finding(kind, action, message, extra) do
    Map.merge(%{kind: kind, priority: 3, age_ms: 0, action: action, message: message}, Map.new(extra))
  end

  defp display_failure_class("caused_by_pr"), do: "PR-caused"
  defp display_failure_class("inherited"), do: "inherited"
  defp display_failure_class("infra"), do: "infra"
  defp display_failure_class("unknown"), do: "unknown"
  defp display_failure_class(class), do: class

  defp single_or_mixed([single]), do: single
  defp single_or_mixed(_), do: "mixed"

  defp cache_age(snapshot, subject), do: get_in(snapshot, [:github_cache_ages, :pull_requests, subject])

  defp live_ci_age(pr, now) do
    if value(pr, :ci_head_sha, nil) == value(pr, :head_sha, nil) do
      case value(pr, :ci_observed_at_ms, nil) do
        observed when is_integer(observed) -> max(DateTime.to_unix(now, :millisecond) - observed, 0)
        _ -> nil
      end
    else
      nil
    end
  end

  defp fresh_age?(age, max_age_ms), do: is_integer(age) and age <= max_age_ms
  defp age(ms) when is_integer(ms), do: duration(ms)
  defp age(_), do: "unknown"

  defp value(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp duration(ms) do
    total_minutes = div(ms, 60_000)
    hours = div(total_minutes, 60)
    minutes = rem(total_minutes, 60)
    if hours > 0, do: "#{hours}h #{minutes}m", else: "#{minutes}m"
  end
end
