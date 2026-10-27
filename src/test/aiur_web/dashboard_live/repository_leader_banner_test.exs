defmodule AiurWeb.DashboardLive.RepositoryLeaderBannerTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias AiurWeb.DashboardLive.RepositoryLeaderBanner

  test "renders unknown and no-leader states with lease age and freshness" do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:second)
    refreshed_at = Calendar.strftime(observed_at, "%H:%M:%S UTC")
    datetime = DateTime.to_iso8601(observed_at)

    for leader <- ["unknown", "none"] do
      status = %{leader: leader, lease_age: "unknown", observed_at: observed_at, freshness: :fresh}
      html = status |> then(&RepositoryLeaderBanner.banner(%{status: &1})) |> rendered_to_string()

      assert html =~ "Repository leader: #{leader} · lease age unknown"
      assert html =~ "status refreshed"
      assert html =~ refreshed_at
      assert html =~ "datetime=\"#{datetime}\""
    end
  end

  test "refresh replaces the pending banner assign with the latest lease status" do
    previous = RepositoryLeaderBanner.initial_status()
    latest = %{leader: "instance-b", lease_age: "2s", observed_at: DateTime.utc_now(), freshness: :fresh}
    socket = %Phoenix.LiveView.Socket{assigns: %{repository_leader: previous, now: previous.observed_at, __changed__: %{}}}

    refreshed = RepositoryLeaderBanner.refresh(socket, fn -> latest end)

    assert refreshed.assigns.repository_leader == latest
    assert DateTime.compare(refreshed.assigns.now, latest.observed_at) in [:eq, :gt]
  end
end
