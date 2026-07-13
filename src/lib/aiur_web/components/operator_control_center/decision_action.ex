defmodule AiurWeb.OperatorControlCenter.DecisionAction do
  @moduledoc false

  use Phoenix.Component

  attr(:decision, :map, required: true)
  attr(:state, :map, default: %{})
  attr(:writable, :boolean, required: true)

  @spec decision_action(map()) :: Phoenix.LiveView.Rendered.t()
  def decision_action(assigns) do
    form = Map.get(assigns.state, :form, %{})
    choice = Map.get(form, "choice") || default_choice(assigns.decision)

    assigns =
      assign(assigns,
        form: form,
        choice: choice,
        open?: assigns.decision.decision_status == :open,
        confirmation_required?: confirmation_required?(assigns.decision),
        error: Map.get(assigns.state, :error),
        notice: Map.get(assigns.state, :notice)
      )

    ~H"""
    <section class="decision-action" aria-labelledby={"decision-action-title-#{@decision.decision_id}"}>
      <header class="decision-action-header">
        <div>
          <p class="section-eyebrow">Durable command</p>
          <h4 id={"decision-action-title-#{@decision.decision_id}"}>{action_title(@decision)}</h4>
        </div>
        <div class="decision-axis" aria-label="Canonical decision and delivery state">
          <span class={axis_chip(@decision.decision_status)}>Decision · {humanize(@decision.decision_status)}</span>
          <span class={axis_chip(@decision.delivery_status)}>Delivery · {humanize(@decision.delivery_status)}</span>
        </div>
      </header>

      <p :if={@error} class="decision-action-message error" role="alert">{@error}</p>
      <p :if={@notice} class="decision-action-message success" role="status">{@notice}</p>

      <form
        :if={@writable and @open?}
        id={"decision-answer-form-#{@decision.decision_id}"}
        class="decision-answer-form"
        phx-change="decision-action-change"
        phx-submit="answer-decision"
      >
        <input type="hidden" name="decision_id" value={@decision.decision_id} />

        <fieldset :if={@decision.options != []} class="decision-choice-list">
          <legend class="sr-only">Choose an answer</legend>
          <label
            :for={option <- @decision.options}
            class={[
              "decision-choice",
              @choice == "option:#{option.id}" && "selected",
              recommended?(@decision, option) && "recommended"
            ]}
          >
            <input
              type="radio"
              name="answer[choice]"
              value={"option:#{option.id}"}
              checked={@choice == "option:#{option.id}"}
            />
            <span class="decision-choice-copy">
              <strong>{option.label}</strong>
              <small :if={present?(option.description)}>{option.description}</small>
            </span>
            <span :if={recommended?(@decision, option)} class="chip super">Recommended</span>
          </label>

          <label class={["decision-choice", "custom", @choice == "custom" && "selected"]}>
            <input type="radio" name="answer[choice]" value="custom" checked={@choice == "custom"} />
            <span class="decision-choice-copy">
              <strong>Custom response</strong>
              <small>Record a bounded response in your own words.</small>
            </span>
          </label>
        </fieldset>

        <input :if={@decision.options == []} type="hidden" name="answer[choice]" value="custom" />

        <label :if={@choice == "custom"} class="decision-action-field">
          <span>Response</span>
          <textarea
            name="answer[custom_response]"
            rows="4"
            maxlength="4000"
            required
            placeholder="State the decision clearly…"
          >{Map.get(@form, "custom_response", "")}</textarea>
        </label>

        <label class="decision-action-field">
          <span>Rationale <small>optional</small></span>
          <textarea name="answer[rationale]" rows="2" maxlength="4000" placeholder="Why this choice?">{Map.get(@form, "rationale", "")}</textarea>
        </label>

        <label :if={@confirmation_required?} class="decision-confirmation">
          <input
            type="checkbox"
            name="answer[confirmed]"
            value="true"
            checked={Map.get(@form, "confirmed") == "true"}
          />
          <span>I understand this decision is irreversible or destructive.</span>
        </label>

        <footer class="decision-action-footer">
          <span>Persisted before dispatch · version {@decision.version}</span>
          <button class="btn" type="submit" phx-disable-with="Recording…">Record answer</button>
        </footer>
      </form>

      <div :if={!@open? and @decision.answer} class="decision-answer-summary">
        <div>
          <span class="decision-answer-label">{if Map.get(@decision, :revision_sequence, 0) > 0, do: "Current revised answer", else: "Recorded answer"}</span>
          <strong>{answer_label(@decision)}</strong>
          <p :if={present?(@decision.answer.rationale)}>{@decision.answer.rationale}</p>
        </div>
        <dl>
          <div><dt>Action</dt><dd class="mono">{@decision.answer.action_id}</dd></div>
          <div><dt>Answered version</dt><dd class="mono num">{@decision.answer.decision_version}</dd></div>
        </dl>
      </div>

      <div :if={@decision.lifecycle == :delivery_failed} class="decision-retry-row">
        <div>
          <strong>Delivery failed</strong>
          <p>{failure_copy(@decision.failure_reason)}</p>
        </div>
        <button
          :if={@writable and @decision.retryable}
          type="button"
          class="btn danger"
          phx-click="retry-decision"
          phx-value-decision-id={@decision.decision_id}
          phx-value-action-id={@decision.answer.action_id}
          phx-disable-with="Scheduling…"
        >Retry delivery</button>
      </div>
    </section>
    """
  end

  defp default_choice(%{options: []}), do: "custom"

  defp default_choice(decision) do
    option_id = get_in(decision, [:recommendation, :option_id]) || decision.options |> List.first() |> Map.fetch!(:id)
    "option:#{option_id}"
  end

  defp action_title(%{decision_status: :open}), do: "Answer this decision"
  defp action_title(_decision), do: "Answer lifecycle"

  defp answer_label(%{answer: %{selected_option_id: option_id}} = decision) when is_binary(option_id) do
    case Enum.find(decision.options, &(&1.id == option_id)) do
      nil -> "Option #{option_id}"
      option -> option.label
    end
  end

  defp answer_label(%{answer: %{custom_response: response}}), do: response

  defp answer_label(_decision), do: "Unavailable"

  defp confirmation_required?(decision) do
    Map.get(decision, :reversibility) == :irreversible or Map.get(decision, :kind) == "destructive_op"
  end

  defp recommended?(%{recommendation: nil}, _option), do: false
  defp recommended?(decision, option), do: decision.recommendation.option_id == option.id
  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp axis_chip(status) when status in [:resolved, :acknowledged, :delivered, :consumed], do: "chip good"
  defp axis_chip(status) when status in [:failed], do: "chip blocking"
  defp axis_chip(status) when status in [:decided, :pending, :queued], do: "chip accent"
  defp axis_chip(_status), do: "chip attention"

  defp failure_copy(nil), do: "The durable action remains available for an explicit retry."
  defp failure_copy(reason), do: "#{humanize(reason)}. The durable action remains available for an explicit retry."
  defp humanize(nil), do: "Unknown"
  defp humanize(value), do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()
end
