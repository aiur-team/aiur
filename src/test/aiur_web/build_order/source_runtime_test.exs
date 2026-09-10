defmodule AiurWeb.BuildOrder.SourceRuntimeTest do
  use ExUnit.Case, async: true

  alias AiurWeb.BuildOrder.SourceRuntime
  alias Phoenix.LiveView.Socket

  defmodule ReportingSource do
    def refresh_catalog do
      send(self(), :refresh_catalog)
      :ok
    end
  end

  defmodule ExitingSource do
    def refresh_catalog, do: exit(:noproc)
  end

  defp socket(assigns) do
    %Socket{assigns: Map.merge(%{__changed__: %{}, source: ReportingSource}, assigns)}
  end

  test "a stated catalog re-converge reaches the source and is then rate limited" do
    socket = socket(%{catalog_refresh_at_ms: nil})

    refreshed = SourceRuntime.refresh_catalog(socket)

    assert_received :refresh_catalog
    assert is_integer(refreshed.assigns.catalog_refresh_at_ms)

    _suppressed = SourceRuntime.refresh_catalog(refreshed)

    refute_received :refresh_catalog
  end

  test "the rate limit expires rather than spending the control once and for all" do
    # A one-shot control would satisfy "the second click does nothing" while
    # leaving the operator with no way to ask again a minute later (#2544).
    stale = System.monotonic_time(:millisecond) - SourceRuntime.catalog_refresh_min_interval_ms() - 1

    _refreshed = SourceRuntime.refresh_catalog(socket(%{catalog_refresh_at_ms: stale}))

    assert_received :refresh_catalog
  end

  test "a source that cannot answer does not take the page down with it" do
    refreshed = SourceRuntime.refresh_catalog(socket(%{catalog_refresh_at_ms: nil, source: ExitingSource}))

    assert is_integer(refreshed.assigns.catalog_refresh_at_ms)
  end
end
