defmodule Aiur.ExecutorSweep.FailureCause do
  @moduledoc """
  Classifies a red required check. It is `caused_by_pr` only when the same
  check passed on the PR's base commit (MainWatch history); without that
  evidence it is `unknown`, since flakes and inherited reds look the same (#5119).
  """

  @passing ~w(success neutral skipped)

  @doc "Returns `%{name:, class:}` with class `infra`, `caused_by_pr` or `unknown`."
  @spec classify(map(), String.t() | nil, [map()]) :: %{name: String.t(), class: String.t()}
  def classify(check, base_sha, base_checks) do
    name = value(check, :name, "required check")

    class =
      cond do
        value(check, :conclusion, nil) in ["cancelled", "timed_out", "startup_failure"] -> "infra"
        passed_on_base?(name, base_sha, base_checks) -> "caused_by_pr"
        true -> "unknown"
      end

    %{name: name, class: class}
  end

  defp passed_on_base?(name, base_sha, base_checks) when is_binary(base_sha) and base_sha != "" do
    Enum.any?(base_checks, &(value(&1, :name, nil) == name and value(&1, :base_sha, nil) == base_sha and value(&1, :conclusion, nil) in @passing))
  end

  defp passed_on_base?(_name, _base_sha, _base_checks), do: false

  defp value(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
