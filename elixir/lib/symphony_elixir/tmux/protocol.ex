defmodule SymphonyElixir.Tmux.Protocol do
  @moduledoc """
  Stateful parser for the tmux control-mode wire format.

  Pure functional: `new_state/0` returns an initial state, `parse(state,
  chunk)` returns `{new_state, [event]}` for any bytes received from
  `tmux -CC`. The transport (Port, socket) is owned elsewhere.

  Recognized inputs:
    * `%begin <time> <cmd-num> <flags>\\n` ... `%end <time> <cmd-num> <flags>\\n`
      (command result, success)
    * `%begin <time> <cmd-num> <flags>\\n` ... `%error <time> <cmd-num> <flags>\\n`
      (command result, error)
    * `%pane-died %<pane-id>\\n`
    * `%window-pane-changed <window-id> %<pane-id>\\n`
    * `%client-detached\\n`
    * `%session-changed $<session-id> <session-name>\\n`
    * `%output %<pane-id> <escaped-data>\\n` (ignored in Phase 1)
    * `%exit [<reason>]\\n`

  Anything else starting with `%` is returned as `{:unknown_notification,
  line}` so callers can log without crashing.
  """

  defstruct buffer: "", in_response: nil

  @type cmd_num :: non_neg_integer()
  @type pane_id :: String.t()
  @type window_id :: String.t()
  @type session_id :: String.t()

  @type event ::
          {:command_result, cmd_num(), :ok | :error, [String.t()]}
          | {:notification, :pane_died, pane_id()}
          | {:notification, :window_pane_changed, window_id(), pane_id()}
          | {:notification, :client_detached}
          | {:notification, :session_changed, session_id(), String.t()}
          | {:notification, :output, pane_id(), String.t()}
          | {:notification, :exit, String.t() | nil}
          | {:unknown_notification, String.t()}

  @type t :: %__MODULE__{
          buffer: String.t(),
          in_response: nil | %{cmd_num: cmd_num(), body: [String.t()]}
        }

  @spec new_state() :: t()
  def new_state, do: %__MODULE__{}

  @spec parse(t(), binary()) :: {t(), [event()]}
  def parse(%__MODULE__{} = state, chunk) when is_binary(chunk) do
    {complete_lines, remainder} = split_lines(state.buffer <> chunk)
    {new_state, events} = Enum.reduce(complete_lines, {state, []}, &handle_line/2)
    {%{new_state | buffer: remainder}, Enum.reverse(events)}
  end

  defp split_lines(buffer) do
    parts = String.split(buffer, "\n")
    {complete, [remainder]} = Enum.split(parts, -1)
    {complete, remainder}
  end

  defp handle_line(line, {state, events}) do
    cond do
      state.in_response != nil ->
        handle_response_line(line, state, events)

      String.starts_with?(line, "%begin ") ->
        case parse_begin(line) do
          {:ok, cmd_num} -> {%{state | in_response: %{cmd_num: cmd_num, body: []}}, events}
          :error -> {state, [{:unknown_notification, line} | events]}
        end

      String.starts_with?(line, "%") ->
        handle_notification(line, state, events)

      true ->
        # Lines outside any response that don't start with % are ignored.
        {state, events}
    end
  end

  defp handle_response_line(line, state, events) do
    cond do
      String.starts_with?(line, "%end ") ->
        finalize_response(line, :ok, state, events)

      String.starts_with?(line, "%error ") ->
        finalize_response(line, :error, state, events)

      true ->
        {%{state | in_response: %{state.in_response | body: [line | state.in_response.body]}}, events}
    end
  end

  defp finalize_response(line, status, state, events) do
    case parse_end_or_error(line) do
      {:ok, cmd_num} when cmd_num == state.in_response.cmd_num ->
        body = Enum.reverse(state.in_response.body)
        {%{state | in_response: nil}, [{:command_result, cmd_num, status, body} | events]}

      _ ->
        {%{state | in_response: nil}, [{:unknown_notification, line} | events]}
    end
  end

  defp handle_notification(line, state, events) do
    event =
      cond do
        String.starts_with?(line, "%pane-died ") -> parse_pane_died(line)
        String.starts_with?(line, "%window-pane-changed ") -> parse_window_pane_changed(line)
        line == "%client-detached" -> {:notification, :client_detached}
        String.starts_with?(line, "%session-changed ") -> parse_session_changed(line)
        String.starts_with?(line, "%output ") -> parse_output(line)
        String.starts_with?(line, "%exit") -> parse_exit(line)
        true -> {:unknown_notification, line}
      end

    {state, [event | events]}
  end

  defp parse_begin("%begin " <> rest) do
    case String.split(rest, " ", parts: 3) do
      [_time, cmd_num_str, _flags] -> safe_cmd_num(cmd_num_str)
      _ -> :error
    end
  end

  defp parse_end_or_error(line) do
    # Callers always pre-filter on `%end ` / `%error ` prefixes, so we
    # don't need a third fallback clause — the line is guaranteed to
    # match one of these two forms.
    rest =
      if String.starts_with?(line, "%end "),
        do: String.replace_prefix(line, "%end ", ""),
        else: String.replace_prefix(line, "%error ", "")

    case String.split(rest, " ", parts: 3) do
      [_time, cmd_num_str, _flags] -> safe_cmd_num(cmd_num_str)
      _ -> :error
    end
  end

  defp safe_cmd_num(str) do
    case Integer.parse(str) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_pane_died("%pane-died " <> pane_id),
    do: {:notification, :pane_died, String.trim(pane_id)}

  defp parse_window_pane_changed("%window-pane-changed " <> rest) do
    case String.split(rest, " ", parts: 2) do
      [window_id, pane_id] ->
        {:notification, :window_pane_changed, String.trim(window_id), String.trim(pane_id)}

      _ ->
        {:unknown_notification, "%window-pane-changed " <> rest}
    end
  end

  defp parse_session_changed("%session-changed " <> rest) do
    case String.split(rest, " ", parts: 2) do
      [session_id, session_name] ->
        {:notification, :session_changed, String.trim(session_id), String.trim(session_name)}

      _ ->
        {:unknown_notification, "%session-changed " <> rest}
    end
  end

  defp parse_output("%output " <> rest) do
    case String.split(rest, " ", parts: 2) do
      [pane_id, data] -> {:notification, :output, String.trim(pane_id), data}
      _ -> {:unknown_notification, "%output " <> rest}
    end
  end

  defp parse_exit("%exit"), do: {:notification, :exit, nil}
  defp parse_exit("%exit " <> reason), do: {:notification, :exit, String.trim(reason)}
end
