defmodule AiurWeb.OperatorControlCenter.CapacityControl do
  @moduledoc """
  Renders the authoritative runtime max-agent capacity and, when the dashboard
  is writable, named decrement/increment controls plus a validated
  positive-integer absolute input. All displayed facts come from the
  Orchestrator Slots contract via `CapacityPresenter`; the control never
  emulates scheduling or per-unit pause in the browser.
  """

  use Phoenix.Component

  attr(:capacity, :map, required: true)
  attr(:writable, :boolean, required: true)
  attr(:input, :string, default: "")
  attr(:feedback, :map, default: nil)

  @spec capacity_control(map()) :: Phoenix.LiveView.Rendered.t()
  def capacity_control(assigns) do
    ~H"""
    <section class="section-card capacity-card" aria-labelledby="capacity-title">
      <header class="section-header capacity-header">
        <div>
          <p class="section-eyebrow">Runtime control</p>
          <h2 id="capacity-title" tabindex="-1">Agent capacity</h2>
          <p>{@capacity.summary}</p>
        </div>
      </header>

      <dl class="capacity-facts">
        <div class="capacity-fact">
          <dt>Active</dt>
          <dd class="num">{@capacity.active_label}</dd>
        </div>
        <div class="capacity-fact">
          <dt>Maximum</dt>
          <dd class="num">{@capacity.max_label}</dd>
        </div>
        <div class="capacity-fact">
          <dt>Source</dt>
          <dd>{@capacity.source_label}</dd>
        </div>
        <div class="capacity-fact">
          <dt>State</dt>
          <dd>{@capacity.state_label}</dd>
        </div>
      </dl>

      <div :if={@writable} class="capacity-controls">
        <div class="capacity-steppers" role="group" aria-label="Adjust maximum agent capacity">
          <button
            id="capacity-decrement"
            type="button"
            class="capacity-button"
            phx-click="capacity-decrement"
            phx-disable-with="Applying…"
            disabled={not @capacity.can_decrement?}
            aria-label="Decrease maximum agent capacity"
          >
            <span aria-hidden="true">−1</span>
          </button>
          <span class="capacity-current num" aria-hidden="true">{@capacity.max_label}</span>
          <button
            id="capacity-increment"
            type="button"
            class="capacity-button"
            phx-click="capacity-increment"
            phx-disable-with="Applying…"
            aria-label="Increase maximum agent capacity"
          >
            <span aria-hidden="true">+1</span>
          </button>
        </div>

        <form class="capacity-set" phx-change="capacity-input-change" phx-submit="capacity-set">
          <label for="capacity-max-input">Set maximum agents</label>
          <div class="capacity-set-row">
            <input
              id="capacity-max-input"
              class="capacity-input num"
              type="number"
              name="max"
              inputmode="numeric"
              min={@capacity.min}
              step="1"
              value={@input}
              aria-describedby="capacity-status"
              autocomplete="off"
            />
            <button
              id="capacity-set"
              type="submit"
              class="capacity-button capacity-apply"
              phx-disable-with="Applying…"
            >
              Apply
            </button>
          </div>
        </form>
      </div>

      <p :if={not @writable} class="capacity-readonly" role="note">
        Read-only dashboard. Agent capacity is displayed but cannot be changed here.
      </p>

      <p
        id="capacity-status"
        class="capacity-status"
        role="status"
        aria-live="polite"
        aria-atomic="true"
        data-kind={feedback_kind(@feedback)}
      >
        {feedback_message(@feedback)}
      </p>
    </section>
    """
  end

  @spec feedback_message(map() | nil) :: String.t()
  def feedback_message(%{kind: :applied, max: max}) when is_integer(max),
    do: "Maximum agent capacity is now #{max}."

  def feedback_message(%{kind: :draining, max: max}) when is_integer(max),
    do: "Maximum agent capacity is now #{max}. Extra agents keep running and drain as they finish."

  def feedback_message(%{kind: :noop, max: max}) when is_integer(max),
    do: "Maximum agent capacity is unchanged at #{max}."

  def feedback_message(%{kind: :invalid}),
    do: "Enter a whole number of #{AiurWeb.OperatorControlCenter.CapacityPresenter.min()} or more."

  def feedback_message(%{kind: :timeout}),
    do: "The capacity service did not respond in time. The value shown may be stale; wait a moment and retry."

  def feedback_message(%{kind: :unavailable}),
    do: "Capacity control is unavailable right now. Wait a moment and retry."

  def feedback_message(_feedback), do: ""

  defp feedback_kind(%{kind: kind}) when is_atom(kind), do: to_string(kind)
  defp feedback_kind(_feedback), do: "idle"
end
