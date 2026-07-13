defmodule AiurWeb.OperatorControlCenter.DecisionDetail do
  @moduledoc false

  use Phoenix.Component

  alias AiurWeb.OperatorControlCenter.{DecisionAction, DecisionPath, DecisionRevisionAction, LifecycleComponents}

  attr(:decision, :map, required: true)
  attr(:history, :list, default: [])
  attr(:action_state, :map, default: %{})
  attr(:writable, :boolean, required: true)
  attr(:filter, :atom, default: :all)

  @spec decision_detail(map()) :: Phoenix.LiveView.Rendered.t()
  def decision_detail(assigns) do
    assigns =
      assigns
      |> assign(:collapse_path, DecisionPath.inbox(assigns.filter))
      |> assign(:ticket_url, trusted_url(assigns.decision.ticket[:url]))
      |> assign(:history_rows, Enum.filter(assigns.history, &(&1.decision_id == assigns.decision.decision_id)))

    ~H"""
    <div id={"decision-detail-#{@decision.decision_id}"} class="decision-detail" tabindex="-1">
      <LifecycleComponents.lifecycle_stepper lifecycle={@decision.lifecycle} />
      <DecisionAction.decision_action decision={@decision} state={@action_state} writable={@writable} />
      <DecisionRevisionAction.decision_revision_action decision={@decision} state={@action_state} writable={@writable} />

      <div class="decision-detail-grid">
        <div>
          <.detail_block title="Context">
            <p :if={present?(@decision.context.short)} class="context-summary">{@decision.context.short}</p>
            <div class="markdown-source">{@decision.context.long_markdown || "No extended context was recorded."}</div>
          </.detail_block>

          <.detail_block :if={present?(@decision.consequence_of_delay)} title="If no one answers">
            <div class="decision-callout">{@decision.consequence_of_delay}</div>
          </.detail_block>

          <.detail_block :if={@decision.options != []} title="Options">
            <div class="option-list">
              <article
                :for={option <- @decision.options}
                class={["option-card", recommended?(@decision, option) && "recommended"]}
              >
                <header class="option-head">
                  <span class="option-key mono">{option.id}</span>
                  <strong>{option.label}</strong>
                  <span :if={present?(option.risk)} class={["risk-tag", risk_class(option.risk)]}>{String.upcase(option.risk)} risk</span>
                  <span :if={recommended?(@decision, option)} class="chip super">Recommended</span>
                </header>
                <p :if={present?(option.description)}>{option.description}</p>
                <div :if={present?(option.benefits) or present?(option.drawbacks)} class="option-columns">
                  <div :if={present?(option.benefits)}><h5>Benefits</h5><p>{option.benefits}</p></div>
                  <div :if={present?(option.drawbacks)}><h5>Drawbacks</h5><p>{option.drawbacks}</p></div>
                </div>
              </article>
            </div>
          </.detail_block>

          <.detail_block :if={@decision.recommendation} title="Recommendation">
            <div class="recommendation">
              <strong>Option {@decision.recommendation.option_id}</strong>
              <p>{@decision.recommendation.reason || "No rationale was recorded."}</p>
            </div>
          </.detail_block>
        </div>

        <div>
          <.detail_block title="Decision metadata">
            <dl class="metadata-list">
              <div><dt>Authority</dt><dd>{humanize(@decision.authority)}</dd></div>
              <div><dt>Urgency</dt><dd>{humanize(@decision.urgency)}</dd></div>
              <div><dt>Reversibility</dt><dd>{humanize(@decision.reversibility)}</dd></div>
              <div><dt>Decision state</dt><dd>{humanize(@decision.decision_status)}</dd></div>
              <div><dt>Delivery state</dt><dd>{humanize(@decision.delivery_status)}</dd></div>
              <div><dt>Version</dt><dd class="mono num">{@decision.version}</dd></div>
              <div><dt>Source agent</dt><dd class="mono">{@decision.source[:agent_id] || "unknown"}</dd></div>
              <div><dt>Recorded</dt><dd class="mono">{format_datetime(@decision.created_at)}</dd></div>
            </dl>
          </.detail_block>

          <.detail_block title="Links & artifacts">
            <div class="link-list">
              <a :if={@ticket_url} class="link-pill" href={@ticket_url} target="_blank" rel="noopener noreferrer">Issue {@decision.ticket[:identifier]} ↗</a>
              <span :if={!@ticket_url} class="link-pill">Issue {@decision.ticket[:identifier]}</span>
              <.artifact :for={artifact <- @decision.artifacts} artifact={artifact} />
            </div>
          </.detail_block>

          <.detail_block :if={@history_rows != []} title="Activity & decision timeline">
            <ol class="decision-timeline">
              <li :for={entry <- @history_rows}>
                <span class="timeline-time mono">{format_datetime(entry.changed_at)}</span>
                <strong>{humanize(entry.change)}</strong>
                <p :if={present?(entry.rationale)}>{entry.rationale}</p>
              </li>
            </ol>
          </.detail_block>

          <p :if={!@writable} class="decision-readonly-note">Read-only mode · mutation controls are hidden.</p>
        </div>
      </div>

      <footer class="decision-detail-footer">
        <.link patch={@collapse_path} class="btn ghost">Collapse details</.link>
      </footer>
    </div>
    """
  end

  attr(:title, :string, required: true)
  slot(:inner_block, required: true)

  defp detail_block(assigns) do
    ~H"""
    <section class="detail-block">
      <h4>{@title}</h4>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr(:artifact, :map, required: true)

  defp artifact(assigns) do
    url = if assigns.artifact[:kind] == :url, do: trusted_url(assigns.artifact[:value])
    assigns = assign(assigns, :url, url)

    ~H"""
    <a :if={@url} class="link-pill" href={@url} target="_blank" rel="noopener noreferrer">{@artifact[:value]} ↗</a>
    <code :if={!@url} class="artifact-path">{@artifact[:value]}</code>
    """
  end

  defp recommended?(%{recommendation: nil}, _option), do: false
  defp recommended?(decision, option), do: decision.recommendation.option_id == option.id

  defp risk_class("high"), do: "risk-high"
  defp risk_class("medium"), do: "risk-medium"
  defp risk_class("med"), do: "risk-medium"
  defp risk_class(_risk), do: "risk-low"

  defp trusted_url(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) -> value
      _uri -> nil
    end
  end

  defp trusted_url(_value), do: nil
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp humanize(nil), do: "Unknown"
  defp humanize(value), do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()
  defp format_datetime(%DateTime{} = datetime), do: datetime |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp format_datetime(value) when is_binary(value), do: value
  defp format_datetime(_value), do: "unknown"
end
