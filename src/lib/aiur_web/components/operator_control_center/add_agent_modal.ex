defmodule AiurWeb.OperatorControlCenter.AddAgentModal do
  @moduledoc false

  use Phoenix.Component

  alias Phoenix.LiveView.JS

  attr(:modal, :map, default: nil)
  attr(:writable, :boolean, default: false)

  @spec add_agent_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def add_agent_modal(assigns) do
    ~H"""
    <div :if={@modal} class="modal-backdrop add-agent-backdrop">
      <section
        id="add-agent-modal"
        class="modal-panel add-agent-modal"
        role="dialog"
        aria-modal="true"
        aria-labelledby="add-agent-title"
        phx-click-away="close-add-agent"
        phx-window-keydown="close-add-agent"
        phx-key="escape"
        phx-mounted={JS.focus(to: "#add-agent-title")}
      >
        <header class="modal-header">
          <div>
            <p class="section-eyebrow">Add an agent</p>
            <h2 id="add-agent-title" tabindex="-1">#{@modal.identifier} {@modal.title}</h2>
          </div>
          <div class="modal-actions">
            <button type="button" class="tool-btn" phx-click="close-add-agent">Close</button>
          </div>
        </header>

        <p class="modal-meta">
          Prefilled from the current routing configuration and this ticket's labels. Change anything before confirming.
        </p>

        <form class="add-agent-form" phx-change="change-add-agent" phx-submit="confirm-add-agent">
          <label class="add-agent-field">
            <span>Agent</span>
            <select name="backend" disabled={@modal.options.backends == []}>
              <option :for={backend <- @modal.options.backends} value={backend} selected={backend == @modal.selection.backend}>
                {backend}
              </option>
            </select>
          </label>

          <label class="add-agent-field">
            <span>Model</span>
            <select name="model">
              <option value="" selected={blank?(@modal.selection.model)}>Backend default</option>
              <option :for={model <- @modal.options.models} value={model} selected={model == @modal.selection.model}>
                {model}
              </option>
            </select>
          </label>

          <label class="add-agent-field" :if={@modal.options.efforts != []}>
            <span>Effort</span>
            <select name="effort">
              <option value="" selected={blank?(@modal.selection.effort)}>Backend default</option>
              <option :for={effort <- @modal.options.efforts} value={effort} selected={effort == @modal.selection.effort}>
                {effort}
              </option>
            </select>
          </label>

          <label class="add-agent-field">
            <span>Complexity</span>
            <select name="complexity">
              <option value="" selected={is_nil(@modal.selection.complexity)}>Untagged</option>
              <option
                :for={complexity <- @modal.options.complexities}
                value={complexity}
                selected={complexity == @modal.selection.complexity}
              >complexity:{complexity}</option>
            </select>
          </label>

          <div class="add-agent-preview">
            <p class="section-eyebrow">Labels to apply</p>
            <div class="ut-pill-row">
              <span :for={label <- @modal.plan.add} class="u-pill u-label">{label}</span>
              <span :if={@modal.plan.add == []} class="tk-muted">Nothing to add — the ticket already carries these labels.</span>
            </div>
          </div>

          <div :if={@modal.plan.remove != []} class="add-agent-preview">
            <p class="section-eyebrow">Labels to replace</p>
            <div class="ut-pill-row">
              <span :for={label <- @modal.plan.remove} class="u-pill u-label is-more">{label}</span>
            </div>
          </div>

          <p :if={!@modal.routing.available?} class="add-agent-note" role="status">
            The routing configuration could not be read, so nothing is prefilled.
          </p>

          <p :if={@modal.result} class={["add-agent-note", result_tone(@modal.result)]} role="status">{result_message(@modal.result)}</p>

          <div class="add-agent-actions">
            <button type="button" class="btn ghost" phx-click="close-add-agent">Cancel</button>
            <button type="submit" class="btn" disabled={!@writable or empty_plan?(@modal.plan) or applied?(@modal.result)}>Confirm</button>
          </div>
        </form>

        <p :if={!@writable} class="agent-chat-readonly">Read-only dashboard — use the CLI to label this ticket.</p>
      </section>
    </div>
    """
  end

  defp blank?(value), do: is_nil(value) or value == ""

  defp empty_plan?(%{add: [], remove: []}), do: true
  defp empty_plan?(_plan), do: false

  defp applied?({:ok, _labels}), do: true
  defp applied?(_result), do: false

  defp result_tone({:ok, _labels}), do: "is-applied"
  defp result_tone(_result), do: "is-error"

  defp result_message({:ok, labels}), do: "Applied #{Enum.join(labels, ", ")}."

  # A halted label write leaves the ticket half-changed; saying "nothing was
  # applied" would be a confident wrong claim about the tracker's state.
  defp result_message({:partial, [], reason}), do: "Nothing was applied: #{reason_text(reason)}"

  defp result_message({:partial, applied, reason}),
    do: "Applied #{Enum.join(applied, ", ")}, then stopped: #{reason_text(reason)} The ticket is partly labelled."

  defp result_message({:error, :no_labels}), do: "This selection changes nothing on the ticket."
  defp result_message({:error, reason}), do: "Could not apply labels: #{reason_text(reason)}"
  defp result_message(_result), do: ""

  defp reason_text(:unavailable), do: "the tracker is unavailable."
  defp reason_text(reason), do: "#{inspect(reason)}."
end
