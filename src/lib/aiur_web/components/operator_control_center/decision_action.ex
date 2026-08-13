defmodule AiurWeb.OperatorControlCenter.DecisionAction do
  @moduledoc false

  use Phoenix.Component

  attr(:decision, :map, required: true)
  attr(:state, :map, default: %{})
  attr(:writable, :boolean, required: true)
  attr(:compact, :boolean, default: false)

  @spec decision_action(map()) :: Phoenix.LiveView.Rendered.t()
  def decision_action(assigns) do
    form = Map.get(assigns.state, :form, %{})
    choice = Map.get(form, "choice") || default_choice(assigns.decision)

    assigns =
      assign(assigns,
        form: form,
        choice: choice,
        answerable?: assigns.decision.decision_status in [:open, :deferred, :dismissed],
        deferrable?: assigns.decision.decision_status in [:open, :deferred],
        # Only offer the control where dismissal genuinely clears the block:
        # the dashboard resolves the underlying legacy attention alongside it.
        # An agent-filed blocking Command has no such path and the store
        # refuses it, so it must be answered rather than closed.
        dismissible?:
          Map.get(assigns.decision, :blocking, false) and
            not is_nil(Map.get(assigns.decision, :legacy_attention)) and
            assigns.decision.decision_status in [:open, :deferred],
        acknowledgeable?: assigns.decision.options == [] and assigns.decision.decision_status == :open and not Map.get(assigns.decision, :blocking, false),
        error: Map.get(assigns.state, :error),
        notice: Map.get(assigns.state, :notice)
      )

    ~H"""
    <section class={["decision-action", @compact && "compact"]} aria-label="Command actions">

      <p :if={@error} class="decision-action-message error" role="alert">{@error}</p>
      <p :if={@notice} class="decision-action-message success" role="status">{@notice}</p>

      <form
        :if={@writable and @answerable?}
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
              <small>Record a response in your own words.</small>
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
            placeholder="State the Command response clearly…"
          >{Map.get(@form, "custom_response", "")}</textarea>
        </label>

        <footer class="decision-action-footer">
          <div class="decision-action-buttons">
            <button
              :if={@deferrable?}
              class="btn ghost"
              type="button"
              phx-click="defer-decision"
              phx-value-decision-id={@decision.decision_id}
              phx-disable-with="Deferring…"
            >{if @decision.decision_status == :deferred, do: "Notify Executor again", else: "Defer to Executor"}</button>
            <button
              :if={@dismissible?}
              class="btn ghost icon-only decision-dismiss"
              type="button"
              phx-click="dismiss-decision"
              phx-value-decision-id={@decision.decision_id}
              phx-disable-with="×"
              aria-label="Dismiss blocker"
              title="Dismiss blocker"
            >×</button>
            <button
              :if={@acknowledgeable?}
              class="btn ghost"
              type="button"
              phx-click="dismiss-decision"
              phx-value-decision-id={@decision.decision_id}
              phx-disable-with="Acknowledging…"
            >Acknowledge</button>
            <button class="btn" type="submit" phx-disable-with="Recording…">{if @decision.decision_status in [:dismissed, :deferred], do: "Change choice", else: "Decision"}</button>
          </div>
        </footer>
      </form>

      <div :if={!@answerable? and @decision.answer} class="decision-answer-summary">
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

  defp answer_label(%{answer: %{selected_option_id: option_id}} = decision) when is_binary(option_id) do
    case Enum.find(decision.options, &(&1.id == option_id)) do
      nil -> "Option #{option_id}"
      option -> option.label
    end
  end

  defp answer_label(%{answer: %{custom_response: response}}), do: response

  defp answer_label(_decision), do: "Unavailable"

  defp recommended?(%{recommendation: nil}, _option), do: false
  defp recommended?(decision, option), do: decision.recommendation.option_id == option.id
  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp failure_copy(nil), do: "The durable action remains available for an explicit retry."
  defp failure_copy(reason), do: "#{humanize(reason)}. The durable action remains available for an explicit retry."
  defp humanize(nil), do: "Unknown"
  defp humanize(value), do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()
end
