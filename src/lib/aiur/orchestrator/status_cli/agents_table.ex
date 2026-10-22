defmodule Aiur.Orchestrator.StatusCLI.AgentsTable do
  @moduledoc false
  alias Aiur.Codex.EventHumanizer, as: CodexEventHumanizer
  alias Aiur.ControlCLI.DispatchAccount
  alias Aiur.Orchestrator.StatusObservation
  alias Aiur.Orchestrator.WaitingReason
  import Aiur.Orchestrator.ControlCLI.Output, only: [display_identifier: 1]
  import Aiur.EventHumanizerHelpers, only: [map_value: 2]

  @agents_header "ISSUE  STATE      RUNTIME  ACTIVITY"

  @doc false
  @spec print_agents_table(term()) :: term()
  def print_agents_table([]) do
    IO.puts(@agents_header)
    IO.puts("(no active agents)")
  end

  def print_agents_table(running) do
    IO.puts(@agents_header)

    Enum.each(running, fn agent ->
      IO.puts([
        String.pad_trailing(display_identifier(agent), 6),
        " ",
        String.pad_trailing(agents_state_label(agent), 10),
        " ",
        String.pad_trailing(format_runtime(Map.get(agent, :runtime_seconds)), 8),
        " ",
        agents_activity(agent),
        if(agent[:repl_attach_command], do: " | " <> agent.repl_attach_command, else: ""),
        WaitingReason.render_wait(agent) <> StatusObservation.row_label(agent) <> DispatchAccount.suffix(agent)
      ])
    end)
  end

  @doc false
  @spec print_idle_count(non_neg_integer()) :: :ok
  def print_idle_count(0), do: :ok
  def print_idle_count(count), do: IO.puts("(#{count} idle tickets hidden; use --all to show)")

  @doc false
  @spec visible_idle_rows([map()], boolean()) :: [map()]
  def visible_idle_rows(idle, true), do: idle
  def visible_idle_rows(idle, false), do: Enum.filter(idle, &idle_attention_row?/1)

  @doc false
  @spec idle_attention_row?(map()) :: boolean()
  def idle_attention_row?(agent) do
    Map.get(agent, :work_state) in [:paused, "paused"] or
      Map.get(agent, :waiting_reason) not in [nil, :active, :awaiting_dispatch] or
      Map.get(agent, :queue_depth, 0) > 0 or Map.get(agent, :claim_released?, false) == true
  end

  # The STATE and ACTIVITY columns read the human wait from the row's derived
  # `waiting_reason` — the same fact `aiur status` prints as
  # `waiting=waiting_for_human` — never from the raw work state alone. A live
  # agent blocked on an open decision used to read `working` here while
  # `status` read `waiting_for_human` for the same ticket (#2698).
  defp agents_state_label(%{work_state: state}) when state in [:paused, "paused", :deactivated, "deactivated"],
    do: to_string(state)

  defp agents_state_label(agent) do
    if WaitingReason.waiting_for_human?(agent),
      do: "waiting",
      else: to_string(Map.get(agent, :work_state, :working))
  end

  defp agents_activity(agent) do
    if WaitingReason.waiting_for_human?(agent),
      do: "(#{WaitingReason.render(:waiting_for_human)}: #{human_wait_cause(agent)})",
      else: agent_activity(agent)
  end

  defp human_wait_cause(%{open_decision_count: count}) when is_integer(count) and count > 0,
    do: "#{count} open decision#{if count == 1, do: "", else: "s"}"

  defp human_wait_cause(_agent), do: "agent requested input"

  @doc false
  @spec agent_activity(term()) :: term()
  def agent_activity(agent) do
    case Map.get(agent, :work_state, :working) do
      :retrying ->
        retry_activity(agent)

      :starting ->
        "(starting provider; no live turn yet)"

      paused when paused in [:paused, "paused"] ->
        paused_activity(agent)

      deactivated when deactivated in [:deactivated, "deactivated"] ->
        "(deactivated)"

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

  defp retry_activity(agent) do
    reason =
      case Map.get(agent, :error) do
        "startup failed: {:port_exit, " <> _ = error ->
          if String.match?(error, ~r/^startup failed: \{:port_exit, \d+\}$/), do: error, else: "previous worker failure"

        _ ->
          "previous worker failure"
      end

    time =
      case Map.get(agent, :last_failure_at) do
        %DateTime{} = at -> "; last failure #{DateTime.to_iso8601(at)}"
        _ -> ""
      end

    "(retrying: #{reason}#{time})"
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

  defp structured_activity?(%{message: message}) when is_map(message),
    do: structured_activity?(message)

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

  defp activity_string(value),
    do: value |> inspect(limit: 5, printable_limit: 120) |> String.trim()

  defp paused_activity(%{pause_reason: :label_override}), do: "(paused: label override)"
  defp paused_activity(%{pause_reason: "label_override"}), do: "(paused: label override)"
  defp paused_activity(_agent), do: "(paused)"

  @doc false
  @spec truncate(term(), term()) :: term()
  def truncate(text, max) do
    collapsed = text |> String.replace(~r/\s+/, " ") |> String.trim()

    if String.length(collapsed) > max do
      String.slice(collapsed, 0, max - 1) <> "…"
    else
      collapsed
    end
  end

  @doc false
  @spec format_runtime(term()) :: term()
  def format_runtime(seconds) when is_integer(seconds) and seconds >= 0 do
    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m"
      true -> "#{div(seconds, 3600)}h#{rem(div(seconds, 60), 60)}m"
    end
  end

  def format_runtime(_), do: "-"

  defp activity_payload(message) do
    case map_value(message, ["payload", :payload]) do
      payload when is_map(payload) -> payload
      _ -> message
    end
  end
end
