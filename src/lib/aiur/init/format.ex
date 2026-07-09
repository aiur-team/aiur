defmodule Aiur.Init.Format do
  @moduledoc """
  Shared terminal-text helpers (faint text, inline-help dimming, option-value recovery, hints) used by every wizard section.
  """

  @spec print_hint(Aiur.Init.io(), String.t()) :: :ok
  def print_hint(io, text), do: io.puts.(dim("  " <> text))

  # Greys an inline help suffix — the ` (...)` tail of an option — so the hint
  # (default model, file path, "coming soon") reads as secondary without
  # competing with the choice. `value_of/1` recovers the bare option value.
  @spec dim_help(String.t()) :: IO.chardata()
  def dim_help(option) do
    case String.split(option, " (", parts: 2) do
      [head, rest] -> [head, IO.ANSI.format([:faint, " (" <> rest])]
      [head] -> head
    end
  end

  @spec value_of(term()) :: String.t()
  def value_of(option), do: option |> to_string() |> String.split(" (", parts: 2) |> hd() |> String.trim()

  @spec dim(term()) :: IO.chardata()
  def dim(text), do: IO.ANSI.format([:faint, to_string(text)])
end
