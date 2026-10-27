defmodule AiurWeb.OperatorControlCenter.ListenerMode do
  @moduledoc "Listener mode, fallback, unread age and message receipt presentation."
  use Phoenix.Component

  @modes [:steer, :sync, :async]

  attr(:listener, :any, default: :unavailable)
  attr(:writable, :boolean, default: false)
  attr(:now, :any, required: true)
  attr(:feedback, :map, default: %{})
  attr(:badge, :boolean, default: false)

  @spec listener_mode(map()) :: Phoenix.LiveView.Rendered.t()
  def listener_mode(assigns) do
    assigns = assign(assigns, :known, is_map(assigns.listener))

    ~H"""
    <div class="listener-mode" data-listener-state={if(@known, do: @feedback[:state] || :known, else: @listener)} role="status">
      <%= if @known do %>
        <span data-requested-mode={@listener[:requested]}>Requested: {mode_label(@listener[:requested])}</span>
        <span :if={@listener[:effective] != @listener[:requested]} data-effective-mode={@listener[:effective] || :unavailable}>
          Effective: {mode_label(@listener[:effective])} — {reason(@listener[:effective_reason])}
        </span>
        <span :if={@listener[:effective_reason] && @listener[:effective] == @listener[:requested]}>{reason(@listener[:effective_reason])}</span>
        <span :if={@listener[:status] == :paused}>Agent paused</span>
        <span :if={@listener[:routing] == :legacy}>Legacy routing — mode does not control delivery</span>
        <span :if={is_integer(@listener[:unread_count])} data-unread-count={@listener[:unread_count]}>
          Unread {@listener[:unread_count]}<span :if={@listener[:unread_count] > 0}> · oldest {age(@listener[:oldest_unread_at], @now)}</span>
        </span>
        <span data-observed-at={timestamp(@listener[:observed_at])}>
          {if(@listener[:freshness] in [:stale, :offline], do: "Stale · ", else: "Observed ")}{age(@listener[:observed_at], @now)}
        </span>
        <form :if={!@badge && @listener[:routing] == :listener} phx-change="set_listen_mode">
          <input type="hidden" name="expected_version" value={@listener[:version]} />
          <label>Listener mode
            <select name="mode" aria-label="Listener mode" disabled={!@writable || @feedback[:state] == :pending || @listener[:freshness] in [:stale, :offline]}>
              <option :for={mode <- modes()} value={mode} selected={mode == @listener[:requested]}>{mode_label(mode)}</option>
            </select>
          </label>
        </form>
        <p :if={!@badge && !@writable}>Read-only dashboard — listener mode cannot be changed.</p>
        <p :if={@feedback[:state] == :pending}>Changing listener mode… waiting for confirmation.</p>
        <p :if={@feedback[:state] == :conflict}>Mode changed elsewhere. Current winner: {mode_label(@listener[:requested])}. Your choice: {mode_label(@feedback[:choice])}. Choose again or discard it.</p>
        <p :if={@feedback[:state] == :error}>Listener change could not be confirmed. Refresh the current mode before retrying.</p>
        <button :if={@feedback[:state] in [:conflict, :error]} type="button" phx-click="refresh_listen_mode">Refresh current mode / discard choice</button>
        <p :if={@feedback[:left_async]}>Unread messages remain on demand after leaving Async.</p>
      <% else %>
        <span>{if(@listener == :loading, do: "Loading listener mode…", else: "Listener mode unavailable")}</span>
      <% end %>
    </div>
    """
  end

  attr(:receipt, :map, required: true)
  @spec receipt(map()) :: Phoenix.LiveView.Rendered.t()
  def receipt(assigns) do
    ~H"""
    <p class="listener-receipt" data-receipt={@receipt[:receipt] || :unknown}>
      Message {@receipt[:request_id]}: {receipt_label(@receipt[:receipt])}
    </p>
    """
  end

  @spec modes() :: [atom()]
  def modes, do: @modes
  @spec mode_label(term()) :: String.t()
  def mode_label(:steer), do: "Steer · interrupts"
  def mode_label(:sync), do: "Sync · next turn"
  def mode_label(:async), do: "Async · on demand"
  def mode_label(_unknown), do: "Unavailable"

  defp reason(:not_running), do: "Agent not running"
  defp reason(:harness_unknown), do: "Harness support unknown"
  defp reason(:pull_tool_unavailable), do: "On-demand reading unavailable for this harness"
  defp reason(:steer_not_wired), do: "Steer is not available for this harness"
  defp reason(:no_interrupt), do: "This harness cannot interrupt"
  defp reason(:no_turn_boundary), do: "This harness has no turn boundary"
  defp reason(:pending_session_start), do: "Waiting for agent session"
  defp reason(:emulated_interrupt), do: "Interrupts current turn"
  defp reason(_unknown), do: "Reason unavailable"

  defp receipt_label(:accepted), do: "Accepted"
  defp receipt_label(:waiting_turn_end), do: "Waiting for turn end"
  defp receipt_label(:held_async), do: "Held for the agent to read"
  defp receipt_label(:harness_queued), do: "Handed to the agent"
  defp receipt_label(:in_context), do: "In context"
  defp receipt_label(:read), do: "Read"
  defp receipt_label(:failed), do: "Failed"
  defp receipt_label(_unknown), do: "Outcome unknown"

  defp timestamp(%DateTime{} = time), do: DateTime.to_iso8601(time)
  defp timestamp(_unknown), do: nil
  defp age(%DateTime{} = time, %DateTime{} = now), do: "#{max(DateTime.diff(now, time), 0)}s ago"
  defp age(_time, _now), do: "age unavailable"
end
