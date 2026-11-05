defmodule AgentConversation.Components do
  @moduledoc """
  The embeddable agent conversation, as Phoenix function components.

  A host mounts `conversation/1` with a `AgentConversation.Client`; the leaf
  components (`entry/1`, `minimap/1`, `media/1`, `command_card/1`, `composer/1`,
  `status/1`) are usable on their own when a host renders inside its own
  LiveView or controller.

  Everything host-specific arrives as an assign, never as an import:

    * `entry_content` - a function component that renders one entry's body, so a
      host keeps its own markdown, sanitizer and syntax highlighting,
    * `command_actions` - a function component that renders the answer controls,
      so Command answering stays in the host's canonical boundary,
    * `reveal_event` / `send_event` / `draft_event` / `tick_attrs` - LiveView event
      names a host may map onto its own handlers.

  The class names (`conversation-entry`, `conversation-divider`,
  `conversation-scroll`, …) and the `data-pos` attributes are the styling
  contract: `priv/static/agent_conversation.css` styles them, and a host may
  replace it wholesale.
  """

  use Phoenix.Component

  alias AgentConversation.{Commands, Labels, Media}

  @media_kinds Media.kinds()
  @motion_modes [:full, :reduced]
  @viewports [:wide, :narrow]

  @doc "Every artifact kind the media component renders inline."
  @spec media_kinds() :: [atom()]
  def media_kinds, do: @media_kinds

  @doc "The motion modes a host may request."
  @spec motion_modes() :: [atom()]
  def motion_modes, do: @motion_modes

  @doc "The viewports the layout understands."
  @spec viewports() :: [atom()]
  def viewports, do: @viewports

  attr(:state, :atom, required: true)
  attr(:title, :string, default: "Conversation")
  attr(:label, :string, default: nil)
  attr(:reason, :any, default: nil)
  attr(:freshness, :map, default: nil)
  attr(:last_entry_text, :string, default: nil)
  attr(:retry_event, :string, default: nil)
  attr(:retry_attrs, :map, default: %{})

  @doc """
  The transcript header: state, freshness and the retry control.

  `retry_event` names a LiveView event; hosts without one pass `retry_attrs`
  instead, which is rendered as plain attributes on the same button.
  """
  @spec status(map()) :: Phoenix.LiveView.Rendered.t()
  def status(assigns) do
    assigns = assign(assigns, :retry?, assigns.state in [:unavailable, :degraded, :denied])

    ~H"""
    <header aria-live="polite" data-state={@state} class="conversation-status">
      <h1>{@title}</h1>
      <p :if={@state == :not_found}>No messages yet</p>
      <p>{@label || Labels.state(@state)} <span :if={@reason}>· {@reason}</span></p>
      <p :if={@freshness} data-freshness={@freshness.freshness}>
        Observed <time :if={@freshness.observed_at} datetime={DateTime.to_iso8601(@freshness.observed_at)}>
          {DateTime.to_iso8601(@freshness.observed_at)}
        </time>
        · {@freshness.text} · {@freshness.freshness}
      </p>
      <p :if={@last_entry_text}>{@last_entry_text}</p>
      <button :if={@retry?} type="button" phx-click={@retry_event} {@retry_attrs}>Retry</button>
    </header>
    """
  end

  attr(:session, :map, required: true)

  @doc "One durable session boundary."
  @spec session_divider(map()) :: Phoenix.LiveView.Rendered.t()
  def session_divider(assigns) do
    ~H"""
    <p class="conversation-divider">
      Session {@session.session_seq} · {session_reason(@session.start_reason)}
      · <time datetime={@session.started_at}>{@session.started_at || "Time unknown"}</time>
    </p>
    """
  end

  attr(:text, :any, default: nil)

  @doc "States that the middle of a stored body is missing."
  @spec truncation_marker(map()) :: Phoenix.LiveView.Rendered.t()
  def truncation_marker(assigns) do
    assigns = assign(assigns, :bytes, omitted_bytes(assigns.text))

    ~H"""
    <p class="conversation-truncation" role="note">Middle of this output not stored ({@bytes} bytes)</p>
    """
  end

  attr(:component, :any, required: true)
  attr(:assigns, :map, default: %{})

  @doc """
  Renders a function component the host supplied.

  Pass either `{Module, :function}` or a captured `&Module.function/1`. The
  component receives exactly the assigns the package would otherwise have to
  guess, so a host keeps its own markdown, sanitizer and answer controls.
  """
  @spec host_component(map()) :: Phoenix.LiveView.Rendered.t()
  def host_component(assigns) do
    render_host(assigns.component, assigns.assigns)
  end

  # The host component may call `assign/2` itself, which needs the change-tracking
  # key a component gets when HEEx invokes it. A hand-built assigns map is not
  # enough, so the key is supplied here once instead of in every host.
  defp render_host({module, function}, assigns) when is_atom(module) and is_atom(function) do
    apply(module, function, [assigns(assigns)])
  end

  defp render_host(function, assigns) when is_function(function, 1), do: function.(assigns(assigns))

  defp visible_media(entry) do
    case Map.get(entry, :media) do
      media when is_list(media) and media != [] -> media
      _none -> AgentConversation.Entry.media(entry)
    end
  end

  defp assigns(assigns), do: Map.put_new(assigns, :__changed__, %{})

  attr(:entry, :map, required: true)
  attr(:sessions, :list, default: [])
  attr(:can_reveal, :boolean, default: false)
  attr(:renderer, :any, default: nil)
  attr(:reveal_event, :string, default: nil)
  attr(:motion, :atom, default: :full)
  attr(:focused, :boolean, default: false)

  @doc """
  One transcript entry: position label, mask state, body, attachments and
  truncation notices.

  The body is rendered by `renderer` when the host supplies one and as plain
  escaped text otherwise, so no markup from a transport reaches the page.
  """
  @spec entry(map()) :: Phoenix.LiveView.Rendered.t()
  def entry(assigns) do
    assigns =
      assigns
      |> assign(:visible_media, visible_media(assigns.entry))
      |> assign(:masked, Map.get(assigns.entry, :redacted, false) == true)

    ~H"""
    <div data-pos={@entry.pos} data-kind={@entry.kind} class="conversation-entry" tabindex="-1" data-entry-focus={@focused}>
      <.session_divider :for={session <- @sessions} :if={session.first_pos == @entry.pos} session={session} />
      <article aria-label={"Entry #{@entry.pos}"}>
        <small>#{@entry.pos} · {@entry.role} · {@entry.kind}</small>
        <span :if={@masked} class="conversation-masked">masked</span>
        <button :if={@masked && @can_reveal} type="button" phx-click={@reveal_event} phx-value-pos={@entry.pos}>Show raw</button>
        <.host_component :if={@renderer} component={@renderer}
          assigns={%{entry: @entry, can_reveal: @can_reveal, reveal_event: @reveal_event}} />
        <.plain_body :if={is_nil(@renderer)} entry={@entry} />
        <.truncation_marker :if={@entry.body_truncated} text={@entry.body} />
        <.truncation_marker :if={@entry.output_truncated} text={@entry.output} />
        <.media :if={@visible_media != []} items={@visible_media} motion={@motion} />
      </article>
    </div>
    """
  end

  attr(:entry, :map, required: true)

  @doc "The default body renderer: escaped text, never interpreted markup."
  @spec plain_body(map()) :: Phoenix.LiveView.Rendered.t()
  def plain_body(assigns) do
    ~H"""
    <div class="conversation-body" data-kind={@entry.kind}>{@entry.body}</div>
    <pre :if={@entry.output not in [nil, ""]} class="conversation-output">{@entry.output}</pre>
    """
  end

  attr(:items, :list, required: true)
  attr(:motion, :atom, default: :full)

  @doc """
  Inline attachments.

  An animated image becomes a still link when the reader asked for reduced
  motion, and an artifact the component cannot render becomes a labelled link
  instead of disappearing.
  """
  @spec media(map()) :: Phoenix.LiveView.Rendered.t()
  def media(assigns) do
    assigns = assign(assigns, :reduced?, assigns.motion == :reduced)

    ~H"""
    <div class="conversation-media-group" data-media-count={length(@items)}>
      <figure :for={item <- @items} class="conversation-media" data-media-kind={item.kind} data-media-fallback={item.fallback}>
        <img :if={item.kind == :image && item.url} src={item.url} alt={item.alt} loading="lazy" decoding="async" />
        <img :if={item.kind == :animated_image && item.url && not @reduced?} src={item.url} alt={item.alt} loading="lazy" decoding="async" data-animated="true" />
        <a :if={item.kind == :animated_image && item.url && @reduced?} href={item.url} class="conversation-media-still" data-motion="reduced">
          {item.alt} (animated image not played)
        </a>
        <video :if={item.kind == :video && item.url} src={item.url} poster={item.poster} controls preload="metadata"></video>
        <audio :if={item.kind == :audio && item.url} src={item.url} controls preload="metadata"></audio>
        <a :if={item.fallback && item.url} href={item.url} class="conversation-media-fallback" rel="noreferrer">
          {item.alt} · {fallback_reason(item.reason)}
        </a>
        <p :if={item.fallback && is_nil(item.url)} class="conversation-media-fallback" role="note">
          {item.alt} · {fallback_reason(item.reason)}
        </p>
          </figure>
    </div>
    """
  end

  attr(:rows, :list, required: true)
  attr(:active_pos, :integer, default: nil)
  attr(:tick_attrs, :map, default: %{})
  attr(:label, :string, default: "Transcript positions")
  attr(:motion, :atom, default: :full)

  @doc """
  The right-edge minimap: one tick per activity row or host anchor.

  Ticks carry `data-tick-pos` rather than `data-pos` so a host that also counts
  transcript rows by position keeps those counts honest.
  """
  @spec minimap(map()) :: Phoenix.LiveView.Rendered.t()
  def minimap(assigns) do
    ~H"""
    <nav class="conversation-minimap" aria-label={@label} data-motion={@motion}>
      <ol>
        <li :for={row <- @rows}>
          <button type="button" class="conversation-minimap-tick" data-tick-pos={row.pos} data-tick-kind={row.kind}
            aria-current={if row.pos == @active_pos, do: "location", else: "false"}
            aria-label={tick_label(row)} title={tick_label(row)} {@tick_attrs} phx-value-pos={if @tick_attrs == %{}, do: nil, else: row.pos}>
            <span class="conversation-minimap-dot" aria-hidden="true"></span>
          </button>
        </li>
      </ol>
    </nav>
    """
  end

  attr(:row, :map, required: true)
  attr(:slot, :any, required: true)
  attr(:href, :string, default: nil)
  attr(:notice, :string, default: nil)
  attr(:answerable, :boolean, default: false)
  attr(:actions, :any, default: nil)

  @doc """
  A pending Command rendered inline with the transcript.

  Row data is host data; the answer controls come from the host's `actions`
  slot, which receives `%{row: row, answerable: boolean}`.
  """
  @spec command_card(map()) :: Phoenix.LiveView.Rendered.t()
  def command_card(assigns) do
    assigns = assign(assigns, :card_id, "conversation-command-" <> to_string(assigns.row.id))

    ~H"""
    <article id={@card_id} class="conversation-command-card" data-command-status={@row.status} aria-label="Inline Command">
      <h3>{@row.question}</h3>
      <p :if={@slot == :pinned_top}>Position unknown</p>
      <p :if={@notice} role="status" class="conversation-command-notice">{@notice}</p>
      <a :if={@href} href={@href}>Open Command</a>
      <.host_component :if={@actions} component={@actions} assigns={%{row: @row, answerable: @answerable, slot: @slot}} />
    </article>
    """
  end

  attr(:draft, :string, default: "")
  attr(:writable, :boolean, default: false)
  attr(:sending, :boolean, default: false)
  attr(:voice, :map, required: true)
  attr(:voice_available, :boolean, default: false)
  attr(:notice, :string, default: nil)
  attr(:send_event, :string, default: nil)
  attr(:draft_event, :string, default: nil)
  attr(:start_voice_event, :string, default: nil)
  attr(:stop_voice_event, :string, default: nil)

  @doc """
  Text composition plus the dictation and two-way voice controls.

  The composer only enables what the host mounted: a host without the `:send`
  feature renders a stated read-only note, and a host whose voice client reports
  unavailable or denied renders that reason instead of a dead button.
  """
  @spec composer(map()) :: Phoenix.LiveView.Rendered.t()
  def composer(assigns) do
    assigns =
      assigns
      |> assign(:voice_status, AgentConversation.Voice.status(assigns.voice))
      |> assign(:voice_modes, AgentConversation.Voice.offered(assigns.voice))

    ~H"""
    <section id="conversation-compose" aria-label="Send a message" data-voice-status={@voice_status}>
      <p :if={!@writable} class="conversation-read-only">Read-only: messages cannot be sent from this embed.</p>
      <p :if={@voice_available and @voice_status != :active} role="status" class="conversation-voice-state">
        {AgentConversation.Voice.label(@voice_status)}
      </p>
      <p :if={@notice} role="status" class="conversation-compose-notice">{@notice}</p>
      <%= if @writable do %>
        <form id="conversation-composer" phx-submit={@send_event || "send"} phx-change={@draft_event || "draft"}>
          <label for="conversation-text">Message to agent</label>
          <textarea id="conversation-text" name="text" rows="3" required disabled={@sending} data-voice-input={if @voice_modes != [], do: ""}>{@draft}</textarea>
          <button type="submit" disabled={@sending}>{if @sending, do: "Sending…", else: "Send"}</button>
        </form>
        <div :if={@voice_modes != []} class="conversation-voice-controls" role="group" aria-label="Voice">
          <button :if={:dictation in @voice_modes and @voice_status != :active} type="button" phx-click={@start_voice_event} phx-value-mode="dictation">
            Dictate
          </button>
          <button :if={:two_way in @voice_modes and @voice_status != :active} type="button" phx-click={@start_voice_event} phx-value-mode="two_way">
            Talk to agent
          </button>
          <button :if={@voice_status == :active} type="button" phx-click={@stop_voice_event}>Stop voice</button>
        </div>
      <% end %>
    </section>
    """
  end

  attr(:client, :map, required: true)
  attr(:entry_content, :any, default: nil)
  attr(:command_actions, :any, default: nil)
  attr(:commands_href, :any, default: nil)
  attr(:retry_attrs, :map, default: %{})
  attr(:transcript_id, :string, default: "conversation-scroll")

  @doc """
  The complete conversation: header, paging, minimap, transcript, Commands and
  composer, driven by a `AgentConversation.Client`.

  This is the mount point for an embedding host that has no LiveView of its own.
  A host inside LiveView usually keeps its own stream container and uses the leaf
  components instead.
  """
  @spec conversation(map()) :: Phoenix.LiveView.Rendered.t()
  def conversation(assigns) do
    assigns =
      assigns
      |> assign(:state, AgentConversation.Client.state(assigns.client))
      |> assign(:entries, AgentConversation.Client.entries(assigns.client))
      |> assign(:pinned, AgentConversation.Client.pinned_commands(assigns.client))
      |> assign(:minimap_rows, AgentConversation.Client.minimap(assigns.client))
      |> assign(:highlight, assigns.client.highlight_pos)
      |> assign(:freshness, Labels.age(assigns.client.timeline.observed_at))
      |> assign(:motion, assigns.client.motion)
      |> assign(:viewport, assigns.client.viewport)

    ~H"""
    <section id="conversation" class="conversation-page" data-motion={@motion} data-viewport={@viewport}
      data-conversation-id={@client.conversation_id}>
      <.status state={@state} title={@client.title} reason={@client.error} freshness={@freshness}
        retry_attrs={@retry_attrs} />
      <div :if={@state == :loading} role="status" aria-busy="true" class="conversation-skeleton">Loading conversation…</div>
      <p :if={@client.notice} id="conversation-position-notice" role="status">{@client.notice}</p>
      <nav aria-label="Conversation paging">
        <button type="button" phx-click="jump_start">Jump to start</button>
        <button type="button" phx-click="load_older">Load older</button>
        <button type="button" phx-click="load_newer">Load newer</button>
        <button type="button" phx-click="jump_latest">Latest entries</button>
      </nav>
      <div class="conversation-command-pinned">
        <.command_card :for={row <- @pinned} row={row} slot={:pinned_top} href={href(row, @commands_href)}
          notice={Commands.notice(@client.command_outcomes, row.id)}
          answerable={AgentConversation.Client.can_answer?(@client)} actions={@command_actions} />
      </div>
      <div class="conversation-layout">
        <.minimap rows={@minimap_rows} active_pos={@highlight} motion={@motion} />
        <div id={@transcript_id} class="conversation-scroll" role="region" aria-label="Transcript" tabindex="0"
          data-keyboard-nav="entries" data-highlight={@highlight} data-motion={@motion}>
          <div id="conversation-entries">
            <div :for={entry <- @entries} id={"entry-#{entry.pos}"}>
              <.entry entry={entry} can_reveal={@client.features[:reveal] == true} renderer={@entry_content} motion={@motion} />
              <.command_card :for={row <- AgentConversation.Client.inline_commands(@client, entry.pos)} row={row}
                slot={{:at_pos, entry.pos}} href={href(row, @commands_href)}
                notice={Commands.notice(@client.command_outcomes, row.id)}
                answerable={AgentConversation.Client.can_answer?(@client)} actions={@command_actions} />
            </div>
          </div>
        </div>
      </div>
      <button :if={@client.new_below > 0} id="conversation-new" type="button" phx-click="jump_latest" aria-live="polite">
        {@client.new_below} new entries below
      </button>
      <.composer draft={@client.draft} writable={@client.features[:send] == true} sending={@client.sending}
        voice={@client.voice} voice_available={@client.features[:voice] != false} notice={@client.notice} />
    </section>
    """
  end

  @doc """
  Renders the conversation to an HTML string.

  Use this from a host that is not a LiveView — a Plug, a controller, a mailer or
  a job. Phoenix function components expect change-tracking assigns internally;
  this adds them so the caller needs nothing but the client.
  """
  @spec render(map()) :: String.t()
  def render(assigns) when is_map(assigns) do
    assigns
    |> Map.put(:__changed__, %{})
    |> Map.put_new(:entry_content, nil)
    |> Map.put_new(:command_actions, nil)
    |> conversation()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  @doc "Whether the entry carries an attachment the media component renders."
  @spec media?(map()) :: boolean()
  def media?(entry), do: Map.get(entry, :media, []) != []

  defp href(_row, nil), do: nil
  defp href(row, fun) when is_function(fun, 1), do: fun.(row)
  defp href(_row, _href), do: nil

  defp tick_label(row) do
    at = if row.at, do: " · " <> to_string(row.at), else: ""
    "#{row.label} · position #{row.pos}#{at}"
  end

  defp fallback_reason(:missing_source), do: "no source available"
  defp fallback_reason(:unsupported_kind), do: "unsupported attachment"
  defp fallback_reason(_reason), do: "attachment unavailable"

  defp omitted_bytes(text) do
    case Regex.run(~r/…\[(\d+) bytes omitted\]…/, text || "") do
      [_all, bytes] -> bytes
      _none -> "unknown number of"
    end
  end

  defp session_reason("resume"), do: "Resumed after restart"
  defp session_reason("clear"), do: "New session after /clear"
  defp session_reason("spawn"), do: "Worker started"
  defp session_reason("start"), do: "Session started"
  defp session_reason("import"), do: "Imported history"
  defp session_reason(reason), do: reason || "Start reason unknown"
end
