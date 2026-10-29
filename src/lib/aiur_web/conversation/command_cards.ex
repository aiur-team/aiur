defmodule AiurWeb.Conversation.CommandCards do
  @moduledoc false
  use Phoenix.Component
  alias AiurWeb.OperatorControlCenter.{DecisionAction, DecisionOutcomes}

  attr(:rows, :list, required: true)
  attr(:slots, :map, required: true)
  attr(:actions, :map, required: true)
  attr(:writable, :boolean, required: true)
  attr(:slot, :any, required: true)

  @spec cards(map()) :: Phoenix.LiveView.Rendered.t()
  def cards(assigns) do
    ~H"""
    <article :for={row <- @rows} :if={@slots[row.decision_id] == @slot} id={"conversation-command-#{row.decision_id}"} aria-label="Inline Command">
      <h3>{row.question}</h3>
      <p :if={@slot == :pinned_top}>Position unknown</p>
      <p :if={row.answer && row.conflict_summary && !get_in(@actions, [row.decision_id, :outcome])}>{winner(row.conflict_summary)}</p>
      <a href={"/commands/#{row.decision_id}"}>Open Command</a>
      <DecisionAction.decision_action decision={row} state={Map.get(@actions, row.decision_id, %{})} writable={@writable} />
    </article>
    """
  end

  defp winner(summary), do: DecisionOutcomes.outcome_notice(%{status: :already_answered, winner: summary}) |> elem(1)
end
