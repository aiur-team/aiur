defmodule Aiur.CapabilitiesWireTest do
  use ExUnit.Case, async: true

  test "wire conversion preserves JSON types and drops provider diagnostics" do
    report = %{
      contract: "aiur.capabilities",
      contract_version: 1,
      revision: 7,
      boot_id: "boot",
      machine: %{machine_id: "machine", label: "workstation", path: "/home/private"},
      instance: %{instance_id: nil, run_shape: %{http_listener: true, dashboard_pages: false}},
      repository: nil,
      executor: %{state: :active, harness: nil},
      capabilities: %{"commands.answer" => %{state: :degraded, reason: :dependency_unavailable, depends_on: ["orchestration"], version: 1, route: "/commands", detail: "ghp_secret"}},
      detail: "sk-secret"
    }

    assert Aiur.Capabilities.to_wire(report) == %{
             "contract" => "aiur.capabilities",
             "contract_version" => 1,
             "revision" => 7,
             "boot_id" => "boot",
             "machine" => %{"machine_id" => "machine", "label" => "workstation"},
             "instance" => %{"instance_id" => nil, "run_shape" => %{"http_listener" => true, "dashboard_pages" => false}},
             "repository" => nil,
             "executor" => %{"state" => "active", "harness" => nil},
             "capabilities" => %{"commands.answer" => %{"state" => "degraded", "reason" => "dependency_unavailable", "depends_on" => ["orchestration"], "version" => 1, "route" => "/commands"}}
           }
  end
end
