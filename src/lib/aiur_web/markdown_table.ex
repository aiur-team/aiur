defmodule AiurWeb.Markdown.Table do
  @moduledoc false

  @spec alignments(String.t(), String.t()) :: [String.t()] | nil
  def alignments(header, delimiter) do
    cells = cells(delimiter)

    if cells != [] and row?(header) and length(cells(header)) == length(cells) and Enum.all?(cells, &Regex.match?(~r/^:?-{3,}:?$/, &1)) do
      Enum.map(cells, &alignment/1)
    end
  end

  defp alignment(cell) do
    cond do
      String.starts_with?(cell, ":") and String.ends_with?(cell, ":") -> "md-al-c"
      String.ends_with?(cell, ":") -> "md-al-r"
      true -> "md-al-l"
    end
  end

  @spec row?(String.t()) :: boolean()
  def row?(line), do: length(split(line)) > 1

  @spec render(String.t(), [String.t()], [String.t()], (String.t() -> String.t())) :: String.t()
  def render(header, rows, alignments, inline) do
    head = render_row(header, "th", alignments, inline)
    body = Enum.map_join(rows, "", &render_row(&1, "td", alignments, inline))
    ~s(<div class="md-table-wrap" tabindex="0" role="region" aria-label="Markdown table"><table><thead>#{head}</thead><tbody>#{body}</tbody></table></div>)
  end

  defp render_row(line, tag, alignments, inline) do
    width = length(alignments)
    {values, extra} = line |> cells() |> Enum.split(width - 1)
    values = Enum.take(values ++ [Enum.join(extra, " | ")] ++ List.duplicate("", width), width)
    scope = if tag == "th", do: ~s( scope="col"), else: ""
    content = Enum.zip_with(values, alignments, fn value, alignment -> ~s(<#{tag}#{scope} class="#{alignment}">#{inline.(value)}</#{tag}>) end)
    "<tr>#{Enum.join(content)}</tr>"
  end

  defp cells(line) do
    parts = line |> String.trim() |> split()
    parts = if hd(parts) == "", do: tl(parts), else: parts
    parts = if List.last(parts) == "", do: Enum.drop(parts, -1), else: parts
    Enum.map(parts, &String.trim/1)
  end

  defp split(line), do: split(String.graphemes(line), [], [])
  defp split([], cell, cells), do: Enum.reverse([cell |> Enum.reverse() |> Enum.join() | cells])
  defp split(["\\", "|" | rest], cell, cells), do: split(rest, ["|" | cell], cells)
  defp split(["\\", "\\" | rest], cell, cells), do: split(rest, ["\\", "\\" | cell], cells)
  defp split(["|" | rest], cell, cells), do: split(rest, [], [cell |> Enum.reverse() |> Enum.join() | cells])
  defp split([char | rest], cell, cells), do: split(rest, [char | cell], cells)
end
