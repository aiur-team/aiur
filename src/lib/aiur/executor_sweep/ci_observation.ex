defmodule Aiur.ExecutorSweep.CiObservation do
  @moduledoc false

  @spec attach(map(), [map()]) :: map()
  def attach(pr, ci_wait) do
    case Enum.find(ci_wait, &same_head?(&1, pr)) do
      nil ->
        pr

      ci ->
        failures = value(ci, :failures, [])
        required = Enum.map(failures, &%{name: value(&1, :name, "required check"), conclusion: value(&1, :result, value(&1, :conclusion, nil))})

        Map.merge(pr, %{
          ci_head_sha: value(ci, :head_sha, nil),
          ci_decision: value(ci, :decision, nil),
          required_checks: required,
          failure_class: to_string(value(ci, :failure_class, "unknown"))
        })
    end
  end

  defp same_head?(ci, pr) do
    (value(ci, :pr_number, nil) == pr.number or value(ci, :identifier, nil) == to_string(pr.issue_number)) and
      value(ci, :head_sha, nil) == pr.head_sha
  end

  defp value(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
