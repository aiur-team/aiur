defmodule AiurWeb.OperatorControlCenter.AgentUsageSnapshot do
  @moduledoc """
  Displays per-agent cumulative token usage with scope and freshness labels.

  Separates current context occupancy (active working set) from cumulative
  metrics (lifetime usage). Handles unknowns explicitly without zero conversion.
  """

  use Phoenix.Component

  alias Aiur.Agent.UsageSnapshot
  alias Aiur.AgentContextPresentation

  attr(:snapshot, :map, default: nil, doc: "UsageSnapshot struct or nil")
  attr(:context_occupancy, :map, default: nil, doc: "Current context occupancy map")
  attr(:error, :atom, default: nil, doc: "Error atom if snapshot unavailable")

  @spec agent_usage_snapshot(map()) :: Phoenix.LiveView.Rendered.t()
  def agent_usage_snapshot(assigns) do
    ~H"""
    <section class="agent-usage-snapshot" data-agent-usage-state={state_for(@snapshot, @error)}>
      <!-- Current Context Occupancy Section -->
      <div class="usage-section context-occupancy">
        <h3>Current Context</h3>
        <div class="usage-value">
          <%= AgentContextPresentation.label(@context_occupancy) %>
        </div>
      </div>

      <!-- Cumulative Metrics Section -->
      <div :if={@snapshot} class="usage-section cumulative-metrics">
        <h3>Cumulative Token Usage</h3>

        <div class="usage-metrics-table">
          <div class="metric-row">
            <span class="metric-label">Input tokens</span>
            <span class="metric-value"><%= format_value(@snapshot.cumulative_metrics.input) %></span>
          </div>

          <div class="metric-row">
            <span class="metric-label">Output tokens</span>
            <span class="metric-value"><%= format_value(@snapshot.cumulative_metrics.output) %></span>
          </div>

          <div class="metric-row">
            <span class="metric-label">Cached input</span>
            <span class="metric-value"><%= format_value(@snapshot.cumulative_metrics.cached_input) %></span>
          </div>

          <div class="metric-row">
            <span class="metric-label">Uncached input</span>
            <span class="metric-value"><%= format_value(@snapshot.cumulative_metrics.uncached_input) %></span>
          </div>

          <div class="metric-row cached-proportion">
            <span class="metric-label">Cached proportion</span>
            <span class="metric-value"><%= format_proportion(@snapshot.cumulative_metrics.cached_proportion) %></span>
          </div>
        </div>

        <!-- Scope and Freshness Labels -->
        <div class="usage-metadata">
          <span class="scope-label">
            <%= scope_label(@snapshot.scope, @snapshot.scope_id) %>
          </span>
          <span class="freshness-label">
            <%= UsageSnapshot.format_freshness(@snapshot.freshness_assessment, @snapshot.observed_at) %>
          </span>
        </div>
      </div>

      <!-- Error State -->
      <div :if={@error and !@snapshot} class="usage-section error-state">
        <p class="usage-error">Usage data unavailable</p>
        <p class="usage-error-detail"><%= error_message(@error) %></p>
      </div>
    </section>
    """
  end

  # Format a token dimension value (known integer or unknown)
  defp format_value(value) do
    UsageSnapshot.format_token_dimension(value)
  end

  # Format a cached proportion (float or unknown)
  defp format_proportion(value) do
    UsageSnapshot.format_cached_proportion(value)
  end

  # Build scope label text
  defp scope_label(:session, scope_id) do
    "Current session (#{scope_id})"
  end

  defp scope_label(:attempt, scope_id) do
    "Current attempt (#{scope_id})"
  end

  defp scope_label(:ticket, scope_id) do
    "Current ticket (#{scope_id})"
  end

  defp scope_label(_scope, scope_id) do
    "Unknown scope (#{scope_id})"
  end

  # Determine state for data attribute
  defp state_for(snapshot, error) do
    cond do
      error -> "error"
      snapshot -> "ready"
      true -> "none"
    end
  end

  # Format error message for display
  defp error_message(:no_usage_data) do
    "This agent has not reported any usage yet."
  end

  defp error_message(:unable_to_resolve_scope) do
    "Could not determine the scope for usage query."
  end

  defp error_message(:unable_to_query_aggregate) do
    "Failed to query usage data from the system."
  end

  defp error_message(:aggregate_query_failed) do
    "An error occurred while querying usage data."
  end

  defp error_message(_error) do
    "Usage data could not be retrieved."
  end
end
