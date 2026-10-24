defmodule Aiur.ControlCLI.SettingsTest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.Config.Overrides

  setup do
    previous_instance = System.get_env("AIUR_INSTANCE_KEY")
    System.put_env("AIUR_INSTANCE_KEY", "settings-cli-test-#{System.unique_integer([:positive])}")
    {:ok, path} = Overrides.path()

    on_exit(fn ->
      Aiur.TestCleanup.rm_rf!(Path.dirname(path))

      if previous_instance,
        do: System.put_env("AIUR_INSTANCE_KEY", previous_instance),
        else: System.delete_env("AIUR_INSTANCE_KEY")
    end)

    :ok
  end

  test "set and list expose the stored value and provenance" do
    output = capture_io(fn -> Aiur.AgentControlCLI.set_setting("agent.max_concurrent_builds", "2") end)
    assert output =~ "agent.max_concurrent_builds set to 2 (live; revision 1)"
    assert output =~ "__AIUR_CONTROL_EXIT__:0"

    json_output = capture_io(fn -> Aiur.AgentControlCLI.list_settings(json: true) end)
    [json_line | _markers] = String.split(json_output, "\n", trim: true)
    assert [%{"key" => "agent.max_concurrent_builds", "source" => "override", "value" => 2, "actor" => "local:" <> _user}] = Jason.decode!(json_line)

    human_output = capture_io(fn -> Aiur.AgentControlCLI.list_settings() end)
    assert human_output =~ "agent.max_concurrent_builds=2 source=override revision=1 actor=local:"
    assert human_output =~ " set_at="
    assert human_output =~ " build="
    assert human_output =~ " applies=live"

    unset_output = capture_io(fn -> Aiur.AgentControlCLI.unset_setting("agent.max_concurrent_builds") end)
    assert unset_output =~ "override removed; YAML value will apply live"
    assert capture_io(fn -> Aiur.AgentControlCLI.list_settings(json: true) end) =~ "[]"
  end

  test "an unknown setting returns an application failure" do
    stderr =
      capture_io(:stderr, fn ->
        assert capture_io(fn -> Aiur.AgentControlCLI.set_setting("agent.max_concurrent_buildz", "2") end) =~
                 "__AIUR_CONTROL_EXIT__:1"
      end)

    assert stderr =~ "unknown setting on this build"
  end

  test "invalid JSON returns an application failure" do
    stderr =
      capture_io(:stderr, fn ->
        assert capture_io(fn -> Aiur.AgentControlCLI.set_setting("agent.max_concurrent_builds", "not-json") end) =~
                 "__AIUR_CONTROL_EXIT__:1"
      end)

    assert stderr =~ "setting value must be JSON"
  end

  test "a schema-invalid value returns the schema failure" do
    stderr =
      capture_io(:stderr, fn ->
        assert capture_io(fn -> Aiur.AgentControlCLI.set_setting("agent.routing", ~s({"bad":true})) end) =~
                 "__AIUR_CONTROL_EXIT__:1"
      end)

    assert stderr =~ "agent.routing"
  end

  test "agent-workspace callers cannot persist or remove overrides" do
    stderr =
      capture_io(:stderr, fn ->
        assert capture_io(fn ->
                 Aiur.AgentControlCLI.set_setting("agent.max_concurrent_builds", "2", caller_agent_workspace: "/workspaces/5969")
               end) =~ "__AIUR_CONTROL_EXIT__:1"
      end)

    assert stderr =~ "runtime setting changes are blocked inside agent workspaces"
    assert {:ok, []} = Overrides.list()

    capture_io(fn -> Aiur.AgentControlCLI.set_setting("agent.max_concurrent_builds", "2") end)

    unset_stderr =
      capture_io(:stderr, fn ->
        assert capture_io(fn ->
                 Aiur.AgentControlCLI.unset_setting("agent.max_concurrent_builds", caller_agent_workspace: "/workspaces/5969")
               end) =~ "__AIUR_CONTROL_EXIT__:1"
      end)

    assert unset_stderr =~ "runtime setting changes are blocked inside agent workspaces"
    assert {:ok, [%{key: "agent.max_concurrent_builds", value: 2}]} = Overrides.list()
  end

  test "missing instance identity returns a named application failure" do
    System.delete_env("AIUR_INSTANCE_KEY")

    stderr =
      capture_io(:stderr, fn ->
        assert capture_io(fn -> Aiur.AgentControlCLI.set_setting("agent.max_concurrent_builds", "2") end) =~
                 "__AIUR_CONTROL_EXIT__:1"
      end)

    assert stderr =~ "runtime settings require a valid AIUR_INSTANCE_KEY (instance_key_missing)"
  end
end
