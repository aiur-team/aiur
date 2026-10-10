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
      capabilities: %{
        "commands.answer" => %{
          state: :degraded,
          reason: :dependency_unavailable,
          observed_at: ~U[2026-10-09 12:00:00Z],
          depends_on: ["orchestration"],
          version: 1,
          route: "/commands",
          detail: "ghp_secret"
        }
      },
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
             "capabilities" => %{
               "commands.answer" => %{
                 "state" => "degraded",
                 "reason" => "dependency_unavailable",
                 "observed_at" => "2026-10-09T12:00:00Z",
                 "depends_on" => ["orchestration"],
                 "version" => 1,
                 "route" => "/commands"
               }
             }
           }
  end

  test "to_wire output equals the contracts golden fixture" do
    report = %{
      contract: "aiur.capabilities",
      contract_version: 1,
      boot_id: "fixed-boot-id",
      revision: 7,
      observed_at: ~U[2026-10-09 12:00:00Z],
      age_ms: 840,
      freshness: "current",
      min_client_versions: %{phone: "1.0.0"},
      machine: %{machine_id: "abcdefghijklmnopqrstuvwxyz", label: "workstation"},
      instance: %{
        instance_id: "abcdefghijklmnopqrstuvwxyz/3f9a1c0b2e",
        aiur_version: "0.0.9",
        run_shape: %{http_listener: true, dashboard_pages: true, dashboard: true, headless: false, interactive_cli: true, executor_mode: true}
      },
      repository: %{kind: :github, owner: "aiur-team", name: "aiur"},
      executor: %{state: :active, consumer_id: "fixture-executor", harness: nil, session_ref: nil},
      capabilities: %{
        "identity" => %{state: :available, reason: nil},
        "orchestration" => %{state: :degraded, reason: :snapshot_stale, observed_at: ~U[2026-10-09 12:00:00Z]},
        "commands.answer" => %{state: :unavailable, reason: :dependency_unavailable, depends_on: ["orchestration"], version: 1},
        "executor.conversation" => %{state: :unavailable, reason: :executor_not_managed, route: "/executor"},
        "listener_modes" => %{state: :unavailable, reason: :spec_invalid},
        "build_queue" => %{state: :degraded, reason: :writes_paused},
        "build_queue.build_order_source" => %{state: :unavailable, reason: :store_unavailable},
        "harness.codex.native_question" => %{state: :available, mode: :in_band_hold}
      }
    }

    wire = Aiur.Capabilities.to_wire(report)
    golden = Path.expand("../../../packages/aiur-contracts/fixtures/capabilities.v1.json", __DIR__)

    if System.get_env("AIUR_UPDATE_GOLDEN") == "1" do
      File.write!(golden, Jason.encode!(wire, pretty: true) <> "\n")
    end

    assert wire == golden |> File.read!() |> Jason.decode!()
  end
end
