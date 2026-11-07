defmodule AiurWeb.ExecutorView do
  @moduledoc "Executor binding states and the footer presentation layered over the shared conversation chronology."
  use Phoenix.Component
  alias Aiur.Executor.Session

  @spec present(map()) :: map()
  def present(assigns) do
    binding = if Process.whereis(Session), do: Session.current(), else: :none
    capability = Aiur.Capabilities.report().capabilities["executor.conversation"]
    state = state(assigns, binding)
    entry = assigns.last_entry
    unreadable? = entry && entry.kind == "gap" && (entry.meta["reason"] || entry.meta[:reason]) in ["source_unreadable", :source_unreadable]
    %{state: state, age: assigns.age, reason: assigns.reason, last_entry: entry, unreadable?: unreadable?, capability: capability}
  end

  defp state(%{state: :loading}, _binding), do: :loading
  defp state(%{read_error: error}, _binding) when error not in [nil, :not_found], do: :unavailable
  defp state(_assigns, {:ok, %{state: "awaiting_first_hook"}}), do: :awaiting_hook
  defp state(_assigns, {:ok, %{state: "detached"}}), do: :ended
  defp state(%{page: page}, :none) when not is_nil(page) and page.head_pos > 0, do: :ended
  defp state(%{state: state}, :none) when state in [:known_empty, :not_found], do: :not_opted_in
  defp state(assigns, _binding), do: assigns.state

  # States whose meaning depends on how old the reading is.
  @aged [:unknown, :restart_unknown, :degraded, :unavailable, :live, :idle]

  @doc """
  The footer's compact state line. Unknown and stale states carry their age, so a
  missing reading is never shown as a plausible `idle`.
  """
  @spec summary(map()) :: String.t()
  def summary(%{state: state, age: age}) do
    case {short(state), age} do
      {text, %{freshness: :unknown}} when state in @aged -> "#{text} · age unknown"
      {text, %{freshness: :stale, age_ms: ms}} when state in @aged -> "#{text} #{compact(ms)}"
      {text, _age} -> text
    end
  end

  defp short(:live), do: "attached"
  defp short(:idle), do: "idle"
  defp short(:not_opted_in), do: "not attached"
  defp short(:awaiting_hook), do: "waiting for session"
  defp short(:ended), do: "ended"
  defp short(:loading), do: "loading"
  defp short(:known_empty), do: "attached · no messages yet"
  defp short(:degraded), do: "stale"
  defp short(:unavailable), do: "unavailable"
  defp short(_state), do: "unknown"

  defp compact(ms) when ms < 3_600_000, do: "#{div(ms, 60_000)}m"
  defp compact(ms) when ms < 86_400_000, do: "#{div(ms, 3_600_000)}h"
  defp compact(ms), do: "#{div(ms, 86_400_000)}d"

  @spec event_label(map()) :: String.t()
  def event_label(anchor), do: anchor["label"] || Aiur.Conversation.JumpPoints.label(anchor["kind"], %{})

  attr(:view, :map, required: true)
  attr(:writable, :boolean, required: true)
  @spec notices(map()) :: Phoenix.LiveView.Rendered.t()
  def notices(assigns) do
    ~H"""
    <div id="executor-frame" class="executor-frame" data-state={@view.state}>
      <p :if={@view.state == :not_opted_in}>
        Not attached. Run <code>aiur executor-attach --harness claude</code> (or <code>--harness codex</code>) in your repository.
        <a href="https://aiur.team/docs/guide/gui#executor">Setup</a>
      </p>
      <p :if={@view.state == :loading} role="status">Loading Executor history…</p>
      <p :if={@view.state == :awaiting_hook}>Waiting for the Executor session. Run <code>aiur executor-attach --check</code> to diagnose attachment and hook failures.</p>
      <p :if={@view.state == :ended}>Executor session ended or detached. Recorded history remains readable.</p>
      <p :if={@view.unreadable?} role="alert">Executor transcript unreadable (source_unreadable). Status may still work; check transcript access and the attached session.</p>
      <p :if={@view.capability && @view.capability.state == :unsupported} role="status">Executor transcript unsupported: {@view.capability.reason}. Recorded history remains readable.</p>
      <p :if={not @writable} role="note">Read-only Executor view. History is readable; messages cannot be sent.</p>
    </div>
    """
  end
end
