defmodule Aiur.Experiments.Packs.DeliverySpeed.Periods do
  @moduledoc false
  alias Aiur.Experiments.Observation
  alias Aiur.Experiments.Packs.DeliverySpeed.Tickets
  alias Aiur.Experiments.Sources.Common
  alias Aiur.Experiments.WindowEvents.GitHub

  @spec observations(String.t(), map(), map()) :: {[Observation.t()], non_neg_integer()}
  def observations("flake_issues_filed", data, window), do: flake_issues(Map.get(data, :flake_issues, []), window)

  def observations("flaky_failure_rate", data, window),
    do: flaky_failure_rate(Map.get(data, :ci_jobs, []), Map.get(data, :flake_evidence, []), Map.get(data, :ci_runs, []), window)

  def observations("ci_queue_wait", data, window), do: queue_wait(Map.get(data, :ci_jobs, []), window)
  def observations("feature_merge_share", data, window), do: feature_merge_share(Map.get(data, :github_pulls, []), window)
  def observations("innocent_dequeues", data, window), do: innocent_dequeues(Map.get(data, :github_pulls, []), window)

  def observations(id, data, window) when id == "merge_group_failure_rate" or id in ["ci_run_failure_rate", "ci_rerun_rate", "pr_ci_wall_time"],
    do: ci_observations(id, Map.get(data, :ci_runs, []), window)

  def observations(id, data, window) do
    buckets =
      Enum.reduce(data.capacity, %{}, fn sample, acc ->
        sample |> slices() |> Enum.reduce(acc, fn {at, ms}, buckets -> Map.update(buckets, at, [{sample, ms}], &[{sample, ms} | &1]) end)
      end)

    merged = data.tickets |> Map.values() |> Enum.map(&Tickets.event_at(&1, "pr_merged")) |> Enum.filter(&(&1 && Common.in_window?(&1, window))) |> Enum.frequencies_by(&hour/1)
    rows = buckets |> Enum.sort_by(&elem(&1, 0), DateTime) |> Enum.flat_map(&bucket_observation(&1, id, merged))
    {rows, map_size(buckets) - length(rows)}
  end

  defp flaky_failure_rate(jobs, evidence, runs, window) do
    merge_groups = runs |> Enum.filter(&(&1["event"] == "merge_group")) |> MapSet.new(&to_string(&1["id"]))

    failed =
      Enum.filter(jobs, fn job ->
        String.contains?(String.downcase(job["name"] || ""), "test") and job["conclusion"] == "failure" and
          MapSet.member?(merge_groups, to_string(job["run_id"])) and Common.in_window?(Common.timestamp(job["completed_at"]), window)
      end)

    rows =
      failed
      |> Enum.group_by(fn job -> Common.timestamp(job["completed_at"]) |> DateTime.to_date() end)
      |> Enum.map(fn {date, day_jobs} ->
        innocent = Enum.count(day_jobs, &innocent_job?(&1, evidence))
        at = day_at(date, window)
        %Observation{unit_id: "day:" <> Date.to_iso8601(date), at: at, value: innocent / length(day_jobs), attrs: %{"innocent_failed_test_jobs" => innocent, "failed_test_jobs" => length(day_jobs)}}
      end)

    {rows, 0}
  end

  defp innocent_job?(job, evidence) do
    run_id = to_string(job["run_id"])

    matching =
      Enum.filter(evidence, fn row ->
        row["job"] == job["name"] and is_binary(row["run_url"]) and String.ends_with?(row["run_url"], "/runs/" <> run_id)
      end)

    matching != [] and
      Enum.all?(matching, fn row ->
        row["job_failure_set_complete"] == true and row["touched"] == false and
          (row["red_on_main"] == true or row["failure_class"] == "known-flake" or row["quarantined"] == true)
      end)
  end

  defp queue_wait(jobs, window) do
    observations =
      Enum.flat_map(jobs, fn job ->
        with %DateTime{} = created <- Common.timestamp(job["created_at"]),
             %DateTime{} = started <- Common.timestamp(job["started_at"]),
             true <- DateTime.compare(started, created) != :lt,
             true <- Common.in_window?(created, window) do
          [%Observation{unit_id: "job:" <> to_string(job["id"]), at: created, value: DateTime.diff(started, created, :millisecond), attrs: %{"name" => job["name"]}}]
        else
          _ -> []
        end
      end)

    {observations, length(jobs) - length(observations)}
  end

  defp flake_issues(issues, window) do
    days = Date.diff(DateTime.to_date(window.end), DateTime.to_date(window.start)) + 1
    dates = Enum.map(0..max(days - 1, 0), &Date.add(DateTime.to_date(window.start), &1))
    counts = Enum.frequencies_by(issues, fn issue -> Common.timestamp(issue["createdAt"]) |> DateTime.to_date() end)

    rows =
      Enum.map(dates, fn date ->
        at = day_at(date, window)
        %Observation{unit_id: "day:" <> Date.to_iso8601(date), at: at, value: Map.get(counts, date, 0)}
      end)

    {Enum.filter(rows, &Common.in_window?(&1.at, window)), 0}
  end

  defp feature_merge_share(pulls, window) do
    rows =
      Enum.filter(pulls, fn pull ->
        case Common.timestamp(pull["mergedAt"]) do
          %DateTime{} = at -> Common.in_window?(at, window)
          _ -> false
        end
      end)

    observations =
      rows
      |> Enum.group_by(fn pull -> pull["mergedAt"] |> Common.timestamp() |> DateTime.to_date() end)
      |> Enum.map(fn {date, daily} ->
        feature = Enum.count(daily, &feature_pull?/1)

        at = day_at(date, window)
        %Observation{unit_id: "day:" <> Date.to_iso8601(date), at: at, value: feature / length(daily), attrs: %{"merged_prs" => length(daily)}}
      end)

    {observations, 0}
  end

  defp feature_pull?(pull) do
    issue_labels = pull |> get_in(["closingIssuesReferences", "nodes"]) |> List.wrap() |> Enum.flat_map(&(get_in(&1, ["labels", "nodes"]) |> List.wrap())) |> Enum.map(& &1["name"])
    pr_labels = pull |> get_in(["labels", "nodes"]) |> List.wrap() |> Enum.map(& &1["name"])
    GitHub.work_kind(issue_labels ++ pr_labels, pull["title"]) == "feature"
  end

  defp innocent_dequeues(pulls, window) do
    observations =
      Enum.flat_map(pulls, fn pull ->
        with %DateTime{} = at <- Common.timestamp(pull["mergedAt"]),
             true <- Common.in_window?(at, window) do
          number = pull["number"]
          head = pull["headRefOid"]

          count = Enum.count(removals_for_pull(pull), &innocent_removal?(&1, number, head, at))

          [%Observation{unit_id: "pr:" <> to_string(number), at: at, value: min(count, 1), attrs: %{"head" => head}}]
        else
          _ -> []
        end
      end)

    {observations, 0}
  end

  defp removals_for_pull(pull) do
    timeline =
      pull
      |> get_in(["timelineItems", "nodes"])
      |> List.wrap()
      |> Enum.map(fn event ->
        %{
          "pr" => pull["number"],
          "head" => get_in(event, ["beforeCommit", "oid"]),
          "reason" => event["reason"],
          "removed_at" => event["createdAt"]
        }
      end)

    timeline
  end

  defp innocent_removal?(removal, number, head, merged_at) do
    removal["pr"] == number and is_binary(head) and removal["head"] == head and removal["reason"] != "merged" and
      removal_before_merge?(removal["removed_at"], merged_at)
  end

  defp removal_before_merge?(timestamp, merged_at) when is_binary(timestamp) do
    case Common.timestamp(timestamp) do
      %DateTime{} = removed_at -> DateTime.compare(removed_at, merged_at) != :gt
      _ -> false
    end
  end

  defp removal_before_merge?(_timestamp, _merged_at), do: false

  defp day_at(date, window) do
    midnight = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    if DateTime.compare(midnight, window.start) == :lt, do: window.start, else: midnight
  end

  defp ci_observations(id, runs, window) do
    rows =
      Enum.filter(runs, fn run ->
        run["event"] in ["pull_request", "merge_group"] and run["conclusion"] in ["failure", "success"] and
          (id != "merge_group_failure_rate" or run["event"] == "merge_group")
      end)

    observations =
      Enum.flat_map(rows, &ci_observation(id, &1))

    {Enum.filter(observations, &Common.in_window?(&1.at, window)), length(rows) - length(observations)}
  end

  defp ci_observation(id, run) do
    case ci_value(id, run) do
      value when is_number(value) ->
        [%Observation{unit_id: "run:" <> to_string(run["id"]), at: Common.timestamp(run["updated_at"]), value: value, attrs: %{"event" => run["event"], "workflow" => run["name"]}}]

      _ ->
        []
    end
  end

  defp ci_value("ci_rerun_rate", %{"run_attempt" => attempt}) when is_integer(attempt), do: if(attempt > 1, do: 1, else: 0)
  defp ci_value("pr_ci_wall_time", run), do: duration(run)
  defp ci_value(_id, %{"conclusion" => "failure"}), do: 1
  defp ci_value(_id, %{"conclusion" => "success"}), do: 0
  defp ci_value(_id, _run), do: nil

  defp duration(run) do
    with %DateTime{} = started <- Common.timestamp(run["run_started_at"]), %DateTime{} = ended <- Common.timestamp(run["updated_at"]), true <- run["conclusion"] in ["success", "failure"] do
      DateTime.diff(ended, started, :millisecond)
    else
      _ -> nil
    end
  end

  defp bucket_observation({at, samples}, id, merged) do
    active? = Enum.any?(samples, fn {sample, _ms} -> sample.running > 0 end)

    case if(active?, do: value(id, samples, Map.get(merged, at, 0))) do
      nil -> []
      value -> [%Observation{unit_id: "hour:" <> DateTime.to_iso8601(at), at: at, value: value, attrs: %{"observed_ms" => Enum.sum(Enum.map(samples, &elem(&1, 1)))}}]
    end
  end

  defp value(_id, [], _merges), do: nil
  defp value("merged_per_hour", _samples, merges), do: merges

  defp value("agents_vs_cap", samples, _merges) do
    valid = Enum.filter(samples, fn {sample, _ms} -> is_number(sample.cap) and sample.cap > 0 end)
    weight = Enum.sum(Enum.map(valid, &elem(&1, 1)))
    if weight > 0, do: Enum.sum(Enum.map(valid, fn {sample, ms} -> sample.running / sample.cap * ms end)) / weight
  end

  defp value(_id, _samples, _merges), do: nil

  defp slices(sample) do
    at = hour(sample.start)
    boundary = DateTime.add(at, 3600, :second)
    finish = if DateTime.compare(sample.end, boundary) == :gt, do: boundary, else: sample.end
    first = {at, DateTime.diff(finish, sample.start, :millisecond)}
    if DateTime.compare(sample.end, boundary) == :gt, do: [first | slices(%{sample | start: boundary})], else: [first]
  end

  defp hour(at), do: %{at | minute: 0, second: 0, microsecond: {0, 0}}
end
