defmodule Aiur.VoiceConversation.BriefingSource do
  @moduledoc "Read-only prototype briefing; the dedicated Executor briefing source replaces this in #4125."
  @behaviour VoiceConverse.Ports.BriefingSource

  alias VoiceConverse.Briefing

  @sections [
    %{id: "transcript", description: "Recent retained Executor transcript"},
    %{id: "agents", description: "Current run agents"},
    %{id: "decisions", description: "Open operator decisions"}
  ]

  @impl true
  def describe_target(:executor), do: %{id: "executor", kind: "executor", title: "Aiur Executor"}

  @impl true
  def brief(:executor) do
    now = DateTime.utc_now()

    extra =
      Enum.map(@sections, fn section ->
        {:ok, text} = details(:executor, section.id, n: 10)
        %{title: section.description, text: text, observed_at: now}
      end)

    {:ok,
     %Briefing{
       summary: %{value: "Read-only Executor voice briefing.", observed_at: now, max_age_s: 30},
       extra: extra,
       gaps: ["Prototype snapshot; no instruction delivery. Dedicated Executor briefing pending #4125."]
     }}
  end

  @impl true
  def sections(:executor), do: @sections

  @impl true
  def details(:executor, section, opts) do
    n = opts |> Keyword.get(:n, 10) |> max(1) |> min(30)
    {:ok, read_section(section, n)}
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
      rows -> Enum.map_join(rows, "\n", &agent_line/1)
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
      rows -> Enum.map_join(rows, "\n", &"#{&1.decision_id}: #{&1.question}")
    end
  end

  @spec transcript_text(map(), pos_integer()) :: String.t()
  def transcript_text(%{events: events}, n) when is_list(events) do
    events
    |> Enum.filter(&(Map.get(&1, :role) in ["user", "assistant"]))
    |> Enum.take(-n)
    |> case do
      [] -> "Executor transcript unavailable; no retained conversational turns."
      rows -> Enum.map_join(rows, "\n", &"#{&1.role}: #{Map.get(&1, :body, "")}")
    end
  end

  def transcript_text(_snapshot, _n), do: "Executor transcript unavailable."

  defp read_section("agents", n) do
    if Process.whereis(Aiur.Orchestrator) do
      Aiur.Orchestrator.snapshot() |> agents_text(n)
    else
      "Agent status unavailable."
    end
  catch
    :exit, _reason -> "Agent status unavailable."
  end

  defp read_section("decisions", n) do
    case Aiur.Commands.query_list(%{"lifecycle" => "open", "limit" => n}) do
      {:ok, %{health: %{status: :available}, decisions: decisions}} -> decisions_text(decisions, n)
      {:ok, %{health: %{status: :partial}, decisions: decisions}} -> "Partial decision data: " <> decisions_text(decisions, n)
      _unavailable -> "Decision status unavailable."
    end
  end

  defp read_section("transcript", n) do
    case Aiur.VoiceConversation.ExecutorTranscript.read(n) do
      {:ok, snapshot} -> transcript_text(snapshot, n)
      {:error, _reason} -> "Executor transcript unavailable."
    end
  end

  defp read_section(_section, _n), do: "Unknown detail section."

  defp agent_line(row) do
    identifier = Map.get(row, :identifier, "unknown")
    title = Map.get(row, :title, "Task not reported")
    activity = Map.get(row, :state) || "Activity not reported"
    "#{identifier}: #{title}; #{activity}"
  end
end
