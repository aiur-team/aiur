defmodule AiurWeb.Markdown do
  @moduledoc """
  Minimal, dependency-free Markdown renderer for bounded, already-sanitized
  ticket, pull-request description and analyst report text.

  The source has already passed `Aiur.DisplaySanitizer`, which
  redacts credentials and local paths while preserving Markdown source. This
  renderer detects block structure on the raw source, then HTML-escapes every
  content run before emitting any tag, converting a small block and inline
  subset — headings, paragraphs, fenced code blocks, blockquotes, unordered and
  ordered lists, pipe tables, inline code, emphasis, and links — into safe HTML.
  Everything else is preserved as escaped text.
  """

  import Phoenix.HTML, only: [raw: 1]
  alias AiurWeb.Markdown.Table

  @heading ~r/^\s*(\#{1,6})\s+(.+)$/
  @fence ~r/^\s*(?:```|~~~)/
  @blockquote ~r/^>\s?(.*)$/
  @unordered ~r/^\s*[-*+]\s+(.+)$/
  @ordered ~r/^\s*\d+\.\s+(.+)$/
  @code_span ~r/`([^`\n]+)`/
  @link ~r/\[([^\]]+)\]\(([^)\s]+)\)/
  @strong ~r/\*\*([^*]+)\*\*/
  @em ~r/(?<!\*)\*([^*]+)\*(?!\*)/
  @safe_link_schemes ~w(http https)
  @max_table_cells 4_096

  @spec render(term(), keyword()) :: Phoenix.HTML.Safe.t()
  def render(text, options \\ [])
  def render(nil, _options), do: raw("")

  def render(text, options) when is_binary(text) do
    offset = Keyword.get(options, :heading_offset, 0) |> max(0) |> min(5)

    text
    |> strip_null()
    |> String.split("\n")
    |> split_fences([], [])
    |> Enum.map_join("\n", &render_segment(&1, offset))
    |> raw()
  end

  def render(_other, _options), do: raw("")

  defp split_fences([], text_buf, segments) do
    Enum.reverse(emit_text(text_buf, segments))
  end

  defp split_fences([line | rest], text_buf, segments) do
    if Regex.match?(@fence, line) do
      {code_lines, rest} = take_code(rest, [])
      split_fences(rest, [], [{:code, Enum.reverse(code_lines)} | emit_text(text_buf, segments)])
    else
      split_fences(rest, [line | text_buf], segments)
    end
  end

  defp take_code([], acc), do: {acc, []}

  defp take_code([line | rest], acc) do
    if Regex.match?(@fence, line), do: {acc, rest}, else: take_code(rest, [line | acc])
  end

  defp emit_text([], segments), do: segments
  defp emit_text(text_buf, segments), do: [{:text, Enum.reverse(text_buf)} | segments]

  defp render_segment({:code, lines}, _offset) do
    "<pre><code>#{escape(Enum.join(lines, "\n"))}</code></pre>"
  end

  defp render_segment({:text, lines}, offset) do
    lines
    |> Enum.chunk_by(&(&1 == ""))
    |> Enum.reject(&match?(["" | _], &1))
    |> Enum.map(&render_blocks(&1, offset))
    |> Enum.intersperse("\n")
    |> IO.iodata_to_binary()
  end

  defp render_blocks([], _offset), do: ""

  defp render_blocks([first | rest] = lines, offset) do
    if Regex.match?(@heading, first), do: [render_heading(first, offset), render_blocks(rest, offset)], else: render_table_or_block(lines, offset)
  end

  defp render_table_or_block([header, delimiter | rest] = lines, offset) do
    case Table.alignments(header, delimiter) do
      nil ->
        render_non_table(lines, offset)

      alignments ->
        {rows, remaining} = Enum.split_while(rest, &Table.row?/1)
        [render_table(header, delimiter, rows, alignments), render_blocks(remaining, offset)]
    end
  end

  defp render_table_or_block(lines, offset), do: render_non_table(lines, offset)

  defp render_table(header, delimiter, rows, alignments) do
    if (length(rows) + 1) * length(alignments) <= @max_table_cells do
      Table.render(header, rows, alignments, &inline(escape(&1)))
    else
      render_paragraph([header, delimiter | rows])
    end
  end

  defp render_non_table(lines, offset) do
    {before, remaining} = take_until_table(lines, [])
    [render_block(before, offset), render_blocks(remaining, offset)]
  end

  defp take_until_table([header, delimiter | rest] = lines, acc) do
    if Regex.match?(@heading, header) or Table.alignments(header, delimiter) do
      {Enum.reverse(acc), lines}
    else
      take_until_table([delimiter | rest], [header | acc])
    end
  end

  defp take_until_table([line], acc) do
    if Regex.match?(@heading, line), do: {Enum.reverse(acc), [line]}, else: {Enum.reverse(acc) ++ [line], []}
  end

  defp render_block([first | _] = lines, offset) do
    cond do
      Enum.count(lines) == 1 and Regex.match?(@heading, first) -> render_heading(first, offset)
      list_block?(lines) -> render_list(lines)
      blockquote_block?(lines) -> render_blockquote(lines)
      true -> render_paragraph(lines)
    end
  end

  defp list_block?(lines), do: Enum.all?(lines, &(Regex.match?(@unordered, &1) or Regex.match?(@ordered, &1)))

  defp blockquote_block?(lines), do: Enum.all?(lines, &Regex.match?(@blockquote, &1))

  defp render_heading(line, offset) do
    [_, hashes, text] = Regex.run(@heading, line)
    level = min(byte_size(hashes) + offset, 6)

    "<h#{level}>#{inline(escape(text))}</h#{level}>"
  end

  defp render_list(lines) do
    tag = if Regex.match?(@ordered, hd(lines)), do: "ol", else: "ul"

    items =
      Enum.map(lines, fn line ->
        [_, item] = Regex.run(@unordered, line) || Regex.run(@ordered, line)
        "<li>#{inline(escape(item))}</li>"
      end)

    "<#{tag}>\n#{Enum.join(items, "\n")}\n</#{tag}>"
  end

  defp render_blockquote(lines) do
    content = Enum.map_join(lines, " ", fn line -> Regex.run(@blockquote, line) |> Enum.at(1) end)

    "<blockquote>#{inline(escape(content))}</blockquote>"
  end

  defp render_paragraph(lines), do: "<p>#{inline(escape(Enum.join(lines, " ")))}</p>"

  defp inline(text) do
    {text, code_refs} = extract_all(text, @code_span, "CODE", &code_span/1, [])
    {text, link_refs} = extract_all(text, @link, "LINK", &link/1, [])

    text
    |> strong()
    |> em()
    |> restore(link_refs)
    |> restore(code_refs)
  end

  defp code_span([_full, code]), do: "<code>#{code}</code>"

  defp link([_full, label, url]) do
    if safe_url?(url) do
      ~s(<a href="#{url}" rel="noopener noreferrer">#{label}</a>)
    else
      "[#{label}](#{url})"
    end
  end

  defp safe_url?(url) do
    %URI{scheme: scheme} = URI.parse(url)
    scheme in @safe_link_schemes
  end

  defp strong(text), do: Regex.replace(@strong, text, "<strong>\\1</strong>")
  defp em(text), do: Regex.replace(@em, text, "<em>\\1</em>")

  defp extract_all(text, regex, prefix, build, refs) do
    case Regex.run(regex, text) do
      nil ->
        {text, refs}

      captures ->
        match = hd(captures)

        case String.split(text, match, parts: 2) do
          [before, rest] ->
            token = "\u0000#{prefix}#{length(refs)}\u0000"
            refs = [{token, build.(captures)} | refs]
            extract_all(before <> token <> rest, regex, prefix, build, refs)

          _ ->
            {text, refs}
        end
    end
  end

  defp restore(text, refs), do: Enum.reduce(refs, text, fn {token, html}, acc -> String.replace(acc, token, html) end)

  defp strip_null(text), do: String.replace(text, "\u0000", "")

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end
end
