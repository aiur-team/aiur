defmodule AiurWeb.Conversation.Components do
  @moduledoc "Conversation chronology shell; rich entry rendering is added separately."
  use Phoenix.Component
  alias AiurWeb.Conversation.Presenter

  attr(:entry, :map, required: true)
  attr(:sessions, :list, required: true)
  @spec entry(map()) :: Phoenix.LiveView.Rendered.t()
  def entry(assigns) do
    ~H"""
    <div data-pos={@entry.pos}>
      <p :for={session <- @sessions} :if={session.first_pos == @entry.pos} class="conversation-divider">
        Session {session.session_seq} · {session.start_reason}
      </p>
      <article aria-label={"Entry #{@entry.pos}"}>
        <small>#{@entry.pos} · {@entry.role} · {@entry.kind}</small>
        <p class="conversation-body">{@entry.body || @entry.output || ""}</p>
      </article>
    </div>
    """
  end

  attr(:state, :atom, required: true)
  attr(:age, :map, required: true)
  attr(:last_entry, :any, default: nil)
  attr(:reason, :any, default: nil)
  @spec status(map()) :: Phoenix.LiveView.Rendered.t()
  def status(assigns) do
    ~H"""
    <header aria-live="polite" data-state={@state}>
      <h1>Conversation</h1>
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
