defmodule AiurWeb.MarkdownTableTest do
  use ExUnit.Case, async: true
  alias AiurWeb.Markdown
  import Phoenix.HTML, only: [safe_to_string: 1]

  test "pipe tables use fixed alignment classes on headers and cells" do
    html = html("| Metric | n | p |\n| :--- | :---: | ---: |\n| latency | 12 | 0.01 |")
    assert html =~ ~s(<th scope="col" class="md-al-l">Metric</th>)
    assert html =~ ~s(<th scope="col" class="md-al-c">n</th>)
    assert html =~ ~s(<th scope="col" class="md-al-r">p</th>)
    assert html =~ ~s(<td class="md-al-c">12</td>)
    assert html =~ ~s(<td class="md-al-r">0.01</td>)
    assert html =~ ~s(class="md-table-wrap")
  end

  test "cells share escaping and link policy with paragraphs" do
    html = html("| Content | Link |\n| --- | --- |\n| <script>alert(1)</script> | [x](javascript:alert(1)) |\n| **bold** `code` | [ok](https://example.com) |")
    assert html =~ ~s[<td class="md-al-l">&lt;script&gt;alert(1)&lt;/script&gt;</td>]
    refute html =~ "<script>"
    refute html =~ ~s(href="javascript:)
    assert html =~ "[x](javascript:alert(1))"
    assert html =~ "<strong>bold</strong> <code>code</code>"
    assert html =~ ~s(href="https://example.com")
  end

  test "escaped pipes stay inside a cell and ragged rows preserve excess content" do
    html = html("| A | B | C |\n| --- | --- | --- |\n| one\\|two | three |\n| a | b | c | d |")
    assert html =~ ~s(<tr><td class="md-al-l">one|two</td><td class="md-al-l">three</td><td class="md-al-l"></td></tr>)
    assert html =~ ~s(<td class="md-al-l">c | d</td>)
  end

  test "only a matching delimiter row starts a table and fences remain literal" do
    for text <- ["A | B\nC | D", "| A | B |\n| --- |", "| A | B |\n| --- | unsafe |", "```\nA | B\n--- | ---\n```"] do
      refute html(text) =~ "<table>"
    end

    assert html("A | B\nC | D") == "<p>A | B C | D</p>"
    assert html("intro\nA | B\n--- | ---\na | b\noutro") =~ "</table></div><p>outro</p>"
    assert html("intro\nA | B\n--- | ---\na | b") =~ "<p>intro</p><div"
  end

  test "heading offset starts report headings at h3 and caps at h6" do
    html = Markdown.render("# Report\nIntroduction\n\n###### Details\nEvidence", heading_offset: 2) |> safe_to_string()
    assert html =~ "<h3>Report</h3>"
    assert html =~ "<h6>Details</h6>"
    assert html =~ "<p>Introduction</p>"
    assert html =~ "<p>Evidence</p>"
  end

  test "wide ragged tables fall back to bounded escaped text instead of amplifying padding" do
    header = Enum.join(List.duplicate("column", 64), " | ")
    delimiter = Enum.join(List.duplicate("---", 64), " | ")
    rows = List.duplicate("|", 63) ++ ["| <script>tail</script> |"]
    html = html(Enum.join([header, delimiter | rows], "\n"))
    refute html =~ "<table>"
    assert html =~ "<p>column"
    assert html =~ "&lt;script&gt;tail&lt;/script&gt;"
    assert byte_size(html) < 10_000
  end

  defp html(text), do: text |> Markdown.render() |> safe_to_string()
end
