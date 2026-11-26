defmodule AiurWeb.OperatorControlCenter.UnitsPresenterCatalogTest do
  use ExUnit.Case, async: true

  alias AiurWeb.OperatorControlCenter.UnitsPresenter.Catalog

  # Future regression guard for the existing unknown-freshness fallback.
  test "an unrecognized fleet freshness cannot become a healthy empty catalog" do
    snapshot = %{
      rows: [],
      health: %{membership: :healthy, status: :healthy},
      freshness: %{status: "unrecognized"}
    }

    assert Catalog.catalog_status(snapshot) == :stale
    assert Catalog.catalog_message(:stale, %{health: :healthy}, snapshot) == "Fleet updates are pending."
  end
end
