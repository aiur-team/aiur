Code.require_file("prewarm_fixture.exs", __DIR__)
Code.require_file(Path.expand("../control_cli/fixture.exs", __DIR__))

defmodule Aiur.OrchestratorStatusCliVisibilityTest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.Issue

  alias Aiur.Orchestrator.ControlCLI.TestFixture

  import TestFixture, except: [setup: 1]
  import Aiur.Orchestrator.StatusCLI.PrewarmFixture

  setup context do
    TestFixture.setup(context)
  end

  alias Aiur.Orchestrator.StatusCLI, as: AgentControlCLI

  describe "prewarm status surface" do
    test "status surfaces prewarm: warming while the base build is in flight" do
      with_prewarm_enabled()
      with_repo_base_phase(:building)

      output = capture_io(fn -> AgentControlCLI.status() end)
      assert output =~ "PREWARM prewarm: warming phase=building"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
    end

    test "status surfaces a failed base build as a cold-clone fallback" do
      with_prewarm_enabled()
      with_repo_base_phase({:error, :base_build_failed})

      output = capture_io(fn -> AgentControlCLI.status() end)
      assert output =~ "PREWARM prewarm: unavailable"
      assert output =~ "dispatching via cold clone"
    end

    test "status stays silent for a ready base and when prewarm is disabled" do
      # Default fixture config has prewarm disabled.
      disabled_output = capture_io(fn -> AgentControlCLI.status() end)
      refute disabled_output =~ "PREWARM"

      with_prewarm_enabled()
      with_repo_base_phase(:ready)
      ready_output = capture_io(fn -> AgentControlCLI.status() end)
      refute ready_output =~ "PREWARM"
    end
  end

  test "status hides closed cached issues and deactivated runtime entries", %{orchestrator: pid} do
    active = %Issue{id: "issue-active", identifier: "repo#44", state: "In Progress", title: "Active"}

    closed_stale_label = %Issue{
      id: "issue-closed-stale-label",
      identifier: "repo#523",
      state: "Closed",
      title: "Closed stale active label",
      labels: ["agent:human-review"]
    }

    closed_unlabeled = %Issue{
      id: "issue-closed-unlabeled",
      identifier: "repo#524",
      state: nil,
      title: "Closed with active label removed"
    }

    deactivated =
      "issue-deactivated"
      |> running_entry("repo#491", :deactivated)
      |> put_in([:issue, Access.key(:title)], "Deactivated")

    closed_running =
      "issue-closed-running"
      |> running_entry("repo#492", :working)
      |> update_in([:issue], &%{&1 | state: "Closed", title: "Closed running"})

    :sys.replace_state(pid, fn state ->
      %{
        state
        | last_polled_issues: %{
            "issue-active" => active,
            "issue-closed-stale-label" => closed_stale_label,
            "issue-closed-unlabeled" => closed_unlabeled
          },
          running: %{
            "issue-active" => running_entry("issue-active", "repo#44", :working),
            "issue-deactivated" => deactivated,
            "issue-closed-running" => closed_running
          }
      }
    end)

    output = capture_io(fn -> AgentControlCLI.status() end)

    assert output =~ "#44    running Issue repo#44"
    refute output =~ "#491"
    refute output =~ "#492"
    refute output =~ "#523"
    refute output =~ "#524"
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
  end
end
