defmodule Aiur.IssueBody do
  @moduledoc "Reads directive lines (`Skills:`, `Premises:`) from a ticket body."

  @doc """
  Body lines outside fenced code blocks, so a ticket that documents a directive
  in an example does not apply it to itself.
  """
  @spec lines(String.t() | nil) :: [String.t()]
  def lines(body) when is_binary(body) do
    body
    |> String.split(~r/\r?\n/)
    |> Enum.reduce({false, []}, fn line, {fenced?, kept} ->
      cond do
        String.starts_with?(String.trim(line), "```") -> {not fenced?, kept}
        fenced? -> {true, kept}
        true -> {false, [line | kept]}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  def lines(_body), do: []
end
