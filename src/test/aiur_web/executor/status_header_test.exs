defmodule AiurWeb.Executor.StatusHeaderTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  alias AiurWeb.Executor.StatusHeader

  test "unknown retains the last-seen age and timestamp" do
    html = render_component(&StatusHeader.header/1, snapshot: snapshot())
    assert html =~ ~s(data-state="unknown" data-freshness="unknown")
    assert html =~ "Status unknown</strong>, last seen"
    assert html =~ "8 minutes ago"
    assert html =~ ~s(datetime="2026-01-01T00:00:00Z")
    refute html =~ "Idle"
  end

  test "unavailable wakes leave the other fields readable" do
    html = render_component(&StatusHeader.header/1, snapshot: %{snapshot() | wakes: :unavailable})
    assert html =~ ~r/<dt>Wakes<\/dt>\s*<dd>unavailable<\/dd>/
    assert html =~ "codex · CLI 0.171.0"
    assert html =~ "untested (version_untested)"
    assert html =~ "2 · Owner primary"
  end

  test "compact shows only activity and its observation" do
    html = render_component(&StatusHeader.header/1, snapshot: snapshot(), compact: true)
    assert html =~ "Status unknown"
    assert html =~ "8 minutes ago"
    refute html =~ "<dl"
  end

  defp snapshot do
    %{
      binding: %{state: "attached", harness: "codex", codex_cli_version: "0.171.0"},
      harness_state: %{state: :unknown, observed_at: ~U[2026-01-01 00:00:00Z], freshness: :unknown, age_ms: 480_000},
      read_capability: %{status: :untested, reason: :version_untested, cli_version: "0.171.0"},
      wakes: %{cursor: 12, pending_count: 3},
      roster: [%{id: "former", role: "owner", state: :expired}, %{id: "primary", role: "owner", state: :active}],
      blockers: :unavailable
    }
  end
end
