defmodule Aiur.ExecutorSweep.FailureCause do
  @moduledoc """
  Classifies a red required check using exact-base evidence from MainWatch.
  Checks that pass on the PR base are PR-caused; checks that fail there are
  inherited. Missing evidence remains unknown (#5119).
  """

  @passing ~w(success neutral skipped)

  @doc "Returns `%{name:, class:}` with class `infra`, `caused_by_pr`, `inherited` or `unknown`."
  @spec classify(map(), String.t() | nil, [map()]) :: %{name: String.t(), class: String.t()}
  def classify(check, base_sha, base_checks) do
    name = value(check, :name, "required check")

    class =
      cond do
        infrastructure_failure?(check) -> "infra"
        passed_on_base?(name, base_sha, base_checks) -> "caused_by_pr"
        failed_on_base?(name, base_sha, base_checks) -> "inherited"
        true -> "unknown"
      end

    %{name: name, class: class}
  end

  defp passed_on_base?(name, base_sha, base_checks) when is_binary(base_sha) and base_sha != "" do
    Enum.any?(base_checks, &(value(&1, :name, nil) == name and value(&1, :base_sha, nil) == base_sha and value(&1, :conclusion, nil) in @passing))
  end

  defp passed_on_base?(_name, _base_sha, _base_checks), do: false

  defp failed_on_base?(name, base_sha, base_checks) when is_binary(base_sha) and base_sha != "" do
    Enum.any?(base_checks, fn check ->
      value(check, :name, nil) == name and value(check, :base_sha, nil) == base_sha and
        value(check, :conclusion, nil) in ["failure", "timed_out", "action_required", "stale", "cancelled", "startup_failure"]
    end)
  end

  defp failed_on_base?(_name, _base_sha, _base_checks), do: false

  defp infrastructure_failure?(check) do
    value(check, :conclusion, nil) in ["cancelled", "timed_out", "startup_failure"] or
      (is_binary(value(check, :excerpt, nil)) and String.match?(value(check, :excerpt, ""), ~r/(?:ECONNRESET|runner.*lost|artifact.*upload.*(?:error|failed))/i))
  end

  defp value(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
