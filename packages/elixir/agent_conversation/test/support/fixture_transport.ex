defmodule AgentConversation.FixtureTransport do
  @moduledoc """
  An in-memory `AgentConversation.Host.Transport` used by the package tests.

  Each conversation keeps its own entries, Commands, anchors and voice report, so
  tests run concurrently without sharing state. Sends and answers are recorded so
  a test can assert the transport was reached exactly once.
  """

  @behaviour AgentConversation.Host.Transport

  @server __MODULE__.Server
  @limit 50

  @doc "Starts the shared store."
  @spec start() :: :ok
  def start do
    case Agent.start(fn -> %{} end, name: @server) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  @doc """
  Seeds a conversation.

  Options: `:commands` (Command rows), `:anchors` (minimap anchors),
  `:voice` (the voice capability report) and `:writable` (false makes sends and
  answers fail with `:permission_denied`, as a read-only host would).
  """
  @spec put_conversation(String.t(), [map()], keyword()) :: :ok
  def put_conversation(id, entries, opts \\ []) do
    start()

    state = %{
      entries: Map.new(entries, &{&1[:pos], AgentConversation.Entry.normalize(&1)}),
      commands: Keyword.get(opts, :commands, []),
      anchors: Keyword.get(opts, :anchors, []),
      voice: Keyword.get(opts, :voice, {:error, :unavailable}),
      writable: Keyword.get(opts, :writable, true),
      sent: [],
      answers: []
    }

    Agent.update(@server, &Map.put(&1, id, state))
    :ok
  end

  @doc "Appends live entries to a seeded conversation."
  @spec append(String.t(), [map()]) :: :ok
  def append(id, entries) do
    start()

    Agent.update(@server, fn store ->
      Map.update!(store, id, fn state ->
        added = Map.new(entries, &{&1[:pos], AgentConversation.Entry.normalize(&1)})
        %{state | entries: Map.merge(state.entries, added)}
      end)
    end)
  end

  @doc "Every sent text for a conversation, oldest first."
  @spec sent(String.t()) :: [String.t()]
  def sent(id), do: fetch(id).sent

  @doc "Every answered `{command_id, action}` pair for a conversation."
  @spec answers(String.t()) :: [{String.t(), map()}]
  def answers(id), do: fetch(id).answers

  @impl true
  def read_entries(_host, id, opts) do
    with {:ok, state} <- get_state(id) do
      {:ok, page(state.entries |> Map.values() |> Enum.sort_by(& &1.pos), opts)}
    end
  end

  @impl true
  def read_anchors(_host, id, _opts) do
    with {:ok, state} <- get_state(id), do: {:ok, state.anchors}
  end

  @impl true
  def read_commands(_host, id) do
    with {:ok, state} <- get_state(id), do: {:ok, state.commands}
  end

  @impl true
  def send_text(_host, id, text) do
    with {:ok, state} <- get_state(id) do
      if state.writable do
        update(id, &%{&1 | sent: &1.sent ++ [text]})
        {:ok, %{text: text, delivered: true}}
      else
        {:error, :permission_denied}
      end
    end
  end

  @impl true
  def answer_command(_host, id, command_id, action) do
    with {:ok, state} <- get_state(id) do
      cond do
        not state.writable ->
          {:error, :permission_denied}

        Enum.any?(state.answers, fn {answered, _action} -> answered == command_id end) ->
          {:error, {:conflict, "another principal answered first"}}

        true ->
          record_answer(id, command_id, action)
      end
    end
  end

  @impl true
  def voice_capabilities(_host, id) do
    with {:ok, state} <- get_state(id), do: state.voice
  end

  defp record_answer(id, command_id, action) do
    update(id, &%{&1 | answers: &1.answers ++ [{command_id, action}]})
    {:ok, %{command_id: command_id, action: action}}
  end

  defp page(entries, opts) do
    limit = Keyword.get(opts, :limit, @limit)

    selected =
      cond do
        pos = opts[:around] -> entries |> Enum.filter(&(abs(&1.pos - pos) <= div(limit, 2))) |> Enum.take(limit)
        pos = opts[:after] -> Enum.filter(entries, &(&1.pos > pos)) |> Enum.take(limit)
        pos = opts[:before] -> entries |> Enum.filter(&(&1.pos < pos)) |> Enum.take(-limit)
        opts[:from] == :start -> Enum.take(entries, limit)
        true -> Enum.take(entries, -limit)
      end

    %{
      entries: selected,
      head_pos: entries |> List.last() |> then(&(&1 && &1.pos)) |> Kernel.||(0),
      prev_cursor: selected |> List.first() |> then(&(&1 && &1.pos)),
      next_cursor: selected |> List.last() |> then(&(&1 && &1.pos)),
      complete_from_start: selected == entries,
      sessions: [],
      observed_at: DateTime.utc_now()
    }
  end

  defp get_state(id) do
    start()

    case Agent.get(@server, &Map.fetch(&1, id)) do
      {:ok, state} -> {:ok, state}
      :error -> {:error, :not_found}
    end
  end

  defp fetch(id) do
    case get_state(id) do
      {:ok, state} -> state
      {:error, :not_found} -> %{sent: [], answers: []}
    end
  end

  defp update(id, fun) do
    start()
    Agent.update(@server, &Map.update!(&1, id, fun))
    :ok
  end
end
