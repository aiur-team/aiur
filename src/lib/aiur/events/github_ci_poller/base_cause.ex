defmodule Aiur.Events.GithubCIPoller.BaseCause do
  @moduledoc """
  Whether a red PR head is the PR's own failure, judged against MainWatch's
  in-memory history of the PR's base commit (#5133). A failing check that
  passed on the base, or never ran there (a PR-only check such as `pr body`),
  is caused by the PR. A check red on the base too is inherited; a base commit
  MainWatch has not recorded is unknown. Without MainWatch there is no base
  evidence, so every red counts as the PR's.
  """

  @passing ~w(success neutral skipped)

  @spec classify(map(), keyword()) :: :caused_by_pr | :inherited | :unknown
  def classify(result, opts) do
    case Keyword.get_lazy(opts, :main_watch_history, &history/0) do
      :disabled -> :caused_by_pr
      history -> classify_against(Map.get(result, :failures, []), Enum.find(history, &(&1.sha == result[:base_sha] and is_binary(&1.sha))))
    end
  end

  defp classify_against([], _base), do: :unknown
  defp classify_against(_failures, nil), do: :unknown
  defp classify_against(failures, %{checks: checks}), do: if(Enum.any?(failures, &caused?(&1.name, checks)), do: :caused_by_pr, else: :inherited)

  defp caused?(name, checks) do
    case Enum.find(checks, &(&1.name == name)) do
      nil -> true
      %{conclusion: conclusion} -> conclusion in @passing
    end
  end

  defp history do
    if Aiur.MainWatch.enabled?(), do: Map.get(Aiur.MainWatch.state(), :history, []), else: :disabled
  end
end
