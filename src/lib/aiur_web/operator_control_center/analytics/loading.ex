defmodule AiurWeb.OperatorControlCenter.Analytics.Loading do
  @moduledoc "Renders loading feedback and timeout state for Analytics."

  use Phoenix.Component

  attr(:state, :atom, required: true)
  attr(:elapsed_seconds, :integer, required: true)
  attr(:timeout_seconds, :float, required: true)
  attr(:refreshing?, :boolean, default: false)
  attr(:refresh_timed_out?, :boolean, default: false)

  @spec state(map()) :: Phoenix.LiveView.Rendered.t()
  def state(assigns) do
    ~H"""
    <p :if={@state == :loading} role="status" class="an-empty">Loading run analytics… waited {@elapsed_seconds}s.</p>
    <p :if={@refreshing?} role="status" class="an-empty">Showing the last computed analytics result while refreshing.</p>
    <p :if={@refresh_timed_out?} role="status" class="an-empty">The refresh timed out. Showing the last computed analytics result.</p>
    <div :if={@state == :timeout} class="an-empty" data-empty-reason="timeout">
      <p><b>Run analytics timed out.</b></p>
      <p>The analytics scan did not finish within {@timeout_seconds} seconds. Reload the page to try again.</p>
    </div>
    """
  end
end
