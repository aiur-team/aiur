defmodule AiurWeb.StreamdeckLive.CommandKeys do
  @moduledoc """
  Descriptors for the Stream Deck emulator's command surfaces: the focused
  agent's command row, the Commands page's history and option keys, and the
  strip readout that goes with them.
  """

  import AiurWeb.StreamdeckLive.Env, only: [dashboard_writable?: 0]

  # Without a focused agent there is no real pause or priority state to render.
  # Blank every slot rather than showing a control whose label would be a guess.
  @spec command_keys(map() | nil, boolean()) :: [map()]
  def command_keys(nil, _mic_held?), do: List.duplicate(empty_command_key(), 8)

  # The command keys are derived from the agent the orchestrator currently
  # reports, never from an optimistic local toggle, so a control call that the
  # orchestrator rejects leaves the key showing the state that actually holds.
  def command_keys(agent, mic_held?) do
    writable? = dashboard_writable?()

    [
      pause_command_key(Map.get(agent, :bucket) == :paused, writable?),
      # Logs is navigation rather than fleet control, so read-only leaves it
      # enabled: it changes what the operator sees, never what the fleet does.
      command_key("logs", "Logs", "SCROLL", icon: "logs", state: "ready"),
      # Mic is the only press-and-hold command: it carries no click handler, so
      # the hook drives it from pointer events.
      mic_command_key(mic_held?, writable?),
      # Settings is navigation too, and sits beside Mic because it is where the
      # deck reports what voice input is doing.
      command_key("settings", "Settings", "OPEN", icon: "settings", state: "ready"),
      # Commands is navigation to the focused agent's Command history, so
      # read-only leaves it enabled: it changes what the operator reads, never
      # what the fleet does.
      command_key("commands", "Commands", "OPEN", icon: "commands", state: "ready"),
      empty_command_key(),
      empty_command_key(),
      empty_command_key()
    ]
  end

  defp pause_command_key(true, writable?),
    do: command_key("pause", "Play", "RESUME", icon: "play", state: "paused", disabled?: not writable?)

  defp pause_command_key(false, writable?),
    do: command_key("pause", "Pause", "HOLD", icon: "pause", state: "running", disabled?: not writable?)

  defp mic_command_key(true, writable?),
    do: command_key("mic", "Mic", "HOLD", icon: "mic", mic?: true, state: "live", disabled?: not writable?)

  defp mic_command_key(false, writable?),
    do: command_key("mic", "Mic", "HOLD", icon: "mic", mic?: true, state: "idle", disabled?: not writable?)

  defp command_key(command, label, sub, opts) do
    %{
      command: command,
      label: label,
      sub: sub,
      icon: Keyword.fetch!(opts, :icon),
      mic?: Keyword.get(opts, :mic?, false),
      state: Keyword.get(opts, :state, "ready"),
      disabled?: Keyword.get(opts, :disabled?, false),
      empty?: false
    }
  end

  defp empty_command_key, do: %{empty?: true, mic?: false}

  # The Commands page's history window: one key per Command, newest first, with
  # an OPEN/ANSWERED badge like the physical deck. Empty slots stay disabled so
  # a pressed index always addresses the painted key.
  @spec commands_history_keys(map(), integer() | nil) :: [map()]
  def commands_history_keys(commands, selected_index) do
    (commands["items"] || [])
    |> Enum.with_index()
    |> Enum.take(8)
    |> Enum.map(fn {command, index} ->
      %{
        empty?: false,
        decision_id: command["decision_id"],
        question: command["question"] || "",
        status: command_status_badge(command["status"]),
        answerable?: command["status"] in ["open", "deferred"],
        selected?: index == selected_index,
        index: index
      }
    end)
    |> pad_slots(8, %{empty?: true})
  end

  # The detail view's option window, four to a page, then a Mic slot that is
  # explained as physical-only (the browser has no local microphone).
  @spec commands_option_keys(map(), non_neg_integer()) :: [map()]
  def commands_option_keys(selection, offset) do
    options = selection["options"] || []
    offset = min(offset, max(0, length(options) - 4))

    Enum.slice(options, offset, 4)
    |> Enum.with_index()
    |> Enum.map(fn {option, index} ->
      %{
        empty?: false,
        index: offset + index,
        label: option["label"] || "",
        selected?: false
      }
    end)
    |> pad_slots(4, %{empty?: true})
  end

  defp pad_slots(list, count, filler), do: list ++ List.duplicate(filler, max(0, count - length(list)))

  defp command_status_badge(status) when status in ["open", "deferred"], do: "OPEN"
  defp command_status_badge(status) when status in ["decided", "acknowledged", "resolved"], do: "ANSWERED"
  defp command_status_badge(status) when status in ["dismissed", "expired"], do: "CLOSED"
  defp command_status_badge(_status), do: "UNKNOWN"

  # The strip readout for the Commands page: a history heading, or the selected
  # Command's question and reading on the detail view.
  @spec commands_panel(map()) :: map()
  def commands_panel(assigns) do
    if assigns.commands_view == :detail and is_map(assigns.commands_selection) do
      command = assigns.commands_selection
      options = command["options"] || []
      offset = assigns.commands_offset || 0
      answerable? = command["status"] in ["open", "deferred"]

      %{
        view: "detail",
        question: command["question"] || "",
        reading: option_reading(command, assigns.commands_option),
        status: command_status_badge(command["status"]),
        answerable?: answerable?,
        selected?: assigns.commands_option != nil,
        more_options?: offset + 4 < length(options),
        note: answerable? && "Reading only — approve on the physical deck"
      }
    else
      items = assigns.commands["items"] || []
      active = Enum.count(items, &(&1["status"] in ["open", "deferred"]))

      %{
        view: "history",
        active: active,
        unavailable?: assigns.commands["unavailable"] == true,
        has_next?: assigns.commands["has_next"] == true,
        page_index: assigns.commands_page_index || 0,
        note: "Select a Command to read it"
      }
    end
  end

  defp option_reading(command, option_index) when is_integer(option_index) do
    case Enum.at(command["options"] || [], option_index) do
      %{"description" => description} when is_binary(description) and description != "" -> description
      %{"label" => label} when is_binary(label) -> label
      _ -> "No description"
    end
  end

  defp option_reading(command, _option_index) do
    case get_in(command, ["context", "short"]) do
      short when is_binary(short) and short != "" -> short
      _ -> "No description"
    end
  end
end
