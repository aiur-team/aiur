defmodule Aiur.VoiceConversation.BriefingSource do
  @moduledoc "Read-only Executor prototype briefing, delegated by the Aiur voice host."
  @behaviour VoiceConverse.Ports.BriefingSource

  alias Aiur.{AgentStatusNote, BuildOrdersCLI, Commands, Orchestrator}
  alias Aiur.VoiceConversation.ExecutorTranscript
  alias VoiceConverse.Briefing

  @sections [
    %{id: "transcript", description: "Recent retained Executor transcript"},
    %{id: "agents", description: "Current run agents"},
    %{id: "decisions", description: "Open operator decisions"},
    %{id: "build_order", description: "Build-order progress"},
    %{id: "blockers", description: "Blocked tickets"},
    %{id: "commands", description: "Open Commands"}
  ]

  @impl true
  def describe_target(:executor), do: %{id: "executor", kind: "executor", title: "Aiur Executor"}

  @impl true
  def brief(:executor) do
    brief(:executor, [])
  end

  @doc false
  @spec brief(:executor, keyword()) :: {:ok, Briefing.t()}
  def brief(:executor, opts) do
    now = DateTime.utc_now()

    extra =
      Enum.map(@sections, fn section ->
        {:ok, text} = details(:executor, section.id, Keyword.merge(opts, n: 10))
        title = if section.id == "build_order", do: "Build-order progress and blockers", else: section.description
        %{title: title, text: text, observed_at: now}
      end)

    {:ok, %Briefing{summary: %{value: "Read-only Executor voice briefing.", observed_at: now, max_age_s: 30}, extra: extra}}
  end

  @impl true
  def sections(:executor), do: @sections

  @impl true
  def details(:executor, section, opts) do
    n = opts |> Keyword.get(:n, 10) |> max(1) |> min(30)
    {:ok, read_section(section, n, opts)}
  end

  @impl true
  def subscribe(:executor, _pid), do: :unsupported

  @impl true
  def alive?(:executor), do: true

  @doc "Renders only the bounded fields relevant to the spoken run briefing."
  @spec agents_text(map(), pos_integer()) :: String.t()
  def agents_text(%{running: running}, n) when is_list(running) do
    case Enum.take(running, n) do
      [] -> "No running agents."
      rows -> compact_lines(rows, &agent_line(&1, nil))
    end
  end

  def agents_text(_snapshot, _n), do: "Agent status unavailable."

  @spec decisions_text([map()], pos_integer()) :: String.t()
  def decisions_text(decisions, n) do
    decisions
    |> Enum.filter(&(Map.get(&1, :decision_status) in [:open, :deferred]))
    |> Enum.take(n)
    |> case do
      [] -> "No open decisions."
      rows -> compact_lines(rows, &"#{&1.decision_id}: #{&1.question}")
    end
  end

  @spec transcript_text(map(), pos_integer()) :: String.t()
  def transcript_text(%{events: events}, n) when is_list(events) do
    events
    |> Enum.filter(&(Map.get(&1, :role) in ["user", "assistant"]))
    |> Enum.take(-n)
    |> Enum.reverse()
    |> case do
      [] -> "Executor transcript unavailable; no retained conversational turns."
      rows -> compact_lines(rows, &"#{&1.role}: #{Map.get(&1, :body, "")}")
    end
  end

  def transcript_text(_snapshot, _n), do: "Executor transcript unavailable."

  # Reserve space for all three sections under the package's opening briefing budget.
  defp compact_lines(rows, render) do
    rows |> Enum.map_join("\n", &(render.(&1) |> excerpt(120))) |> excerpt(300)
  end

  defp excerpt(text, count) do
    prefix = text |> String.to_charlist() |> Enum.take(count) |> List.to_string()
    prefix <> if(byte_size(prefix) < byte_size(text), do: "…", else: "")
  end

  defp read_section("agents", n, opts) do
    snapshot_reader = Keyword.get(opts, :snapshot, fn -> Orchestrator.snapshot() end)

    case snapshot_reader.() do
      %{running: _} = snapshot ->
        notes_root = Keyword.get(opts, :status_note_root, Application.get_env(:aiur, :agent_status_note_root))
        notes = if notes_root, do: [root: notes_root], else: []

        snapshot
        |> running_agents()
        |> Enum.take(n)
        |> Enum.map_join("\n", fn row ->
          note = Keyword.get(opts, :status_note, fn id -> AgentStatusNote.latest(id, notes) end).(to_string(row.identifier))
          agent_line(row, note)
        end)
        |> empty_as("No running agents.")

      _ ->
        "Agent status unavailable."
    end
  catch
    :exit, _reason -> "Agent status unavailable."
  end

  defp read_section("decisions", n, opts) do
    query = Keyword.get(opts, :query_decisions, &Commands.query_list/1)

    case query.(%{"lifecycle" => "open", "limit" => n}) do
      {:ok, %{health: %{status: :available}, decisions: decisions}} -> decisions_text(decisions, n)
      {:ok, %{health: %{status: :partial}, decisions: decisions}} -> "Partial decision data: " <> decisions_text(decisions, n)
      _unavailable -> "Decision status unavailable."
    end
  end

  defp read_section("transcript", n, opts) do
    reader = Keyword.get(opts, :read_transcript, &ExecutorTranscript.read/1)

    case reader.(n) do
      {:ok, snapshot} -> transcript_text(snapshot, n)
      {:error, _reason} -> "Executor transcript unavailable."
    end
  end

  defp read_section("build_order", _n, opts) do
    reader = Keyword.get(opts, :build_orders, &BuildOrdersCLI.published/0)

    case reader.() do
      {:ok, %{data: %{catalog: catalog}}} -> build_order_text(catalog)
      _unavailable -> "Build-order progress unavailable."
    end
  rescue
    _error -> "Build-order progress unavailable."
  end

  defp read_section("blockers", n, opts) do
    reader = Keyword.get(opts, :blocked_tickets, fn -> Aiur.Commands.blocked_ticket_ids() end)

    case reader.() do
      {:ok, identifiers} when is_struct(identifiers, MapSet) -> identifiers |> MapSet.to_list() |> Enum.sort() |> Enum.take(n) |> Enum.join(", ") |> empty_as("No blocked tickets.")
      _ -> "Blocker data unavailable."
    end
  rescue
    _error -> "Blocker data unavailable."
  end

  defp read_section("commands", n, opts) do
    commands = Keyword.get(opts, :query_decisions, &Commands.query_list/1).(%{"lifecycle" => "open", "limit" => 10})
    executor_commands(commands, n)
  end

  defp read_section(_section, _n, _opts), do: "Unknown detail section."

  defp executor_commands({:ok, %{health: %{status: status}, decisions: decisions}}, n) when status in [:available, :partial] do
    open = Enum.filter(decisions, &(Map.get(&1, :decision_status) in [:open, :deferred]))
    top = open |> Enum.take(min(n, 3)) |> Enum.map_join("; ", &"#{&1.decision_id}: #{&1.question}")
    "#{length(open)} open; top #{min(length(open), min(n, 3))}: #{empty_as(top, "none")}"
  end

  defp executor_commands(_, _n), do: "Open Command status unavailable."

  defp agent_line(row, note) do
    identifier = Map.get(row, :identifier, "unknown")
    title = Map.get(row, :title, "Task not reported")
    activity = Map.get(row, :state) || "Activity not reported"

    note =
      case note do
        {:ok, value} -> value
        value when is_map(value) -> value
        _ -> nil
      end

    doing = if is_map(note), do: Map.get(note, "doing", "No note yet"), else: "No note yet"
    "#{identifier}: #{title}; #{activity}; #{doing}"
  end

  defp running_agents(%{running: running}) when is_list(running), do: running
  defp running_agents(_snapshot), do: []

  defp build_order_text(catalog) when is_map(catalog) do
    entries = Map.get(catalog, "epics", [])
    progress = Map.get(catalog, "progress", %{})
    blockers = Map.get(catalog, "edges", [])
    percent = value(progress, "percent", nil)
    progress_text = if is_number(percent), do: "#{percent}%", else: "progress unavailable"
    blocker_text = if is_list(blockers) and blockers != [], do: "; #{length(blockers)} blocker edge(s)", else: ""

    title = entries |> List.first() |> then(&if(is_map(&1), do: value(&1, "title", "Build orders"), else: "Build orders"))
    "#{title}: #{progress_text}#{blocker_text}"
  end

  defp build_order_text(_catalog), do: "Build-order progress unavailable."
  defp value(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp value(_map, _key, default), do: default
  defp empty_as("", fallback), do: fallback
  defp empty_as(value, _fallback), do: value
end
