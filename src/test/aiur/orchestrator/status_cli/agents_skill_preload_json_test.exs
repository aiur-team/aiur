Code.require_file(Path.expand("../control_cli/fixture.exs", __DIR__))

defmodule Aiur.OrchestratorStatusCliAgentsSkillPreloadJsonTest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.Handoff.CLI
  alias Aiur.Orchestrator.ControlCLI.TestFixture

  import TestFixture, except: [setup: 1]

  setup context do
    TestFixture.setup(context)
  end

  describe "agents --json skill_preload" do
    test "reports the reported skill preload per running row", %{orchestrator: pid} do
      agent = running_entry("issue-skjson", "repo#skjson", :working)
      :sys.replace_state(pid, fn state -> %{state | running: %{"issue-skjson" => agent}} end)

      preload = %{
        mapped: [%{name: "pixel-art", reason: "lane:art"}],
        over_budget: false,
        missing: ["ghost-skill"],
        bytes: 812,
        max_bytes: 4_096
      }

      send(pid, {:session_execution_info, "issue-skjson", %{backend: "claude", skills: "skills: pixel-art (lane:art)", skill_preload: preload}})
      :sys.get_state(pid)

      [row] = agents_json_rows()

      assert row["skill_preload"] == %{
               "mapped" => [%{"name" => "pixel-art", "reason" => "lane:art"}],
               "over_budget" => false,
               "missing" => ["ghost-skill"],
               "bytes" => 812,
               "max_bytes" => 4_096
             }
    end

    test "reports null, not an empty preload, when the preload is unknown", %{orchestrator: pid} do
      agent = running_entry("issue-adopted", "repo#adopted", :working)
      :sys.replace_state(pid, fn state -> %{state | running: %{"issue-adopted" => agent}} end)

      [row] = agents_json_rows()

      assert Map.has_key?(row, "skill_preload")
      assert row["skill_preload"] == nil
    end
  end

  defp agents_json_rows do
    output = capture_io(fn -> CLI.agents() end)
    [json | _markers] = String.split(output, "\n", trim: true)
    %{"contract" => "aiur.agents", "running" => rows} = Jason.decode!(json)
    rows
  end
end
