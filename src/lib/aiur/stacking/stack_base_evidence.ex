defmodule Aiur.Stacking.StackBaseEvidence do
  @moduledoc "Resolves a CI target's stack base from locally held GitHub evidence."
  require Logger
  alias Aiur.Config
  alias Aiur.GitHub.{Issues, TicketPullRequest}
  alias Aiur.Issue
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

  defp blocker_facts(target) do
    case Issues.hydrate_blocked_by(%Issue{id: target}, revalidate: :cached) do
      {:ok, %Issue{blocked_by: blockers}} -> Enum.map(blockers, &with_pr/1)
      _missing -> []
    end
  end

  defp with_pr(%{id: id}) do
    case TicketPullRequest.read(id) do
      {:ok, pr} -> %{id: id, pr: pr}
      _missing -> %{id: id, pr: nil}
    end
  end
end
