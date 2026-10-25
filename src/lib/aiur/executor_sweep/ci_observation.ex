defmodule Aiur.ExecutorSweep.CiObservation do
  @moduledoc false

  @spec attach(map(), [map()]) :: map()
  def attach(pr, ci_wait) do
    case Enum.find(ci_wait, &same_head?(&1, pr)) do
      nil ->
        pr

      ci ->
        required = ci |> observed_checks() |> Enum.map(&required_check/1)

        Map.merge(pr, %{
          ci_head_sha: value(ci, :head_sha, nil),
          ci_observed_at_ms: value(ci, :observed_at_ms, nil),
          ci_decision: value(ci, :decision, nil),
          required_checks: required,
          failure_class: to_string(value(ci, :failure_class, "unknown"))
        })
    end
  end

  defp observed_checks(ci) do
    failures = value(ci, :failures, [])

    case value(ci, :check_runs, nil) do
      runs when is_list(runs) -> runs ++ Enum.reject(failures, &(value(&1, :kind, nil) == "check_run"))
      _ -> failures
    end
  end

  defp required_check(check) do
    %{
      id: value(check, :id, value(check, :run_id, nil)),
      name: value(check, :name, value(check, :context, "required check")),
      conclusion: value(check, :result, value(check, :conclusion, nil)),
      excerpt: value(check, :excerpt, nil),
      started_at: value(check, :started_at, nil),
      completed_at: value(check, :completed_at, nil)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp same_head?(ci, pr) do
    (value(ci, :pr_number, nil) == pr.number or value(ci, :identifier, nil) == to_string(pr.issue_number)) and
      value(ci, :head_sha, nil) == pr.head_sha
  end

  defp value(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
