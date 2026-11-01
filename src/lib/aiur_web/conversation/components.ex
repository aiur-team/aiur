defmodule AiurWeb.Conversation.Components do
  @moduledoc "Conversation chronology entries, session dividers and state presentation."
  use Phoenix.Component
  alias AiurWeb.Conversation.{EntryContent, Presenter}

  attr(:entry, :map, required: true)
  attr(:sessions, :list, default: [])
  attr(:can_reveal, :boolean, default: false)
  @spec entry(map()) :: Phoenix.LiveView.Rendered.t()
  def entry(assigns) do
    ~H"""
    <div data-pos={@entry.pos} class="conversation-entry">
      <.session_divider :for={session <- @sessions} :if={session.first_pos == @entry.pos} session={session} />
      <article aria-label={"Entry #{@entry.pos}"}>
        <small>#{@entry.pos} · {@entry.role} · {@entry.kind}</small>
        <span :if={Map.get(@entry, :redacted, false)} class="conversation-masked">masked</span>
        <button :if={Map.get(@entry, :redacted, false) && @can_reveal} phx-click="reveal_entry" phx-value-pos={@entry.pos}>Show raw</button>
        <EntryContent.content entry={@entry} />
        <.truncation_marker :if={@entry.body_truncated} text={@entry.body} />
        <.truncation_marker :if={@entry.output_truncated} text={@entry.output} />
      </article>
    </div>
    """
  end

  attr(:entry, :map, required: true)
  @spec gap(map()) :: Phoenix.LiveView.Rendered.t()
  def gap(assigns), do: EntryContent.gap(assigns)

  attr(:session, :map, required: true)
  @spec session_divider(map()) :: Phoenix.LiveView.Rendered.t()
  def session_divider(assigns) do
    ~H"""
    <p class="conversation-divider">
      Session {@session.session_seq} · {EntryContent.session_reason(@session.start_reason)}
      · <time datetime={@session.started_at}>{@session.started_at || "Time unknown"}</time>
    </p>
    """
  end

  attr(:text, :any, default: nil)
  @spec truncation_marker(map()) :: Phoenix.LiveView.Rendered.t()
  def truncation_marker(assigns) do
    assigns = assign(assigns, :bytes, EntryContent.omitted_bytes(assigns.text))

    ~H"""
    <p class="conversation-truncation" role="note">Middle of this output not stored ({@bytes} bytes)</p>
    """
  end

  attr(:title, :string, default: "Conversation")
  attr(:state, :atom, required: true)
  attr(:age, :map, required: true)
  attr(:last_entry, :any, default: nil)
  attr(:reason, :any, default: nil)
  @spec status(map()) :: Phoenix.LiveView.Rendered.t()
  def status(assigns) do
    ~H"""
    <header aria-live="polite" data-state={@state}>
      <h1>{@title}</h1>
      <p :if={@state == :not_found}>No messages yet</p>
      <p>{Presenter.label(@state)} <span :if={@reason}>· {@reason}</span></p>
      <p :if={@state not in [:loading, :not_found]} data-freshness={@age.freshness}>
        Observed <time :if={@age.observed_at} datetime={DateTime.to_iso8601(@age.observed_at)}>{DateTime.to_iso8601(@age.observed_at)}</time>
        · {@age.text} · {@age.freshness}
      </p>
      <p :if={@last_entry}>Last entry: {Presenter.age(@last_entry.observed_at, DateTime.utc_now()).text}</p>
      <button :if={@state in [:unavailable, :degraded]} phx-click="retry">Retry</button>
    </header>
    """
  end
end
