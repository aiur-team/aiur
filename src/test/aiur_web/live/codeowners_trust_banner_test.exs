defmodule AiurWeb.CodeownersTrustBannerTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias AiurWeb.OperatorControlCenter.CodeownersTrust

  test "degraded trust renders the cause and elapsed age" do
    now = ~U[2026-10-09 12:00:00Z]
    snapshot = %{degradation: %{cause: {:team_lookup_failed, "@acme/team", :permission}, observed_at: DateTime.add(now, -60)}}
    html = render_component(&CodeownersTrust.banner/1, now: now, snapshot: snapshot)
    assert html =~ "CODEOWNERS trust degraded"
    assert html =~ "@acme/team"
    assert html =~ "permission"
    assert html =~ "age 60s"
  end

  test "unknown observation time renders age unknown" do
    html = render_component(&CodeownersTrust.banner/1, now: DateTime.utc_now(), snapshot: %{degradation: %{cause: :repo_owner_unknown, observed_at: nil}})
    assert html =~ "Repository owner is unknown"
    assert html =~ "age unknown"
  end
end
