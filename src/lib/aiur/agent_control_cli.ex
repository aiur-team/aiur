defmodule Aiur.AgentControlCLI do
  @moduledoc false

  alias Aiur.{AgentChat, Orchestrator}
  alias Aiur.Codex.EventHumanizer, as: CodexEventHumanizer
  import Aiur.EventHumanizerHelpers, only: [map_value: 2]

  @exit_marker "__AIUR_CONTROL_EXIT__:"

  @spec status() :: :ok
  def status do
    case Orchestrator.status() do
      statuses when is_list(statuses) ->
        print_status_table(statuses)
        exit_marker(0)

      error ->
        print_orchestrator_status_error(error)
        exit_marker(1)
    end
  end

  # Concise one-line-per-agent activity summary — the built-in, headless
  # equivalent of the dashboard / `aiur-status` log-tailing skill. Pulls the
  # orchestrator snapshot (richer than `status/0`: work-state + latest
  # activity) and prints state + what each agent is doing right now.
  @spec agents() :: :ok
  def agents do
    case Orchestrator.snapshot(Orchestrator, 10_000) do
      %{running: running} when is_list(running) ->
        print_agents_table(running)
        exit_marker(0)

      error when error in [:timeout, :unavailable] ->
        print_orchestrator_status_error(error)
        exit_marker(1)

      _other ->
        print_orchestrator_status_error(:unavailable)
        exit_marker(1)
    end
  end

  # Absolute set of the concurrent-agent cap on a live node — `aiur set
  # max-agents N`. Positive validation lives in the CLI; the orchestrator
  # applies the session cap and reports whether active work is draining down.
  @spec set_max_agents(integer()) :: :ok
  def set_max_agents(n) when is_integer(n) and n > 0 do
    case Orchestrator.set_max_concurrent_agents(n) do
      {:ok, status} ->
        IO.puts("aiur: max-agents set to #{status.max} (#{max_agents_status_suffix(status)})")
        exit_marker(0)

      {:error, reason} ->
        IO.puts(:stderr, "aiur: failed to set max-agents (#{format_reason(reason)})")
        exit_marker(1)
    end
  end

  def set_max_agents(_n) do
    IO.puts(:stderr, "aiur: max-agents must be a positive integer")
    exit_marker(1)
  end

  defp max_agents_status_suffix(%{active: active} = status) do
    paused = Map.get(status, :paused, 0)
    drain = if Map.get(status, :draining?) == true, do: ", draining", else: ""

    case paused do
      0 -> "#{active} active#{drain}"
      n -> "#{active} active, #{n} paused#{drain}"
    end
  end

  @spec pause(:all | [String.t()]) :: :ok
  def pause(targets), do: control(:pause, targets)

  @spec resume(:all | [String.t()]) :: :ok
  def resume(targets), do: control(:resume, targets)

  @spec message(String.t(), String.t()) :: :ok
  def message(issue, text) when is_binary(issue) and is_binary(text) do
    issue
    |> message_status(text, Orchestrator.status())
    |> exit_marker()
  end

  defp message_status(issue, text, statuses) when is_list(statuses) do
    case Enum.find(statuses, &target_matches?(&1, issue)) do
      nil ->
        print_failure(:message, %{identifier: issue, issue_id: issue}, :no_running_agent)
        1

      status ->
        deliver_message(status, text)
    end
  end

  defp message_status(_issue, _text, error) when error in [:timeout, :unavailable] do
    print_orchestrator_status_error(error)
    1
  end

  # Empty/whitespace-only and over-long text are validated downstream by
  # Orchestrator.send_operator_message (the shared delivery path), which returns
  # {:error, :empty_message | :message_too_long}; we surface those via format_reason.
  defp deliver_message(status, text) do
    case send_message(canonical_identifier(status), text) do
      {:ok, _request_id} ->
        IO.puts("aiur: messaged #{display_identifier(status)}")
        0

      {:error, reason} ->
        print_failure(:message, status, reason)
        1
    end
  end

  defp send_message(identifier, text) do
    Application.get_env(:aiur, :agent_control_cli_message_fun, &AgentChat.send/2).(identifier, text)
  end

  defp control(action, targets) when action in [:pause, :resume] do
    action
    |> control_status(targets, Orchestrator.status())
    |> exit_marker()
  end

  defp control_status(action, targets, statuses) when is_list(statuses) do
    action
    |> select_targets(targets, statuses)
    |> control_selected(action, targets)
  end

  defp control_status(_action, _targets, error) when error in [:timeout, :unavailable] do
    print_orchestrator_status_error(error)
    1
  end

  defp control_selected([], action, targets) do
    print_empty_selection(action, targets)
    0
  end

  defp control_selected(selected, action, _targets) do
    results = Enum.map(selected, &control_one(action, &1))
    failed = Enum.count(results, &match?({:error, _}, &1))

    if failed == length(results), do: 1, else: 0
  end

  defp select_targets(:pause, :all, statuses) do
    Enum.filter(statuses, &(&1.state in [:running, :paused]))
  end

  defp select_targets(:resume, :all, statuses) do
    Enum.filter(statuses, &(&1.state == :paused))
  end

  defp select_targets(_action, targets, statuses) when is_list(targets) do
    Enum.map(targets, fn target ->
      Enum.find(statuses, &target_matches?(&1, target)) ||
        %{identifier: target, issue_id: target, state: :missing}
    end)
  end

  defp control_one(:pause, %{state: :paused} = status) do
    IO.puts("aiur: already paused #{display_identifier(status)}")
    :ok
  end

  defp control_one(:pause, %{state: :running} = status) do
    canonical = canonical_identifier(status)

    case pause_agent(canonical) do
      {:ok, _request_id} ->
        IO.puts("aiur: paused #{display_identifier(status)} (was: running)")
        :ok

      {:error, reason} ->
        print_failure(:pause, status, reason)
        {:error, reason}
    end
  end

  defp control_one(:pause, status) do
    print_failure(:pause, status, :no_running_agent)
    {:error, :no_running_agent}
  end

  defp control_one(:resume, %{state: :paused} = status) do
    canonical = canonical_identifier(status)

    case resume_agent(canonical) do
      {:ok, result} when result in [:resumed, :started] ->
        IO.puts("aiur: #{result_verb(result)} #{display_identifier(status)} (was: paused)")
        :ok

      {:error, reason} ->
        print_failure(:resume, status, reason)
        {:error, reason}
    end
  end

  defp control_one(:resume, %{state: :running} = status) do
    IO.puts("aiur: already running #{display_identifier(status)}")
    :ok
  end

  defp control_one(:resume, %{state: :idle} = status) do
    canonical = canonical_identifier(status)

    case resume_agent(canonical) do
      {:ok, result} when result in [:started, :resumed] ->
        IO.puts("aiur: #{result_verb(result)} #{display_identifier(status)} (was: idle)")
        :ok

      {:error, reason} ->
        print_failure(:resume, status, reason)
        {:error, reason}
    end
  end

  defp control_one(:resume, status) do
    print_failure(:resume, status, :no_running_agent)
    {:error, :no_running_agent}
  end

  defp print_status_table([]) do
    IO.puts("ISSUE STATE  TITLE")
    IO.puts("(no active agents)")
  end

  defp print_status_table(statuses) do
    IO.puts("ISSUE STATE   TITLE")

    Enum.each(statuses, fn status ->
      IO.puts([
        String.pad_trailing(display_identifier(status), 6),
        " ",
        String.pad_trailing(to_string(status.state), 7),
        " ",
        to_string(status.title || "")
      ])
    end)
  end

  @agents_header "ISSUE  STATE      RUNTIME  ACTIVITY"

  defp print_agents_table([]) do
    IO.puts(@agents_header)
    IO.puts("(no active agents)")
  end

  defp print_agents_table(running) do
    IO.puts(@agents_header)

    Enum.each(running, fn agent ->
      IO.puts([
        String.pad_trailing(display_identifier(agent), 6),
        " ",
        String.pad_trailing(to_string(Map.get(agent, :work_state, :working)), 10),
        " ",
        String.pad_trailing(format_runtime(Map.get(agent, :runtime_seconds)), 8),
        " ",
        agent_activity(agent)
      ])
    end)
  end

  defp agent_activity(agent) do
    case Map.get(agent, :work_state, :working) do
      state when state in [:paused, :deactivated] ->
        "(#{state})"

      _ ->
        activity_values(agent)
        |> Enum.map(&activity_string/1)
        |> Enum.find("", &(&1 != ""))
        |> case do
          "" -> "(no activity yet)"
          text -> truncate(text, 80)
        end
    end
  end

  defp activity_values(agent) do
    message = Map.get(agent, :last_codex_message)
    event = Map.get(agent, :last_codex_event)

    if structured_activity?(message) do
      [message, event]
    else
      [event, message]
    end
  end

  defp structured_activity?(%{message: message}) when is_map(message), do: structured_activity?(message)

  defp structured_activity?(message) when is_map(message) do
    message
    |> activity_payload()
    |> map_value(["method", :method])
    |> is_binary()
  end

  defp structured_activity?(_value), do: false

  defp activity_string(value) when is_binary(value), do: String.trim(value)
  defp activity_string(nil), do: ""

  defp activity_string(%{message: message}) when is_map(message) do
    activity_string(message)
  end

  defp activity_string(message) when is_map(message) do
    payload = activity_payload(message)

    case map_value(payload, ["method", :method]) do
      method when is_binary(method) ->
        method |> CodexEventHumanizer.humanize_method(payload) |> String.trim()

      _ ->
        message |> inspect(limit: 5, printable_limit: 120) |> String.trim()
    end
  end

  defp activity_string(value), do: value |> inspect(limit: 5, printable_limit: 120) |> String.trim()

  defp truncate(text, max) do
    collapsed = text |> String.replace(~r/\s+/, " ") |> String.trim()

    if String.length(collapsed) > max do
      String.slice(collapsed, 0, max - 1) <> "…"
    else
      collapsed
    end
  end

  defp format_runtime(seconds) when is_integer(seconds) and seconds >= 0 do
    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m"
      true -> "#{div(seconds, 3600)}h#{rem(div(seconds, 60), 60)}m"
    end
  end

  defp format_runtime(_), do: "-"

  defp print_empty_selection(:pause, :all), do: IO.puts("aiur: no running agents")
  defp print_empty_selection(:resume, :all), do: IO.puts("aiur: no paused agents")

  defp print_orchestrator_status_error(error) do
    IO.puts(:stderr, Map.fetch!(%{timeout: "aiur: timed out while reading agent status", unavailable: "aiur: orchestrator is not running"}, error))
  end

  defp print_failure(action, status, reason) do
    IO.puts(:stderr, "aiur: failed to #{action} #{display_identifier(status)} (#{format_reason(reason)})")
  end

  defp target_matches?(status, target) do
    target = to_string(target)
    identifier = to_string(status.identifier || "")
    issue_id = to_string(status.issue_id || "")

    target == identifier or target == issue_id or String.ends_with?(identifier, "##{target}")
  end

  defp canonical_identifier(status) do
    to_string(status.identifier || status.issue_id)
  end

  defp pause_agent(identifier) do
    Application.get_env(:aiur, :agent_control_cli_pause_fun, &AgentChat.pause/1).(identifier)
  end

  defp resume_agent(identifier) do
    Application.get_env(:aiur, :agent_control_cli_resume_fun, &AgentChat.resume/1).(identifier)
  end

  defp display_identifier(%{identifier: identifier, issue_id: issue_id}) do
    cond do
      issue_number_suffix(identifier) ->
        "##{issue_number_suffix(identifier)}"

      numeric_identifier?(identifier) ->
        "##{identifier}"

      numeric_identifier?(issue_id) ->
        "##{issue_id}"

      is_binary(identifier) and identifier != "" ->
        identifier

      true ->
        to_string(issue_id)
    end
  end

  defp issue_number_suffix(identifier) when is_binary(identifier) do
    case Regex.run(~r/#(\d+)$/, identifier) do
      [_, number] -> number
      _ -> nil
    end
  end

  defp issue_number_suffix(_identifier), do: nil

  defp numeric_identifier?(identifier) when is_binary(identifier), do: Regex.match?(~r/^\d+$/, identifier)
  defp numeric_identifier?(_identifier), do: false

  defp activity_payload(message) do
    case map_value(message, ["payload", :payload]) do
      payload when is_map(payload) -> payload
      _ -> message
    end
  end

  defp result_verb(result), do: Map.fetch!(%{resumed: "resumed", started: "started"}, result)

  defp format_reason(reason) do
    Map.get(
      %{
        no_running_agent: "no running agent",
        agent_finished: "agent finished",
        max_concurrent_agents_reached: "max concurrent agents reached",
        below_active_count: "below active agent count",
        not_resumable: "not resumable",
        empty_message: "message is empty",
        message_too_long: "message is too long",
        invalid_message: "invalid message",
        unavailable: "orchestrator unavailable",
        timeout: "orchestrator timed out"
      },
      reason,
      inspect(reason)
    )
  end

  defp exit_marker(code) do
    IO.puts("#{@exit_marker}#{code}")
    :ok
  end
end
