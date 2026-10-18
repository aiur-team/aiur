defmodule Aiur.LandingWatch.QuarantineAnnotations do
  @moduledoc """
  Reads the failure annotations CI writes for the landing watcher:
  `aiur-test-failure` (a quarantinable test) and `aiur-guard-failure` (an OrchestratorGuard
  failure, filed as evidence but never quarantined).
  """

  alias Aiur.GitHub.FailureEvidence
  alias Aiur.LandingWatch.QuarantineEvidence

  @type found :: %{tests: [map()], guards: [map()]}

  @doc "Failures annotated on the failed jobs of one workflow run."
  @spec from_jobs([map()], keyword()) :: {:ok, found()} | {:error, term()}
  def from_jobs(jobs, opts) do
    jobs
    |> Enum.filter(&(&1["conclusion"] == "failure"))
    |> Enum.map(&{check_run_id(&1), &1["name"] || "unknown job"})
    |> from_checks(opts)
  end

  @doc "Failures annotated on `{check_run_id, job_name}` pairs; nil ids are skipped."
  @spec from_checks([{integer() | nil, String.t()}], keyword()) :: {:ok, found()} | {:error, term()}
  def from_checks(checks, opts) do
    Enum.reduce_while(checks, {:ok, %{tests: [], guards: []}}, fn
      {nil, _job}, acc ->
        {:cont, acc}

      {id, job}, {:ok, acc} ->
        case Keyword.get(opts, :annotations_fun, &FailureEvidence.annotations/2).(id, opts) do
          {:ok, annotations} -> {:cont, {:ok, merge(acc, parse(annotations, job))}}
          {:error, reason} -> {:halt, {:error, {:merge_group_annotations_unavailable, reason}}}
        end
    end)
  end

  defp merge(left, right), do: %{tests: left.tests ++ right.tests, guards: left.guards ++ right.guards}

  defp parse(annotations, job) do
    Enum.reduce(annotations, %{tests: [], guards: []}, fn annotation, acc ->
      case annotation do
        %{"title" => "aiur-test-failure", "message" => message} when is_binary(message) -> %{acc | tests: acc.tests ++ test(message, annotation, job)}
        %{"title" => "aiur-guard-failure", "message" => "orchestrator-guard :: " <> named} -> %{acc | guards: acc.guards ++ [QuarantineEvidence.guard_failure(named, job)]}
        _ -> acc
      end
    end)
  end

  defp test(message, annotation, job) do
    case String.split(message, " :: ", parts: 3) do
      [class, module, name] when class in ["known-flake", "new-failure"] and module != "" and name != "" ->
        excerpt = annotation["raw_details"] || annotation["description"] || message
        [%{module: module, name: name, job: job, path: annotation["path"], excerpt: String.slice(String.trim(to_string(excerpt)), 0, 500)}]

      _ ->
        []
    end
  end

  defp check_run_id(%{"check_run_id" => id}) when is_integer(id), do: id

  defp check_run_id(%{"check_run_url" => url}) when is_binary(url) do
    case Regex.run(~r{/check-runs/(\d+)\z}, url, capture: :all_but_first) do
      [id] -> String.to_integer(id)
      _ -> nil
    end
  end

  defp check_run_id(_), do: nil
end
