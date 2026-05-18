defmodule AiurPane.Composer do
  @moduledoc """
  Composer state machine for a per-agent conversation pane.

  Holds the input buffer, the cursor offset within that buffer, and a small
  history. Exposes pure functions that the owning `AiurPane.Conversation`
  GenServer calls in response to keystrokes.

  Length-caps the buffer at 64 KiB and filters control characters except
  newline and tab on submit (defense-in-depth alongside server-side
  validation in `Aiur.PaneRPC`).
  """

  @max_bytes 65_536

  @type t :: %{buffer: String.t(), cursor: non_neg_integer(), history: [String.t()]}

  @spec new() :: t()
  def new, do: %{buffer: "", cursor: 0, history: []}

  @spec append(t(), binary()) :: t()
  def append(%{buffer: buffer, cursor: cursor} = state, chunk)
      when is_binary(chunk) do
    cond do
      byte_size(buffer) + byte_size(chunk) > @max_bytes ->
        state

      printable_or_newline?(chunk) ->
        {head, tail} = split_at(buffer, cursor)
        new_buffer = head <> chunk <> tail
        %{state | buffer: new_buffer, cursor: cursor + String.length(chunk)}

      true ->
        state
    end
  end

  @spec backspace(t()) :: t()
  def backspace(%{cursor: 0} = state), do: state

  def backspace(%{buffer: buffer, cursor: cursor} = state) do
    {head, tail} = split_at(buffer, cursor)
    new_head = String.slice(head, 0, max(String.length(head) - 1, 0))
    %{state | buffer: new_head <> tail, cursor: cursor - 1}
  end

  @spec move_left(t()) :: t()
  def move_left(%{cursor: 0} = state), do: state
  def move_left(%{cursor: cursor} = state), do: %{state | cursor: cursor - 1}

  @spec move_right(t()) :: t()
  def move_right(%{buffer: buffer, cursor: cursor} = state) do
    if cursor >= String.length(buffer), do: state, else: %{state | cursor: cursor + 1}
  end

  @spec submit(t()) :: {t(), String.t()}
  def submit(%{buffer: buffer, history: history} = state) do
    sanitized = sanitize(buffer)

    new_state = %{
      state
      | buffer: "",
        cursor: 0,
        history: [sanitized | history] |> Enum.take(50)
    }

    {new_state, sanitized}
  end

  defp sanitize(text) when is_binary(text) do
    String.replace(text, ~r/[\x00-\x08\x0B-\x1F]/, "")
  end

  defp split_at(buffer, cursor) when is_binary(buffer) and is_integer(cursor) do
    {String.slice(buffer, 0, cursor), String.slice(buffer, cursor, String.length(buffer))}
  end

  defp printable_or_newline?(<<c::utf8>>) when c == ?\n or c == ?\t or c >= 32, do: true

  defp printable_or_newline?(chunk) when is_binary(chunk) and byte_size(chunk) > 1,
    do: not has_control_chars?(chunk)

  defp printable_or_newline?(_other), do: false

  defp has_control_chars?(binary) when is_binary(binary) do
    Enum.any?(:binary.bin_to_list(binary), fn c ->
      c not in [9, 10] and (c < 32 or c == 127)
    end)
  end
end
