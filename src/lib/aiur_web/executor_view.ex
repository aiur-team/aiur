defmodule AiurWeb.ExecutorView do
  @moduledoc "Executor binding states layered over the shared conversation chronology."
  use Phoenix.Component
  alias Aiur.Executor.Session
  alias AiurWeb.Conversation.Components

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

  attr(:view, :map, required: true)
  attr(:writable, :boolean, required: true)
  @spec header(map()) :: Phoenix.LiveView.Rendered.t()
  def header(assigns) do
    ~H"""
    <div id="executor-frame" class="executor-frame">
      <Components.status title="Executor" state={@view.state} age={@view.age} reason={@view.reason} last_entry={@view.last_entry} />
      <div :if={@view.state == :not_opted_in}>
        <p>Attach your Executor session to read its conversation here. Transcript capture is opt in.</p>
        <p>Run <code>aiur executor-attach --harness claude</code> or <code>aiur executor-attach --harness codex</code> in your repository.</p>
        <a href="https://aiur.team/guide/gui#executor">Executor setup and history</a>
      </div>
      <p :if={@view.state == :awaiting_hook}>Waiting for the Executor session. Run <code>aiur executor-attach --check</code> to check the hook setup.</p>
      <p :if={@view.state == :ended}>Executor session ended or detached. Recorded history remains readable.</p>
      <p :if={@view.state == :loading}>Loading Executor history…</p>
      <p :if={@view.unreadable?} role="alert">Executor transcript unreadable (source_unreadable). Status may still work; check transcript access and the attached session.</p>
      <p :if={@view.capability && @view.capability.state == :unsupported} role="status">Executor transcript unsupported: {@view.capability.reason}. Recorded history remains readable.</p>
      <p :if={not @writable} role="note">Read-only Executor view. History is readable; messages cannot be sent.</p>
    </div>
    """
  end
end
