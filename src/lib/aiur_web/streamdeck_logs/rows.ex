defmodule AiurWeb.StreamdeckLogs.Rows do
  @moduledoc """
  Per-row presentation for the Stream Deck logs projection: row class, glyph
  gutter, tool body display and the plain-text line form.
  """

  @spec line(map()) :: String.t()
  def line(%{kind: :event_header, badge: badge, body: body}), do: "[#{badge}] #{body}"
  def line(%{kind: :message, role: role, body: body}), do: "[#{role}] #{body}"
  # An unrolled hunk line keeps its own sign, which is the only thing that says
  # whether it was added or removed. Without this clause it fell to the
  # catch-all and every line of every diff read "[INFO]".
  def line(%{kind: :diff_line, sign: sign, text: text}), do: "#{sign}#{text}"

  def line(%{kind: :diff, path: path, additions: additions, deletions: deletions, line: line}) do
    "[diff] #{path || "changed file"} +#{additions} -#{deletions}" <> if(is_binary(line) and line != "", do: " #{line}", else: "")
  end

  def line(_entry), do: "[INFO]"

  # Row kind drives the per-kind colour on both the emulator and the device.
  # Commands and tool rows are one class (the agent acting on an external
  # surface); agent prose is another; system/reasoning/alert are the "logs"
  # class. The third distinct colour (tan) belongs to logs.
  @doc false
  @spec row_kind(String.t() | atom()) :: :agent | :command | :user | :logs
  def row_kind(role) when role in ["assistant", :assistant], do: :agent
  def row_kind(role) when role in ["command", :command, "tool", :tool], do: :command
  def row_kind(role) when role in ["user", :user], do: :user
  def row_kind(_role), do: :logs

  # The opencode-style glyph gutter (#1934): `$` commands, `→` read, `←`
  # edit/write, `⚙` generic tools. The verb is detected from the RAW body
  # (before the prefix is stripped).
  @doc false
  @spec glyph(String.t() | atom(), term()) :: String.t() | nil
  def glyph(role, body) when role in ["tool", :tool] and is_binary(body) do
    case tool_verb(body) do
      :read -> "→"
      :write -> "←"
      :edit -> "←"
      nil -> "⚙"
    end
  end

  def glyph(role, _body) when role in ["command", :command], do: "$"
  def glyph(_role, _body), do: nil

  @doc false
  @spec tool_display(term()) :: term()
  def tool_display(body) when is_binary(body) do
    case tool_verb(body) do
      verb when verb in [:read, :write, :edit] ->
        case String.split(body, " ", parts: 2) do
          [_verb, rest] -> rest
          _ -> body
        end

      nil ->
        body
    end
  end

  def tool_display(body), do: body

  defp tool_verb(body) when is_binary(body) do
    cond do
      String.starts_with?(body, "read ") -> :read
      String.starts_with?(body, "write ") -> :write
      String.starts_with?(body, "edit ") -> :edit
      true -> nil
    end
  end
end
