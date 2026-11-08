defmodule Aiur.Config.Schema.DashboardTest do
  use ExUnit.Case, async: true

  alias Aiur.Config.Schema.Dashboard

  test "projects_home defaults to false and casts true" do
    assert %Dashboard{projects_home: false} = %Dashboard{}
    assert Ecto.Changeset.apply_changes(Dashboard.changeset(%Dashboard{}, %{"projects_home" => true})).projects_home == true
  end
end
