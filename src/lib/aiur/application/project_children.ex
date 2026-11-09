defmodule Aiur.Application.ProjectChildren do
  @moduledoc """
  The child list of one project tree, in the relative order of the machine list.

  Only modules that register through `Aiur.Project.via/1` or `name/2` belong here
  (MPG-303..305): two trees of an unmigrated module would collide on its bare name.
  Unmigrated per-project modules stay machine-level and serve the daemon config.
  """

  @doc "Modules a projects-mode machine list drops: they poll or dispatch for one repository."
  @spec pollers() :: [module()]
  def pollers, do: [Aiur.GitHub.Listeners, Aiur.Orchestrator | List.wrap(Aiur.BuildQueue.child(true))]

  @doc "Called from the project root's `init/1`, so name helpers already see its context."
  @spec specs(Aiur.Project.t(), keyword()) :: [Supervisor.child_spec() | {module(), term()} | module()]
  def specs(%Aiur.Project{id: id}, opts) do
    [
      Aiur.WorkflowStore,
      Aiur.AgentPubSub.FleetRefresh,
      Aiur.AlertFeed.Backfill,
      Aiur.RepoBase,
      Aiur.Conversation.HeadTable,
      Aiur.Events.project_children(),
      Aiur.GitHub.OpenIssueSnapshot,
      Aiur.BuildOrder.Features,
      Aiur.Orchestrator.OptimisticLedger,
      Aiur.Orchestrator.TrackedSet,
      Aiur.Orchestrator.SnapshotCache,
      Aiur.Orchestrator.SnapshotStore,
      Aiur.Orchestrator.SnapshotPublisher,
      # Seed the fail-closed admission table before the Orchestrator's first dispatch.
      Aiur.Orchestrator.SpendCap.Store,
      Aiur.GitHub.Listeners,
      {Aiur.Orchestrator, name: Aiur.Project.name(Aiur.Orchestrator, id), initial_poll?: Application.get_env(:aiur, :orchestrator_initial_poll?, true)},
      Aiur.BuildQueue.child(Keyword.get(opts, :recording?, true))
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end
end
