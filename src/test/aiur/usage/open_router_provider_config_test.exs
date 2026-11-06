defmodule Aiur.Usage.OpenRouterProviderConfigTest do
  use Aiur.TestSupport

  alias Aiur.Usage.CLI

  # The route list is normally injected by the unit tests in
  # `open_router_provider_test.exs`. This file covers the wiring those injections
  # bypass: an operator's `openrouter:` route read straight from `agent.routing`
  # and the per-complexity candidate lists, with no OpenRouter route injection.
  test "a route configured in agent.routing is read without an injected route list" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_priority: ["claude"],
      agent_routing: %{3 => ["openrouter:deepseek/deepseek-v4-flash"]}
    )

    assert {:ok, payload} = CLI.payload("openrouter", meter_views: %{}, openrouter_spend: empty_spend())

    assert [
             %{
               "route" => "openrouter:deepseek/deepseek-v4-flash",
               "model" => "deepseek/deepseek-v4-flash",
               "state" => "no_reading"
             }
           ] = payload["provider"]["fields"]["routes"]

    assert payload["provider"]["fields"]["state"] == "no_reading"
    assert CLI.render(payload, "openrouter") =~ "route: openrouter:deepseek/deepseek-v4-flash  no reading"
  end

  test "a route configured only in the complexity candidate list is read too" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_priority: ["claude"],
      agent_routing: %{3 => ["claude:sonnet", "openrouter:deepseek/deepseek-v4-flash"]}
    )

    assert {:ok, payload} = CLI.payload("openrouter", meter_views: %{}, openrouter_spend: empty_spend())

    routes = Enum.map(payload["provider"]["fields"]["routes"], & &1["route"])
    assert "openrouter:deepseek/deepseek-v4-flash" in routes
    refute "claude:sonnet" in routes
  end

  defp empty_spend, do: %{api_equivalent: [], provider_reported: []}
end
