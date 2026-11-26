defmodule AiurWeb.Conversation.CommandCards do
  @moduledoc """
  Inline Command cards for a conversation or job view.

  The card state (pending, answered, revised, expired, conflict) comes from
  `Aiur.Commands.ComponentState`, the same contract the ticket-scoped host API
  and the embeddable `@aiur/commands` renderer consume, so the dashboard and an
  embedding host cannot drift on what a Command is doing.
  """

  use Phoenix.Component
  alias Aiur.Commands.ComponentState
  alias AiurWeb.Components.CommandMedia
  alias AiurWeb.OperatorControlCenter.{DecisionAction, DecisionOutcomes}

  attr(:rows, :list, required: true)
  attr(:slots, :map, required: true)
  attr(:actions, :map, required: true)
  attr(:writable, :boolean, required: true)
  attr(:slot, :any, required: true)

  @spec cards(map()) :: Phoenix.LiveView.Rendered.t()
  def cards(assigns) do
    ~H"""
    <.card
      :for={row <- @rows}
      :if={@slots[row.decision_id] == @slot}
      row={row}
      action={Map.get(@actions, row.decision_id, %{})}
      writable={@writable}
      position_unknown={@slot == :pinned_top}
    />
    """
  end

  attr(:row, :map, required: true)
  attr(:action, :map, required: true)
  attr(:writable, :boolean, required: true)
  attr(:id_prefix, :string, default: "")
  attr(:position_unknown, :boolean, default: false)

  @spec card(map()) :: Phoenix.LiveView.Rendered.t()
  def card(assigns) do
    ~H"""
    <article
      id={"#{@id_prefix}conversation-command-#{@row.decision_id}"}
      class="conversation-command-card"
      data-command-state={command_state(@row)}
      aria-label="Inline Command"
    >
      <h3>{@row.question}</h3>
      <CommandMedia.command_media
        items={Map.get(@row, :media, [])}
        decision_id={@row.decision_id}
        label="Command media"
        path_prefix="/commands"
      />
      <p :if={@position_unknown}>Position unknown</p>
      <p :if={@row.answer && @row.conflict_summary && !@action[:outcome]}>{winner(@row.conflict_summary)}</p>
      <a href={"/commands/#{@row.decision_id}"}>Open Command</a>
      <DecisionAction.decision_action decision={@row} state={@action} writable={@writable} id_prefix={@id_prefix} />
    </article>
    """
  end

  @doc "The shared component state token for one Command row."
  @spec command_state(map()) :: String.t()
  def command_state(row), do: row |> ComponentState.from_projection() |> Map.fetch!("state")

  defp winner(summary), do: DecisionOutcomes.outcome_notice(%{status: :already_answered, winner: summary}) |> elem(1)
end
