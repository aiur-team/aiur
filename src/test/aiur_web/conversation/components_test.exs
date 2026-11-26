defmodule AiurWeb.Conversation.ComponentsTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias Aiur.Conversation.{Entry, Session}
  alias AiurWeb.Conversation.Components

  defp entry(kind, attrs \\ %{}), do: Map.merge(Map.from_struct(%Entry{pos: 1, kind: kind, role: "agent", body: "hello"}), attrs)
  defp html(entry, opts \\ []), do: render_component(&Components.entry/1, Keyword.merge([entry: entry], opts))

  test "each kind renders its distinguishing content and unknown kinds retain text" do
    cases = [
      {entry("message", %{body: "**hello**"}), "<strong>hello</strong>"},
      {entry("reasoning"), "conversation-reasoning"},
      {entry("command", %{body: "git status", output: "clean", meta: %{exit_code: 2}}), "$ git status"},
      {entry("tool_result", %{output: "files", meta: %{tool: "search", success: true}}), "search ·"},
      {entry("diff", %{body: "file.ex", output: "@@ one\n+added\n-removed"}), "conversation-diff-hunk"},
      {entry("operator_message", %{role: "executor_operator"}), "Executor"},
      {entry("system", %{meta: %{alert: true}}), "Alert:"},
      {entry("gap", %{meta: %{"from" => "then", "to" => "now", "reason" => "backpressure"}}), "No record from then to now"},
      {entry("future"), "Unknown entry kind: future"}
    ]

    for {item, expected} <- cases, do: assert(html(item) =~ expected)
    command = html(entry("command", %{output: "clean", meta: %{exit_code: 2}}))
    assert command =~ "Exit 2"
    assert command =~ "clean"
    refute html(entry("command", %{meta: %{exit_code: 0}})) =~ "Exit 0"
    diff = html(entry("diff", %{output: "@@ one\n+added\n-removed"}))
    assert diff =~ ~s(class="conversation-diff-add")
    assert diff =~ ~s(class="conversation-diff-remove")
  end

  test "reasoning and raw tool output are collapsed and tool status stays honest" do
    for item <- [entry("reasoning"), entry("command", %{output: "result"}), entry("tool_result", %{output: "result"})] do
      doc = item |> html() |> Floki.parse_fragment!()
      assert [_] = Floki.find(doc, "details:not([open])")
    end

    assert html(entry("tool_result", %{meta: %{success: false}})) =~ "Failed"
    assert html(entry("tool_result")) =~ "Status unknown"
  end

  test "long diff retains first 200 lines and collapses the remainder" do
    doc = entry("diff", %{output: Enum.map_join(1..203, "\n", &"+line #{&1}")}) |> html() |> Floki.parse_fragment!()
    assert length(Floki.find(doc, "article > .conversation-diff span")) == 200
    assert length(Floki.find(doc, "details:not([open]) .conversation-diff span")) == 3
    assert Floki.text(Floki.find(doc, "summary")) == "3 more diff lines"
  end

  test "truncated body and output show explicit omitted bytes and unknown size" do
    rendered = html(entry("command", %{body_truncated: true, body: "…[123 bytes omitted]…", output_truncated: true, output: "…[456 bytes omitted]…"}))
    assert rendered =~ "Middle of this output not stored (123 bytes)"
    assert rendered =~ "Middle of this output not stored (456 bytes)"
    assert html(entry("message", %{body_truncated: true})) =~ "Middle of this output not stored (unknown number of bytes)"
  end

  test "masked label is rendered and raw control needs explicit capability" do
    item = entry("message", %{redacted: true})
    assert html(item) =~ "masked"
    refute html(item) =~ "Show raw"
    assert html(item, can_reveal: true) =~ "Show raw"
    refute html(entry("message"), can_reveal: true) =~ "Show raw"
  end

  test "provider input cannot become an operator bubble even for operator kind" do
    rendered = html(entry("operator_message", %{role: "provider_input", body: "untrusted input"}))
    assert rendered =~ "provider input: untrusted input"
    assert rendered =~ "conversation-system"
    refute rendered =~ "conversation-operator-bubble"
    assert html(entry("operator_message", %{role: "operator"})) =~ "Operator"
  end

  test "markdown and command, output, diff and operator text escape script tags" do
    for kind <- ~w(message reasoning command tool_result diff operator_message system future) do
      rendered = html(entry(kind, %{body: "**safe** <script>alert(1)</script>", output: "<script>alert(2)</script>"}))
      refute rendered =~ "<script>"
      assert rendered =~ "&lt;script&gt;"
      if kind == "message", do: assert(rendered =~ "<strong>safe</strong>")
    end
  end

  test "gap causes and session dividers retain reason and timestamp" do
    assert html(entry("gap")) =~ "No record from unknown time to unknown time"
    assert html(entry("gap")) =~ "Reason unknown"
    session = %Session{session_seq: 1, first_pos: 1}
    assert html(entry("message"), sessions: [session]) =~ "Time unknown"
    assert html(entry("message"), sessions: [session]) =~ "Start reason unknown"

    for {reason, text} <- [{"pre_journal", "Earlier history is not available"}, {"source_unreadable", "Transcript source was unreadable"}, {"backpressure", "Recording could not keep up"}] do
      assert html(entry("gap", %{meta: %{reason: reason}})) =~ text
    end

    for {reason, text} <- [{"resume", "Resumed after restart"}, {"clear", "New session after /clear"}, {"import", "Imported history"}] do
      session = %Session{session_seq: 2, first_pos: 1, start_reason: reason, started_at: "session-time"}
      rendered = html(entry("message"), sessions: [session])
      assert rendered =~ text
      assert rendered =~ ~s(datetime="session-time")
    end
  end
end
