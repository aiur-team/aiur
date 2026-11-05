defmodule AiurWeb.Conversation.Components do
  @moduledoc """
  The dashboard's conversation presentation, rendered by the extracted
  `AgentConversation.Components` package.

  Aiur keeps its own entry bodies (`AiurWeb.Conversation.EntryContent`), state
  labels (`AiurWeb.Conversation.Presenter`) and reveal event, and passes them into
  the package as a renderer and labels. That way the transcript row, session
  divider, state header and media markup have exactly one implementation — the
  one an embedding host also gets — while Aiur's markdown, masking and freshness
  wording stay where they already live.
  """
  use Phoenix.Component

  alias AgentConversation.Components, as: Embed
  alias AiurWeb.Conversation.{EntryContent, Presenter}

  attr(:entry, :map, required: true)
  attr(:sessions, :list, default: [])
  attr(:can_reveal, :boolean, default: false)
  @spec entry(map()) :: Phoenix.LiveView.Rendered.t()
  def entry(assigns) do
    ~H"""
    <Embed.entry entry={@entry} sessions={@sessions} can_reveal={@can_reveal} renderer={{EntryContent, :content}} reveal_event="reveal_entry" />
    """
  end

  attr(:entry, :map, required: true)
  @spec gap(map()) :: Phoenix.LiveView.Rendered.t()
  def gap(assigns), do: EntryContent.gap(assigns)

  attr(:session, :map, required: true)
  @spec session_divider(map()) :: Phoenix.LiveView.Rendered.t()
  def session_divider(assigns) do
    ~H"""
    <Embed.session_divider session={@session} />
    """
  end

  attr(:text, :any, default: nil)
  @spec truncation_marker(map()) :: Phoenix.LiveView.Rendered.t()
  def truncation_marker(assigns) do
    ~H"""
    <Embed.truncation_marker text={@text} />
    """
  end

  attr(:title, :string, default: "Conversation")
  attr(:state_label, :string, default: nil)
  attr(:show_freshness, :boolean, default: true)
  attr(:state, :atom, required: true)
  attr(:age, :map, required: true)
  attr(:last_entry, :any, default: nil)
  attr(:reason, :any, default: nil)
  @spec status(map()) :: Phoenix.LiveView.Rendered.t()
  def status(assigns) do
    assigns =
      assigns
      |> assign(:label, assigns.state_label || Presenter.label(assigns.state))
      |> assign(:freshness, if(assigns.show_freshness and assigns.state not in [:loading, :not_found], do: assigns.age))
      |> assign(:last_entry_text, last_entry_text(assigns.last_entry))

    ~H"""
    <Embed.status state={@state} title={@title} label={@label} reason={@reason} freshness={@freshness}
      last_entry_text={@last_entry_text} retry_event="retry" />
    """
  end

  attr(:rows, :list, required: true)
  attr(:active_pos, :integer, default: nil)
  attr(:tick_attrs, :map, default: %{})
  @spec minimap(map()) :: Phoenix.LiveView.Rendered.t()
  def minimap(assigns) do
    ~H"""
    <Embed.minimap rows={@rows} active_pos={@active_pos} tick_attrs={@tick_attrs} />
    """
  end

  defp last_entry_text(nil), do: nil
  defp last_entry_text(entry), do: "Last entry: " <> Presenter.age(entry.observed_at, DateTime.utc_now()).text
end
