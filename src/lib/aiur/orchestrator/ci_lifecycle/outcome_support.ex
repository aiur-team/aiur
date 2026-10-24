defmodule Aiur.Orchestrator.CiLifecycle.OutcomeSupport do
  @moduledoc false

  alias Aiur.Issue
  alias Aiur.Orchestrator.CiLifecycle
  alias Aiur.Orchestrator.State

  @spec ci_head_approved?(State.t(), Issue.t(), map()) :: boolean()
  def ci_head_approved?(%State{} = state, %Issue{} = issue, result) do
    case {Map.get(state.ci_lifecycle.approved_heads, CiLifecycle.ci_target_for_issue(issue)), Map.get(result, :head_sha)} do
      {approved_head, observed_head} when is_binary(approved_head) and approved_head == observed_head -> true
      {approved_head, nil} when is_binary(approved_head) -> true
      _ -> false
    end
  end

  @spec ci_wait_reason_modifiers(map()) :: [String.t()]
  def ci_wait_reason_modifiers(result), do: if(is_map(result[:merge_queue_entry]), do: ["merge-queued"], else: [])
end
