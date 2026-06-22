defmodule Aiur.AgentControlCLI do
  @moduledoc false

  alias Aiur.{AgentChat, Orchestrator}

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

  defp result_verb(result), do: Map.fetch!(%{resumed: "resumed", started: "started"}, result)

  defp format_reason(reason) do
    Map.get(
      %{
        no_running_agent: "no running agent",
        agent_finished: "agent finished",
        max_concurrent_agents_reached: "max concurrent agents reached",
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
