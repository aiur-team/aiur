defmodule Aiur.DecisionStore.Overrides do
  @moduledoc false

  alias Aiur.Commands.OverrideRoute
  alias Aiur.Commands.Overrides, as: CommandOverrides
  alias Aiur.Decision

  @spec metadata(keyword()) :: map()
  def metadata(opts) do
    context = Keyword.fetch!(opts, :override_context)
    pr = if is_map(context.pr), do: context.pr, else: %{}

    %{
      pr_number: Map.get(pr, :number),
      pr_merged: Map.get(pr, :merged?, :unknown),
      pr_head_sha: Map.get(pr, :head_sha),
      pr_head_ref: Map.get(pr, :head_ref),
      route: OverrideRoute.choose(if(Map.get(pr, :merged?) == true, do: :merged, else: :unmerged), context.worker, context.capacity)
    }
  end

  @spec dispatchable?(Decision.t()) :: boolean()
  def dispatchable?(decision) do
    case Enum.find(decision.overrides, &(&1.action_id == decision.active_action_id)) do
      %{state: :superseded} -> false
      %{route: :corrective_ticket, corrective_ticket: nil} -> false
      %{route: :corrective_ticket} = record -> is_map(Map.get(record, :corrective_ticket))
      _observed_route -> is_nil(CommandOverrides.resume_request(decision))
    end
  end
end
