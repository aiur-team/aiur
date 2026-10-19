defmodule Aiur.Events.GithubCIPoller.BaseCause do
  @moduledoc """
  Whether a red PR head is the PR's own failure, judged against MainWatch's
  in-memory history of the PR's base commit (#5133). A failing check that
  passed on the base, or never ran there (a PR-only check such as `pr body`),
  is caused by the PR. A check red on the base too is inherited. When MainWatch
  never recorded the base (merge-queue or cancelled push runs), a failing check
  that appears nowhere in its history is still the PR's; otherwise the cause
  is unknown, and `Recovery` holds it for about one main CI run before routing,
  since that base may never be recorded. Without MainWatch there is no base evidence, so every red counts
  as the PR's.
  """

  @passing ~w(success neutral skipped)

  @spec classify(map(), keyword()) :: :caused_by_pr | :inherited | :unknown
  def classify(result, opts) do
    case Keyword.get_lazy(opts, :main_watch_history, &history/0) do
      :disabled -> :caused_by_pr
      history -> classify_against(Map.get(result, :failures, []), Enum.find(history, &(&1.sha == result[:base_sha] and is_binary(&1.sha))), history)
    end
  end

  defp classify_against([], _base, _history), do: :unknown
  defp classify_against(failures, nil, history), do: if(Enum.any?(failures, &never_ran?(&1.name, history)), do: :caused_by_pr, else: :unknown)
  defp classify_against(failures, %{checks: checks}, _history), do: if(Enum.any?(failures, &caused?(&1.name, checks)), do: :caused_by_pr, else: :inherited)

  defp never_ran?(name, history), do: not Enum.any?(history, fn entry -> Enum.any?(entry.checks, &(&1.name == name)) end)

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
