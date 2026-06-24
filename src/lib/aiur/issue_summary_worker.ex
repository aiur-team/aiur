defmodule Aiur.IssueSummaryWorker do
  @moduledoc """
  System-level worker that writes concise per-issue summary logs.
  """

  use GenServer

  require Logger

  alias Aiur.{AgentPubSub, AgentSetupScout, IssueSummaryLog}

  defstruct subscribed: MapSet.new(),
            seen: MapSet.new(),
            scout: AgentSetupScout.new(),
            reporter: Aiur.AgentSetupScout.GitHubReporter,
            max_lines: nil

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    _ = AgentPubSub.subscribe_running()
    _ = AgentPubSub.subscribe_status()
    _ = AgentPubSub.subscribe_agent_events()

    {:ok,
     %__MODULE__{
       reporter: Keyword.get(opts, :reporter, reporter()),
       max_lines: Keyword.get(opts, :max_lines)
     }}
  end

  @impl true
  def handle_info({:running_changed, summaries}, state) when is_list(summaries) do
    state =
      Enum.reduce(summaries, state, fn summary, acc ->
        identifier = Map.get(summary, :identifier)

        acc
        |> maybe_subscribe(identifier)
        |> maybe_write(identifier, running_summary(summary), timestamp: DateTime.utc_now())
      end)

    {:noreply, state}
  end

  def handle_info({:status_changed, %{identifier: identifier, status: status}}, state)
      when is_binary(identifier) do
    state =
      state
      |> maybe_subscribe(identifier)
      |> maybe_write(identifier, "Status changed: #{status}", timestamp: DateTime.utc_now())

    {:noreply, state}
  end

  def handle_info({:agent_event, identifier, {:transcript_event, %{role: _role, body: _body} = event}}, state)
      when is_binary(identifier) do
    state =
      state
      |> mark_subscribed(identifier)
      |> maybe_write(identifier, transcript_summary(event), timestamp: Map.get(event, :timestamp))
      |> observe_scout(identifier, event)

    {:noreply, state}
  end

  def handle_info({:agent_event, identifier, {:alert, %{name: name, message: message} = event}}, state)
      when is_binary(identifier) do
    text = "Alert #{name}: #{summarize(message)}"

    state =
      state
      |> mark_subscribed(identifier)
      |> maybe_write(identifier, text, timestamp: Map.get(event, :timestamp))

    {:noreply, state}
  end

  def handle_info({:agent_event, identifier, {:turn_event, identifier, tag, payload}}, state)
      when is_binary(identifier) do
    {:noreply, summarize_turn_event(state, identifier, tag, payload)}
  end

  def handle_info({:agent_event, identifier, {:aiur_turn_done, identifier, turn_id, reason}}, state)
      when is_binary(identifier) do
    {:noreply, summarize_aiur_turn_done(state, identifier, turn_id, reason)}
  end

  def handle_info({:turn_event, identifier, tag, payload}, state) when is_binary(identifier) do
    {:noreply, summarize_turn_event(state, identifier, tag, payload)}
  end

  def handle_info({:aiur_turn_done, identifier, _turn_id, reason}, state) when is_binary(identifier) do
    {:noreply, summarize_aiur_turn_done(state, identifier, nil, reason)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp maybe_subscribe(state, identifier) when is_binary(identifier) do
    mark_subscribed(state, identifier)
  end

  defp maybe_subscribe(state, _identifier), do: state

  defp mark_subscribed(state, identifier) when is_binary(identifier) do
    %{state | subscribed: MapSet.put(state.subscribed, identifier)}
  end

  defp maybe_write(state, _identifier, nil, _opts), do: state
  defp maybe_write(state, _identifier, "", _opts), do: state

  defp maybe_write(state, identifier, text, opts) when is_binary(identifier) and is_binary(text) do
    date = opts |> Keyword.get(:timestamp) |> summary_date()
    key = {identifier, date, text}

    if MapSet.member?(state.seen, key) do
      state
    else
      write_opts =
        opts
        |> Keyword.put_new(:max_lines, state.max_lines || IssueSummaryLog.max_lines())

      :ok = IssueSummaryLog.append_once(identifier, text, write_opts)
      %{state | seen: MapSet.put(state.seen, key)}
    end
  end

  defp observe_scout(state, identifier, event) do
    {scout, findings} = AgentSetupScout.observe(state.scout, identifier, event)
    Enum.each(findings, &report_finding(state.reporter, &1))
    %{state | scout: scout}
  end

  defp report_finding(reporter, finding) do
    _ = reporter.report(finding)
    :ok
  rescue
    error ->
      Logger.warning("agent_setup_scout reporter raised: #{Exception.message(error)}")
      :ok
  end

  defp summarize_turn_event(state, identifier, tag, payload) do
    reason = Map.get(payload, :reason) || Map.get(payload, "reason")

    text =
      if reason do
        "Turn #{tag}: #{summarize(inspect(reason))}"
      else
        "Turn #{tag}"
      end

    state
    |> mark_subscribed(identifier)
    |> maybe_write(identifier, text, timestamp: DateTime.utc_now())
  end

  defp summarize_aiur_turn_done(state, identifier, _turn_id, reason) do
    state
    |> mark_subscribed(identifier)
    |> maybe_write(identifier, "Aiur turn done: #{summarize(inspect(reason))}", timestamp: DateTime.utc_now())
  end

  defp running_summary(%{identifier: identifier, status: status} = summary) do
    descriptor =
      [Map.get(summary, :title), Map.get(summary, :tag), Map.get(summary, :backend)]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" / ")

    suffix = if descriptor == "", do: "", else: " (#{summarize(descriptor)})"
    "Agent #{identifier} #{status}#{suffix}"
  end

  defp transcript_summary(%{role: :command, body: body}), do: "Command: #{summarize(body)}"
  defp transcript_summary(%{role: :tool, body: body}), do: "Tool: #{summarize(body)}"
  defp transcript_summary(%{role: :assistant, body: body}), do: "Agent: #{summarize(body)}"
  defp transcript_summary(%{role: :system, body: body}), do: "System: #{summarize(body)}"
  defp transcript_summary(%{role: :user, body: body}), do: "Operator message: #{summarize(body)}"
  defp transcript_summary(%{role: :alert, body: body}), do: "Alert: #{summarize(body)}"
  defp transcript_summary(%{role: :reasoning}), do: nil
  defp transcript_summary(_event), do: nil

  defp summarize(text) do
    single = text |> to_string() |> String.replace(~r/\s+/, " ") |> String.trim()

    if String.length(single) > 160 do
      String.slice(single, 0, 160) <> "..."
    else
      single
    end
  end

  defp summary_date(%DateTime{} = ts), do: ts |> DateTime.to_date() |> Date.to_iso8601()
  defp summary_date(_), do: Date.utc_today() |> Date.to_iso8601()

  defp reporter do
    Application.get_env(:aiur, :agent_setup_scout_reporter, Aiur.AgentSetupScout.GitHubReporter)
  end
end
