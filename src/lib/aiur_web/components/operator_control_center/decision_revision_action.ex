defmodule AiurWeb.OperatorControlCenter.DecisionRevisionAction do
  @moduledoc false

  use Phoenix.Component

  attr(:decision, :map, required: true)
  attr(:state, :map, default: %{})
  attr(:writable, :boolean, required: true)

  @spec decision_revision_action(map()) :: Phoenix.LiveView.Rendered.t()
  def decision_revision_action(assigns) do
    decision =
      Map.merge(
        %{
          answer: nil,
          original_answer: nil,
          active_action_id: nil,
          revision_sequence: 0,
          revisions: [],
          revision_follow_ups: %{}
        },
        assigns.decision
      )

    form = Map.get(assigns.state, :revision_form, %{})

    assigns =
      assigns
      |> assign(:decision, decision)
      |> assign(
        form: form,
        choice: Map.get(form, "choice") || default_choice(decision),
        error: Map.get(assigns.state, :revision_error),
        notice: Map.get(assigns.state, :revision_notice),
        follow_up_error: Map.get(assigns.state, :follow_up_error),
        follow_up_notice: Map.get(assigns.state, :follow_up_notice),
        follow_up_detail: Map.get(assigns.state, :follow_up_detail, ""),
        pending_follow_up: pending_follow_up(decision),
        confirmation_required?: confirmation_required?(decision)
      )

    ~H"""
    <section :if={@decision.answer} class="decision-revision" aria-labelledby={"decision-revision-title-#{@decision.decision_id}"}>
      <header class="decision-action-header">
        <div>
          <p class="section-eyebrow">Append-only correction</p>
          <h4 id={"decision-revision-title-#{@decision.decision_id}"}>Revise decision</h4>
        </div>
        <span class="chip super">Revision {@decision.revision_sequence}</span>
      </header>

      <p class="decision-revision-caution">
        A revision records new direction; it does not claim earlier effects were rolled back.
      </p>

      <div :if={@decision.revisions != []} class="decision-revision-list">
        <article class="decision-revision-entry original">
          <div>
            <span class="decision-answer-label">Original answer · preserved</span>
            <strong>{answer_label(@decision.original_answer, @decision.options)}</strong>
          </div>
          <span class="chip attention">Superseded</span>
        </article>
        <article :for={revision <- @decision.revisions} class="decision-revision-entry">
          <div>
            <span class="decision-answer-label">Revision {revision.sequence}</span>
            <strong>{answer_label(revision.answer, @decision.options)}</strong>
            <p>{revision.reason}</p>
          </div>
          <span class={revision_result_chip(revision, @decision.revision_sequence)}>
            {revision_result_label(revision, @decision.revision_sequence)}
          </span>
        </article>
      </div>

      <p :if={@error} class="decision-action-message error" role="alert">{@error}</p>
      <p :if={@notice} class="decision-action-message success" role="status">{@notice}</p>
      <p :if={@follow_up_error} class="decision-action-message error" role="alert">{@follow_up_error}</p>
      <p :if={@follow_up_notice} class="decision-action-message success" role="status">{@follow_up_notice}</p>

      <form
        :if={@writable}
        id={"decision-revision-form-#{@decision.decision_id}"}
        class="decision-answer-form"
        phx-change="decision-revision-change"
        phx-submit="revise-decision"
      >
        <input type="hidden" name="decision_id" value={@decision.decision_id} />

        <fieldset :if={@decision.options != []} class="decision-choice-list">
          <legend class="sr-only">Choose the revised answer</legend>
          <label
            :for={option <- @decision.options}
            class={["decision-choice", @choice == "option:#{option.id}" && "selected"]}
          >
            <input
              type="radio"
              name="revision[choice]"
              value={"option:#{option.id}"}
              checked={@choice == "option:#{option.id}"}
            />
            <span class="decision-choice-copy">
              <strong>{option.label}</strong>
              <small :if={present?(option.description)}>{option.description}</small>
            </span>
          </label>

          <label class={["decision-choice", "custom", @choice == "custom" && "selected"]}>
            <input type="radio" name="revision[choice]" value="custom" checked={@choice == "custom"} />
            <span class="decision-choice-copy">
              <strong>Custom response</strong>
              <small>Replace the current direction with bounded free text.</small>
            </span>
          </label>
        </fieldset>

        <input :if={@decision.options == []} type="hidden" name="revision[choice]" value="custom" />

        <label :if={@choice == "custom"} class="decision-action-field">
          <span>Revised response</span>
          <textarea name="revision[custom_response]" rows="4" maxlength="4000" required>{Map.get(@form, "custom_response", "")}</textarea>
        </label>

        <label class="decision-action-field">
          <span>Reason for revision</span>
          <textarea name="revision[reason]" rows="3" maxlength="4000" required>{Map.get(@form, "reason", "")}</textarea>
        </label>

        <label :if={@confirmation_required?} class="decision-confirmation">
          <input
            type="checkbox"
            name="revision[confirmed]"
            value="true"
            checked={Map.get(@form, "confirmed") == "true"}
          />
          <span>I understand this revised direction is irreversible or destructive.</span>
        </label>

        <footer class="decision-action-footer">
          <span>Targets action {@decision.active_action_id} · sequence {@decision.revision_sequence}</span>
          <button class="btn" type="submit" phx-disable-with="Recording…">Record revision</button>
        </footer>
      </form>

      <div :if={@pending_follow_up} class="decision-follow-up">
        <div>
          <span class="decision-answer-label">Executor follow-up required</span>
          <strong>Target no longer active</strong>
          <p>{@pending_follow_up.question}</p>
        </div>
        <form :if={@writable} phx-submit="handle-revision-follow-up" class="decision-answer-form">
          <input type="hidden" name="decision_id" value={@decision.decision_id} />
          <input type="hidden" name="action_id" value={@pending_follow_up.action_id} />
          <label class="decision-action-field">
            <span>How was this follow-up handled?</span>
            <textarea name="follow_up[detail]" rows="2" maxlength="4000" required>{@follow_up_detail}</textarea>
          </label>
          <button class="btn danger" type="submit" phx-disable-with="Recording…">Mark follow-up handled</button>
        </form>
      </div>
    </section>
    """
  end

  defp default_choice(%{answer: %{selected_option_id: option_id}}) when is_binary(option_id),
    do: "option:#{option_id}"

  defp default_choice(%{answer: %{custom_response: response}}) when is_binary(response), do: "custom"
  defp default_choice(%{options: []}), do: "custom"
  defp default_choice(decision), do: "option:#{decision.options |> List.first() |> Map.fetch!(:id)}"

  defp answer_label(%{selected_option_id: option_id}, options) when is_binary(option_id) do
    case Enum.find(options, &(&1.id == option_id)) do
      nil -> "Option #{option_id}"
      option -> option.label
    end
  end

  defp answer_label(%{custom_response: response}, _options), do: response
  defp answer_label(_answer, _options), do: "Unavailable"

  defp pending_follow_up(decision) do
    decision.revision_follow_ups
    |> Map.values()
    |> Enum.find(&is_nil(&1.handled_at))
  end

  defp revision_result_label(revision, current_sequence) when revision.sequence < current_sequence,
    do: "Superseded"

  defp revision_result_label(revision, _current_sequence) do
    revision.result |> to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp revision_result_chip(revision, current_sequence) when revision.sequence < current_sequence,
    do: "chip attention"

  defp revision_result_chip(%{result: :no_longer_applicable}, _current_sequence), do: "chip blocking"
  defp revision_result_chip(%{result: :dispatched}, _current_sequence), do: "chip good"
  defp revision_result_chip(_revision, _current_sequence), do: "chip super"

  defp confirmation_required?(decision) do
    Map.get(decision, :reversibility) == :irreversible or Map.get(decision, :kind) == "destructive_op"
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
