defmodule Aiur.Stacking.StackBaseEvidence do
  @moduledoc "Resolves a CI target's stack base from locally held GitHub evidence."
  require Logger
  alias Aiur.Config
  alias Aiur.GitHub.{ResourceStore, TicketPullRequest, Transport}
  alias Aiur.Stacking.StackBase

  @spec expected_base(String.t(), map(), keyword()) :: String.t()
  def expected_base(target, pr, opts) do
    integration = Config.base_branch(opts)
    base = get_in(pr, ["base", "ref"])

    case StackBase.decide(base, integration, blocker_facts(target)) do
      {:ok, {:stacked, blocker_id}} ->
        Logger.debug("Pull request base stacked: pr=#{pr["number"]} blocker=#{blocker_id}")
        base

      _integration_or_repair ->
        integration
    end
  end

  @spec blocker_facts(String.t()) :: [map()]
  def blocker_facts(target) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, %{data: blockers}} when is_list(blockers) <- ResourceStore.fetch(ResourceStore.key(:issue_blocked_by, owner, repo, target)),
         true <- Enum.all?(blockers, &valid_edge?/1) do
      Enum.map(blockers, &with_pr/1)
    else
      _missing_or_malformed -> []
    end
  end

  defp valid_edge?(%{"number" => number}) when is_integer(number) and number > 0, do: true
  defp valid_edge?(_edge), do: false

  defp with_pr(%{"number" => number}) do
    id = Integer.to_string(number)
    {:ok, pr} = TicketPullRequest.read(id)
    %{id: id, pr: pr}
  end
end
