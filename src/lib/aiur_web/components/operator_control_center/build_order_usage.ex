defmodule AiurWeb.OperatorControlCenter.BuildOrderUsage do
  @moduledoc """
  Composes DASH-031's protected usage/cost summary onto the selected Build Order
  route as the `this build` scope.

  Scope-level states — loading, empty build, selected-invalid, graph unavailable,
  and a member set with no scopable tickets — render as distinct regions here, so
  none is confused with a zero total. When the selected member set is scopable the
  accounting states (loading, no retained usage, partial retention, unavailable,
  stale, ready) are delegated unchanged to the DASH-031
  `AiurWeb.OperatorControlCenter.UsageSummary` component; a stale member graph adds
  an explicit freshness note above it rather than hiding the last-known-good cost.
  """

  use Phoenix.Component

  alias AiurWeb.OperatorControlCenter.UsageSummary

  attr(:scope, :map, required: true)
  attr(:view, :map, default: nil)
  attr(:announcement, :string, default: nil)
  attr(:drill_down, :map, default: nil)
  attr(:drill_trigger, :string, default: nil)

  @spec build_order_usage(map()) :: Phoenix.LiveView.Rendered.t()
  def build_order_usage(assigns) do
    assigns = assign(assigns, :state, Map.get(assigns.scope, :state, :none))

    ~H"""
    <div :if={@state != :none} class="bo-usage" data-bo-usage-state={@state}>
      <.scope_state :if={@state != :ready} state={@state} scope={@scope} />

      <div :if={@state == :ready}>
        <UsageSummary.usage_summary
          :if={@view}
          view={@view}
          announcement={@announcement}
          drill_down={@drill_down}
          drill_trigger={@drill_trigger}
        />
      </div>
    </div>
    """
  end

  defp scope_state(%{state: :pending} = assigns) do
    ~H"""
    <section class="section-card bo-usage-state empty-state" aria-label="This build usage and cost">
      <p role="status" aria-live="polite">Loading usage and cost for this build…</p>
    </section>
    """
  end

  defp scope_state(%{state: :empty_build} = assigns) do
    ~H"""
    <section class="section-card bo-usage-state empty-state" aria-label="This build usage and cost">
      <h2>Usage and cost</h2>
      <p>This Build Order has no members yet, so there is no build-scoped usage to account.</p>
    </section>
    """
  end

  defp scope_state(%{state: :unscopable} = assigns) do
    ~H"""
    <section class="section-card bo-usage-state readonly-banner" role="status" aria-label="This build usage and cost">
      <h2>Usage and cost</h2>
      <p>
        This Build Order's {@scope.rejected} member(s) are not repository-qualified for accounting,
        so build-scoped usage cannot be attributed — this is not a zero total.
      </p>
    </section>
    """
  end

  defp scope_state(%{state: :graph_unavailable} = assigns) do
    ~H"""
    <section class="section-card bo-usage-state error-card" role="alert" aria-label="This build usage and cost">
      <h2>Usage and cost unavailable</h2>
      <p>The current Build Order's units cannot be read right now, so usage for this build is unavailable.</p>
    </section>
    """
  end

  defp scope_state(%{state: :invalid} = assigns) do
    ~H"""
    <section class="section-card bo-usage-state error-card" role="alert" aria-label="This build usage and cost">
      <h2>Usage and cost unavailable</h2>
      <p>The selected Build Order is not valid, so there is no build scope to account.</p>
    </section>
    """
  end

  defp scope_state(assigns) do
    ~H"""
    <section class="section-card bo-usage-state empty-state" aria-label="This build usage and cost">
      <p role="status">Usage and cost for this build is not available.</p>
    </section>
    """
  end
end
