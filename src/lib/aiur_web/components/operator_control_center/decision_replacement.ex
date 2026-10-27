defmodule AiurWeb.OperatorControlCenter.DecisionReplacement do
  @moduledoc false
  use Phoenix.Component
  alias AiurWeb.OperatorControlCenter.DecisionOutcomes

  attr(:decision, :map, required: true)
  attr(:state, :map, required: true)
  attr(:writable, :boolean, required: true)
  attr(:live_connected, :boolean, required: true)

  @spec decision_replacement(map()) :: Phoenix.LiveView.Rendered.t()
  def decision_replacement(assigns) do
    canonical = DecisionOutcomes.canonical_notice(assigns.decision)
    canonical_overrides? = match?(%{status: :too_late}, canonical) or match?(%{delivery: :queued_for_restart}, canonical)
    outcome = if canonical_overrides?, do: canonical, else: assigns.state[:outcome] || canonical
    outcome_notice = if outcome, do: DecisionOutcomes.outcome_notice(outcome)
    notice = if canonical_overrides?, do: outcome_notice, else: form_notice(assigns.state) || outcome_notice
    actions = if outcome_notice, do: elem(outcome_notice, 2), else: []

    assigns = assign(assigns, notice: notice, actions: actions, replaceable?: DecisionOutcomes.replaceable?(assigns.decision), follow_up: follow_up(assigns.decision))

    ~H"""
    <div class="decision-replacement">
      <p :if={@notice} class={["decision-action-message", elem(@notice, 0)]} role={if elem(@notice, 0) == :error, do: "alert", else: "status"}>{elem(@notice, 1)}</p>
      <button
        :if={@writable and @replaceable? and !@state[:replacing?]}
        type="button"
        class="aiur-button aiur-button--dashboard btn"
        phx-click="begin-replace-decision"
        phx-value-decision-id={@decision.decision_id}
        data-confirm={"Replace the Executor's answer? It has not reached ##{@decision.ticket.identifier} yet."}
        disabled={!@live_connected}
      >Replace</button>
      <a :if={:follow_up in @actions and @follow_up} href={@follow_up}>Send a follow-up message</a>
      <a :if={:refresh in @actions} href={"/commands/#{URI.encode(@decision.decision_id, &URI.char_unreserved?/1)}"}>Refresh Command</a>
    </div>
    """
  end

  defp form_notice(%{error: text}), do: {:error, text, []}
  defp form_notice(%{notice: text}), do: {:success, text, []}
  defp form_notice(_state), do: nil

  defp follow_up(%{ticket: %{url: url, identifier: id}}) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: "github.com", path: path} -> github_chat(path, id)
      _unknown -> nil
    end
  end

  defp follow_up(_decision), do: nil

  defp github_chat(path, id) do
    case String.split(path || "", "/", trim: true) do
      [owner, repository, "issues", _number] -> "/chat/" <> Enum.map_join([owner, repository, id], "/", &URI.encode(&1, fn char -> URI.char_unreserved?(char) end))
      _unknown -> nil
    end
  end
end
