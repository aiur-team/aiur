defmodule Aiur.ApplicationDashboardPagesTest do
  use ExUnit.Case, async: true

  alias Aiur.Application, as: AiurApp

  test "API-without-pages run passes dashboard_pages?: false to HttpServer" do
    shape = [interactive_cli?: false, headless?: true, dashboard?: true]

    assert {Aiur.HttpServer, [dashboard_pages?: false]} in AiurApp.child_specs(shape ++ [dashboard_pages?: false])
    assert {Aiur.HttpServer, [dashboard_pages?: true]} in AiurApp.child_specs(shape)
  end
end
