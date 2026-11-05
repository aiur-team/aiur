defmodule AiurWeb.Conversation.CommandCards do
  @moduledoc """
  Inline Command cards, rendered by the extracted `AgentConversation.Components`
  package.

  The card shell — question, position note, conflict notice and the link to the
  full Command — comes from the shared component. Answering stays inside Aiur's
  canonical boundary: `action/1` below is the only thing the package renders for
  it, and that is `AiurWeb.OperatorControlCenter.DecisionAction`.
  """
  use Phoenix.Component

  alias AiurWeb.OperatorControlCenter.{DecisionAction, DecisionOutcomes}

  attr(:rows, :list, required: true)
  attr(:slots, :map, required: true)
  attr(:actions, :map, required: true)
  attr(:writable, :boolean, required: true)
  attr(:slot, :any, required: true)

  @spec cards(map()) :: Phoenix.LiveView.Rendered.t()
  def cards(assigns) do
    rows = Enum.filter(assigns.rows, &(Map.get(assigns.slots, &1.decision_id) == assigns.slot))
    assigns = assign(assigns, :rows_at_slot, Enum.map(rows, &row(&1, Map.get(assigns.actions, &1.decision_id, %{}), assigns.writable)))

    ~H"""
    <AgentConversation.Components.command_card
      :for={row <- @rows_at_slot}
      row={row}
      slot={@slot}
      href={"/commands/#{row.decision_id}"}
      notice={notice(row)}
      answerable={@writable}
      actions={{__MODULE__, :action}}
    />
    """
  end

  @doc """
  Maps an Aiur decision row onto the shared Command card shape.

  The shared card reads only `:id`, `:question`, `:status`, `:position` and
  `:conflict`. Aiur's answering boundary needs the original row and its action
  state too, so both travel with it rather than being re-derived inside the
  package.
  """
  @spec row(map(), map(), boolean()) :: map()
  def row(row, state, writable) do
    %{
      id: to_string(row.decision_id),
      question: row.question,
      status: if(row.answer, do: :answered, else: :pending),
      position: Map.get(row, :pos),
      conflict: Map.get(row, :conflict_summary),
      decision: row,
      state: state,
      writable: writable,
      decision_id: row.decision_id,
      answer: row.answer,
      conflict_summary: Map.get(row, :conflict_summary)
    }
  end

  @doc "The answer controls: Aiur's canonical Command answering boundary."
  @spec action(map()) :: Phoenix.LiveView.Rendered.t()
  def action(assigns) do
    ~H"""
    <DecisionAction.decision_action decision={@row.decision} state={@row.state} writable={@row.writable} />
    """
  end

  defp notice(%{state: state} = row) when is_map(state) do
    cond do
      get_in(state, [:outcome]) -> nil
      row.answer && row.conflict_summary -> DecisionOutcomes.outcome_notice(%{status: :already_answered, winner: row.conflict_summary}) |> elem(1)
      true -> nil
    end
  end

  defp notice(_row), do: nil
end
