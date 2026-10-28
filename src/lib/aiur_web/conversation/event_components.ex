defmodule AiurWeb.Conversation.EventComponents do
  @moduledoc false
  use Phoenix.Component
  alias Aiur.Conversation.JumpPoints

  attr(:streams, :map, required: true)
  attr(:id, :string, required: true)
  attr(:visible_kinds, :list, required: true)
  attr(:event_start, :integer, required: true)
  attr(:event_has_newer, :boolean, required: true)
  attr(:error, :any, default: nil)

  @spec event_nav(map()) :: Phoenix.LiveView.Rendered.t()
  def event_nav(assigns) do
    ~H"""
    <aside id="conversation-events" class="conversation-events" aria-label="Conversation events">
      <h2>Events</h2>
      <.filter_chips visible_kinds={@visible_kinds} />
      <p :if={@error} role="status">{@error}</p>
      <button :if={@event_start > 0} id="events-older" phx-click="older_events">Older events</button>
      <button :if={@event_has_newer} id="events-latest" phx-click="latest_events">Latest events</button>
      <ul id="event-list" phx-update="stream">
        <li :for={{dom_id, anchor} <- @streams.events} id={dom_id} data-kind={anchor["kind"]} data-precision={anchor["precision"]}>
          <.event_item anchor={anchor} conversation_id={@id} />
        </li>
      </ul>
      <p :if={is_nil(@error)} class="events-empty">No events match these filters</p>
    </aside>
    """
  end

  attr(:visible_kinds, :list, required: true)

  @spec filter_chips(map()) :: Phoenix.LiveView.Rendered.t()
  def filter_chips(assigns) do
    ~H"""
    <div class="event-filters" aria-label="Event kinds">
      <button :for={kind <- JumpPoints.kinds()} type="button" phx-click="toggle_event_kind" phx-value-kind={kind}
        aria-pressed={to_string(to_string(kind) in @visible_kinds)} data-filter-kind={kind}>
        {JumpPoints.entry(kind).label}
      </button>
    </div>
    """
  end

  attr(:anchor, :map, required: true)
  attr(:conversation_id, :string, required: true)

  @spec event_item(map()) :: Phoenix.LiveView.Rendered.t()
  def event_item(assigns) do
    assigns = assign(assigns, :decision_id, get_in(assigns.anchor, ["subject_ref", "decision_id"]))

    ~H"""
    <time>{@anchor["event"]["observed_at"]}</time>
    <.link :if={is_integer(@anchor["pos"])} patch={"/conversations/#{@conversation_id}?pos=#{@anchor["pos"]}"}>
      {@anchor["label"] || JumpPoints.label(@anchor["kind"], %{})}
    </.link>
    <span :if={is_nil(@anchor["pos"])}>{@anchor["label"] || JumpPoints.label(@anchor["kind"], %{})} — Not linked to a position</span>
    <small :if={@anchor["precision"] == "observed"}>approximate position</small>
    <.link :if={@anchor["kind"] == "command_requested" and is_binary(@decision_id)} href={"/commands/#{URI.encode_www_form(@decision_id)}"} class="command-chip">Open Command</.link>
    <span :if={@anchor["kind"] == "command_resolved"} class="command-chip">answered</span>
    """
  end

  attr(:anchors, :list, required: true)
  attr(:pos, :integer, required: true)
  attr(:highlight_pos, :any, default: nil)

  @spec entry_marker(map()) :: Phoenix.LiveView.Rendered.t()
  def entry_marker(assigns) do
    ~H"""
    <div :for={anchor <- AiurWeb.Conversation.Navigation.markers(@anchors, @pos)}
      id={"marker-#{anchor["event"]["event_id"]}-#{anchor["kind"]}"}
      class={["conversation-event-marker", @highlight_pos == @pos && "conversation-highlight"]}
      data-jump-target={to_string(@highlight_pos == @pos)}>
      {anchor["label"] || JumpPoints.label(anchor["kind"], %{})}
      <small :if={anchor["precision"] == "observed"}>approximate position</small>
    </div>
    """
  end
end
