defmodule AiurWeb.MarkdownTest do
  use ExUnit.Case, async: true

  alias AiurWeb.Markdown

  import Phoenix.HTML, only: [safe_to_string: 1]

  test "renders a bounded GitHub-flavoured block and inline subset" do
    html =
      Markdown.render("""
      ## Overview

      - first
      - second

      1. one
      2. two

      > quoted

      **bold** and *em* with `code` and [a link](https://example.com)
      """)
      |> safe_to_string()

    assert html =~ "<h2>Overview</h2>"
    assert html =~ "<ul>"
    assert html =~ "<li>first</li>"
    assert html =~ "<ol>"
    assert html =~ "<li>one</li>"
    assert html =~ "<blockquote>quoted</blockquote>"
    assert html =~ "<strong>bold</strong>"
    assert html =~ "<em>em</em>"
    assert html =~ "<code>code</code>"
    assert html =~ ~s(href="https://example.com")
  end

  test "renders fenced code blocks without interpreting their content" do
    html = Markdown.render("```elixir\n1 + **not bold**\n```") |> safe_to_string()

    assert html =~ "<pre><code>1 + **not bold**</code></pre>"
    refute html =~ "<strong>"
  end

  test "escapes raw HTML before rendering" do
    html = Markdown.render("<script>alert(1)</script>") |> safe_to_string()

    refute html =~ "<script>"
    assert html =~ "&lt;script&gt;"
  end

  test "never emits an unsafe link scheme" do
    html = Markdown.render("[click](javascript:alert)") |> safe_to_string()

    refute html =~ ~s(href="javascript:)
    refute html =~ "<a "
    assert html =~ "[click](javascript:alert)"
  end

  test "renders nil as an empty safe fragment" do
    assert Markdown.render(nil) |> safe_to_string() == ""
  end
end
