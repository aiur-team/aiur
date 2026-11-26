defmodule Aiur.LocalTestEvidence.Bullets do
  @moduledoc "Moves a note written between a command and `->` to the end of the Local tests bullet."

  @section ~r/^(\#{2,6} Local tests\s*\n)(.*?)(?=^\#{1,6} |\z)/ms
  @bullet ~r/^- `([^`\n]+)` (?!->)(\S[^\n]*?) -> (\S[^\n]*)$/m

  @doc "Rewrites ``- `cmd` note -> result`` to ``- `cmd` -> result (note)`` inside the Local tests section only."
  @spec normalize(String.t()) :: String.t()
  def normalize(body) do
    Regex.replace(@section, body, fn _all, heading, section ->
      heading <> Regex.replace(@bullet, section, "- `\\1` -> \\3 (\\2)")
    end)
  end
end
