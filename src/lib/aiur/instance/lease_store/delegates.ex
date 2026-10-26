defmodule Aiur.Instance.LeaseStore.Delegates do
  @moduledoc false

  defmacro __using__(_opts) do
    delegates = [
      {Aiur.Instance.LeaseStore.RepositoryLease, [claim_leader: [1, 2], renew_leader: [1, 2], leader: [1, 2], leader_owned?: [1, 2], repository_key: [0, 1]]},
      {Aiur.Instance.LeaseStore.SharedState,
       [
         admit_github_budget: [5, 6, 7],
         release_github_budget: [1, 2],
         publish_github_budget_hold: [3, 4],
         github_budget_hold: [2, 3],
         publish_provider_meter: [1, 2],
         shared_provider_meter: [1, 2],
         publish_github_quota_snapshot: [1, 2],
         github_quota_snapshots: [0, 1],
         budget_coordination_status: [0, 1]
       ]}
    ]

    for {target, functions} <- delegates,
        {function, arities} <- functions,
        arity <- arities do
      args = Macro.generate_arguments(arity, __CALLER__.module)

      quote do
        defdelegate unquote(function)(unquote_splicing(args)), to: unquote(target)
      end
    end
  end
end
