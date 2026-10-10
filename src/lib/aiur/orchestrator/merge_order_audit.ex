defmodule Aiur.Orchestrator.MergeOrderAudit do
  @moduledoc """
  Detective control: raises `merge.out-of-order` when a ticket PR merges while one of its blockers
  has not landed or is not contained in the merged head. It undoes nothing; the Executor's
  `check-stack-order.sh` is the preventive gate.
  """
  alias Aiur.{Alerts, GitHub}
  alias Aiur.Orchestrator.{State, TrackerTasks}
  alias Aiur.Stacking.{MergeOrder, StackBaseEvidence}

  @spec merged(State.t(), String.t(), map(), keyword()) :: State.t()
  def merged(%State{} = state, identifier, event, opts \\ []) do
    pr = if is_map(Map.get(event, :pr)), do: event.pr, else: %{}
    number = pr["number"]
    head = get_in(pr, ["head", "sha"])

    if is_integer(number) and not Map.has_key?(state.restack_completed, {:merge_order, number}) do
      state = %{state | restack_completed: Map.put(state.restack_completed, {:merge_order, number}, :done)}
      TrackerTasks.run(state, {:merge_order, number}, fn -> audit(identifier, number, head, opts) end, fn current, _result -> current end)
    else
      state
    end
  end

  defp audit(identifier, number, head, opts) do
    blockers = Keyword.get(opts, :blockers, &StackBaseEvidence.blocker_facts/1).(identifier)
    compare = Keyword.get(opts, :compare, &GitHub.Client.fetch_compare_status/2)
    emit = Keyword.get(opts, :emit, &Alerts.emit_system/2)

    contained = fn sha ->
      with true <- is_binary(head) and head != "",
           {:ok, status} <- compare.(sha, head) do
        if status in ["ahead", "identical"], do: :contained, else: :not_contained
      else
        _ -> :unknown
      end
    end

    case MergeOrder.verdict(blockers, contained) do
      :ok ->
        :ok

      {:violation, ids} ->
        emit.("ticket.#{identifier}.merge.out-of-order",
          message: "PR ##{number} for ##{identifier} merged before blocker(s) #{format(ids)} landed",
          needs_attention: true,
          severity: "critical"
        )

      {:unverified, ids} ->
        emit.("ticket.#{identifier}.merge.out-of-order",
          message: "PR ##{number} for ##{identifier} merged; could not verify blocker(s) #{format(ids)}",
          needs_attention: true,
          severity: "warning"
        )
    end
  end

  defp format(ids), do: Enum.map_join(ids, ", ", &"##{&1}")
end
