defmodule Aiur.GitHub.CandidateAuthorization do
  @moduledoc false

  @spec authorize([Aiur.Issue.t()], map(), ([Aiur.Issue.t()] -> [Aiur.Issue.t()])) :: [Aiur.Issue.t()]
  def authorize(issues, cache, authorize) do
    adopted = Map.get(cache, :adopted_issue_ids, MapSet.new())
    {running, candidates} = Enum.split_with(issues, &MapSet.member?(adopted, &1.id))
    # Keep fresh lifecycle evidence so reconciliation does not refetch running
    # tickets. They remain unauthorized and cannot become new dispatches.
    authorize.(candidates) ++ running
  end
end
