defmodule AgentConversation.Client do
  @moduledoc """
  The conversation view state: one struct holding history, live tail, Commands and
  voice for one scoped conversation.

  Every operation is a pure function from a client to a client (plus, for sends
  and answers, the effects a host should apply). The transport and principal come
  from `AgentConversation.Host`, so the same code runs inside a LiveView and
  inside any other web host.

  Reads, sends, voice requests and Command answers all pass `AgentConversation.Scope.check/3`
  before the transport is called. A conversation outside the host's ticket or
  game scope is refused here, which is what makes `mount/3` on somebody else's
  conversation return `{:error, :out_of_scope}` instead of a transcript.
  """

  alias AgentConversation.{Commands, Host, Scope, Timeline, Voice}

  defstruct host: nil,
            conversation_id: nil,
            title: "Conversation",
            timeline: %Timeline{},
            state: :loading,
            error: nil,
            anchors: [],
            visible_kinds: [],
            commands: [],
            command_slots: %{},
            command_outcomes: %{},
            voice: %Voice{},
            voice_report: nil,
            draft: "",
            sending: false,
            delivery: [],
            notice: nil,
            at_bottom: true,
            new_below: 0,
            connected: true,
            buffered: [],
            highlight_pos: nil,
            features: %{},
            motion: :full,
            viewport: :wide

  @type effect ::
          {:push, String.t(), map()}
          | :clear_draft
          | {:command_refresh, String.t()}
          | {:scroll, :bottom | :start | pos_integer()}
  @type t :: %__MODULE__{}

  @doc """
  Builds the client for one conversation and loads its tail, anchors, Commands and
  voice capabilities.

  Returns `{:error, :out_of_scope}` when the host's scope does not register the
  conversation, and `{:error, :permission_denied}` when reading it is allowed for
  somebody else but not this principal.
  """
  @spec mount(Host.t(), String.t(), keyword()) :: {:ok, t()} | {:error, atom()}
  def mount(%Host{} = host, conversation_id, opts \\ []) when is_binary(conversation_id) do
    with :ok <- Scope.check(host.scope, conversation_id, :read) do
      client = %__MODULE__{
        host: host,
        conversation_id: conversation_id,
        title: host.title,
        features: host.features,
        visible_kinds: Keyword.get(opts, :visible_kinds, []),
        motion: Keyword.get(opts, :motion, :full),
        viewport: Keyword.get(opts, :viewport, :wide)
      }

      case read_page(client, :tail) do
        {:ok, client} -> {:ok, client |> load_anchors() |> load_commands() |> load_voice()}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Loads the next older page. A denied or failed read keeps the loaded transcript."
  @spec load_older(t()) :: {:ok, t(), [effect()]} | {:error, atom()}
  def load_older(%__MODULE__{timeline: timeline} = client) do
    case Timeline.older_cursor(timeline) do
      nil -> {:ok, %{client | notice: "No earlier history is available"}, []}
      cursor -> loaded(read_page(client, :older, before: cursor))
    end
  end

  @doc "Loads the next newer page."
  @spec load_newer(t()) :: {:ok, t(), [effect()]} | {:error, atom()}
  def load_newer(%__MODULE__{timeline: timeline} = client) do
    case Timeline.newer_cursor(timeline) do
      nil -> {:ok, %{client | notice: "Already at the latest entry"}, []}
      cursor -> loaded(read_page(client, :newer, after: cursor))
    end
  end

  @doc "Jumps to the newest entries and returns to the live tail."
  @spec jump_latest(t()) :: {:ok, t(), [effect()]}
  def jump_latest(%__MODULE__{} = client) do
    case read_page(client, :tail) do
      {:ok, client} -> {:ok, %{client | new_below: 0, at_bottom: true}, [{:scroll, :bottom}]}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Loads the oldest page."
  @spec jump_start(t()) :: {:ok, t(), [effect()]} | {:error, atom()}
  def jump_start(%__MODULE__{} = client) do
    case read_page(client, :start) do
      {:ok, client} -> {:ok, client, [{:scroll, :start}]}
      {:error, reason} -> {:error, reason}
    end
  end

  defp loaded({:ok, client}), do: {:ok, client, []}
  defp loaded({:error, reason}), do: {:error, reason}

  @doc """
  Jumps to a position, loading the window around it when it is not loaded.

  A denied read leaves the transcript where it was and states why, rather than
  silently doing nothing.
  """
  @spec reveal(t(), pos_integer()) :: {:ok, t(), [effect()]} | {:error, atom()}
  def reveal(%__MODULE__{} = client, pos) when is_integer(pos) and pos > 0 do
    with :ok <- Scope.check(client.host.scope, client.conversation_id, :read) do
      if pos in Timeline.positions(client.timeline) do
        {:ok, %{client | highlight_pos: pos}, [{:scroll, pos}]}
      else
        case read_page(client, {:around, pos}) do
          {:ok, client} -> {:ok, %{client | highlight_pos: pos}, [{:scroll, pos}]}
          {:error, reason} -> {:error, reason}
        end
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Narrows the entry kinds the transcript shows."
  @spec filter(t(), [String.t()]) :: t()
  def filter(%__MODULE__{} = client, kinds) when is_list(kinds) do
    %{client | visible_kinds: Enum.map(kinds, &to_string/1)}
  end

  @doc "Records composer text without sending it."
  @spec draft(t(), String.t()) :: t()
  def draft(%__MODULE__{} = client, text) when is_binary(text), do: %{client | draft: text}
  def draft(%__MODULE__{} = client, _text), do: client

  @doc """
  Sends composer text into the conversation.

  Sending needs the scope's `:send` action *and* the host's `:send` feature. A
  host that can read a conversation but not write to it gets
  `{:error, :permission_denied}` and keeps its draft.
  """
  @spec send_text(t(), String.t()) :: {:ok, t(), [effect()]} | {:error, atom()}
  def send_text(%__MODULE__{} = client, text) when is_binary(text) do
    cond do
      String.trim(text) == "" -> {:error, :empty_message}
      not Host.enabled?(client.host, :send) -> {:error, :permission_denied}
      Scope.check(client.host.scope, client.conversation_id, :send) != :ok -> scope_denial(client, :send)
      true -> deliver_text(client, text)
    end
  end

  def send_text(%__MODULE__{}, _text), do: {:error, :invalid_message}

  @doc "Answers a pending Command through the host's answering boundary."
  @spec answer(t(), String.t(), map()) :: {:ok, t(), [effect()]} | {:error, atom()}
  def answer(%__MODULE__{} = client, command_id, action) when is_binary(command_id) do
    cond do
      not Host.enabled?(client.host, :commands) ->
        {:error, :permission_denied}

      Scope.check(client.host.scope, client.conversation_id, :answer_command) != :ok ->
        scope_denial(client, :answer_command)

      true ->
        submit_answer(client, command_id, action)
    end
  end

  @doc """
  Applies live entries from the host's subscription.

  While the client is disconnected, entries buffer instead of merging: the
  reconnect path has to discard the ones the catch-up page already covered.
  """
  @spec receive_live(t(), [map()]) :: t()
  def receive_live(%__MODULE__{connected: false} = client, entries) when is_list(entries) do
    %{client | buffered: client.buffered ++ entries}
  end

  def receive_live(%__MODULE__{} = client, entries) when is_list(entries) do
    new_below = if client.at_bottom, do: 0, else: client.new_below + length(entries)
    %{client | timeline: Timeline.live(client.timeline, entries), new_below: new_below}
  end

  @doc "Marks the subscription as dropped, keeping loaded history."
  @spec disconnect(t()) :: t()
  def disconnect(%__MODULE__{} = client), do: %{client | connected: false, voice: Voice.disconnect(client.voice)}

  @doc """
  Re-reads the tail after a reconnect and reconciles the buffered live entries.

  The head the catch-up page reports wins: buffered entries at or below it are
  discarded so nothing is rendered twice.
  """
  @spec reconnect(t()) :: {:ok, t(), [effect()]} | {:error, atom()}
  def reconnect(%__MODULE__{} = client) do
    case read_page(%{client | connected: true, voice: Voice.reconnect(client.voice)}, :tail) do
      {:ok, client} ->
        {timeline, _discarded} = Timeline.reconcile(client.timeline, %{}, client.buffered)
        {:ok, %{client | timeline: timeline, buffered: [], connected: true, notice: nil}, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Starts dictation or two-way voice through the host's voice client."
  @spec start_voice(t(), Voice.mode()) :: {:ok, t()} | {:error, atom()}
  def start_voice(%__MODULE__{} = client, mode) do
    case Voice.open(client.host, client.conversation_id, mode, client.voice_report) do
      {:ok, voice} -> {:ok, %{client | voice: voice}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns to text-only composition."
  @spec stop_voice(t()) :: t()
  def stop_voice(%__MODULE__{} = client), do: %{client | voice: Voice.stop(client.voice)}

  @doc "Whether this host may answer a pending Command in this conversation."
  @spec can_answer?(t()) :: boolean()
  def can_answer?(%__MODULE__{} = client) do
    Host.enabled?(client.host, :commands) and
      Scope.check(client.host.scope, client.conversation_id, :answer_command) == :ok
  end

  @doc "The status the reader sees for the transcript itself."
  @spec state(t()) :: atom()
  def state(%__MODULE__{state: :loading}), do: :loading
  def state(%__MODULE__{state: :error, error: :not_found}), do: :not_found
  def state(%__MODULE__{state: :error, error: error}) when error in [:out_of_scope, :permission_denied], do: :denied
  def state(%__MODULE__{state: :error}), do: :unavailable
  def state(%__MODULE__{timeline: timeline}), do: if(Timeline.empty?(timeline), do: :empty, else: :ready)

  @doc "The entries the transcript renders, filtered to the visible kinds."
  @spec entries(t()) :: [map()]
  def entries(%__MODULE__{visible_kinds: []} = client), do: Timeline.visible(client.timeline)

  def entries(%__MODULE__{} = client) do
    Enum.filter(Timeline.visible(client.timeline), &(&1.kind in client.visible_kinds))
  end

  @doc "The minimap rows for the loaded transcript."
  @spec minimap(t(), keyword()) :: [map()]
  def minimap(%__MODULE__{} = client, opts \\ []) do
    Timeline.minimap(client.timeline, Keyword.put_new(opts, :anchors, client.anchors))
  end

  @doc "Commands pinned above the transcript because their position is unknown."
  @spec pinned_commands(t()) :: [Commands.row()]
  def pinned_commands(%__MODULE__{} = client), do: Commands.at(client.commands, client.command_slots, :pinned_top)

  @doc "Commands that render after the given transcript position."
  @spec inline_commands(t(), pos_integer()) :: [Commands.row()]
  def inline_commands(%__MODULE__{} = client, pos),
    do: Commands.at(client.commands, client.command_slots, {:at_pos, pos})

  defp deliver_text(client, text) do
    case client.host.transport.send_text(client.host, client.conversation_id, text) do
      {:ok, receipt} ->
        {:ok, %{client | draft: "", delivery: client.delivery ++ [receipt], sending: false, notice: nil},
         [:clear_draft, {:push, "conversation-bottom", %{}}]}

      {:error, reason} ->
        {:error, normalize(reason)}
    end
  end

  defp submit_answer(client, command_id, action) do
    case client.host.transport.answer_command(client.host, client.conversation_id, command_id, action) do
      {:ok, receipt} ->
        {:ok, %{client | command_outcomes: Commands.record(client.command_outcomes, command_id, {:ok, receipt})}, []}

      {:error, {:conflict, summary}} ->
        outcome = Commands.record(client.command_outcomes, command_id, {:error, {:conflict, summary}})
        {:ok, %{client | command_outcomes: outcome}, []}

      {:error, reason} ->
        {:error, normalize(reason)}
    end
  end

  defp read_page(client, direction, extra \\ []) do
    case Scope.check(client.host.scope, client.conversation_id, :read) do
      :ok -> fetch_page(client, direction, extra)
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_page(client, direction, extra) do
    opts = page_opts(client, direction) ++ extra

    case client.host.transport.read_entries(client.host, client.conversation_id, opts) do
      {:ok, page} ->
        {:ok, %{client | timeline: Timeline.merge(client.timeline, page, direction), state: :ready, error: nil}}

      {:error, reason} ->
        {:error, normalize(reason)}
    end
  end

  defp page_opts(_client, :tail), do: []
  defp page_opts(_client, :start), do: [from: :start]
  defp page_opts(_client, {:around, pos}), do: [around: pos, limit: 50]
  defp page_opts(_client, _direction), do: []

  defp load_anchors(client) do
    with true <- Host.enabled?(client.host, :minimap),
         true <- exported?(client.host.transport, :read_anchors, 3),
         {:ok, anchors} <- client.host.transport.read_anchors(client.host, client.conversation_id, []) do
      %{client | anchors: List.wrap(anchors)}
    else
      _other -> client
    end
  end

  defp load_commands(client) do
    with true <- Host.enabled?(client.host, :commands),
         true <- exported?(client.host.transport, :read_commands, 2),
         {:ok, rows} <- client.host.transport.read_commands(client.host, client.conversation_id) do
      commands = Commands.normalize_all(rows)
      %{client | commands: commands, command_slots: Commands.slots(commands, Timeline.positions(client.timeline))}
    else
      _other -> client
    end
  end

  defp load_voice(client) do
    report =
      if Host.enabled?(client.host, :voice) and exported?(client.host.transport, :voice_capabilities, 2) do
        client.host.transport.voice_capabilities(client.host, client.conversation_id)
      else
        {:error, :unavailable}
      end

    %{client | voice: Voice.from_report(report), voice_report: report}
  end

  defp exported?(module, function, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end

  defp scope_denial(client, action) do
    case Scope.check(client.host.scope, client.conversation_id, action) do
      {:error, :out_of_scope} -> {:error, :out_of_scope}
      {:error, _reason} -> {:error, :permission_denied}
      :ok -> {:error, :permission_denied}
    end
  end

  defp normalize(:not_found), do: :not_found
  defp normalize(:out_of_scope), do: :out_of_scope
  defp normalize(:permission_denied), do: :permission_denied
  defp normalize(_reason), do: :unavailable
end
