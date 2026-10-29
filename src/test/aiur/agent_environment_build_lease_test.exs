defmodule Aiur.AgentEnvironmentBuildLeaseTest do
  use ExUnit.Case, async: false

  alias Aiur.AgentEnvironment

  test "workspace child environment does not inherit its parent's build lease" do
    original_path = System.get_env("AIUR_BUILD_GATE_LEASE_PATH")
    original_token = System.get_env("AIUR_BUILD_GATE_LEASE_TOKEN")

    on_exit(fn ->
      restore_env("AIUR_BUILD_GATE_LEASE_PATH", original_path)
      restore_env("AIUR_BUILD_GATE_LEASE_TOKEN", original_token)
    end)

    System.put_env("AIUR_BUILD_GATE_LEASE_PATH", "/parent/gate/slot-1.owner")
    System.put_env("AIUR_BUILD_GATE_LEASE_TOKEN", "parent-lease")

    workspace = Aiur.TestSupport.tmp_root!("aiur-build-lease-env")
    File.mkdir_p!(workspace)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace) end)

    child_env = AgentEnvironment.workspace_env(workspace)

    assert {~c"AIUR_BUILD_GATE_LEASE_PATH", false} in child_env
    assert {~c"AIUR_BUILD_GATE_LEASE_TOKEN", false} in child_env
  end

  test "scrub_shell_command clears the parent's build lease" do
    command =
      AgentEnvironment.scrub_shell_command("env | grep -E '^(AIUR_BUILD_GATE_LEASE_PATH|AIUR_BUILD_GATE_LEASE_TOKEN|OTHER_KEEP)=' | sort")

    {output, 0} =
      System.cmd("bash", ["-lc", command],
        env: [
          {"AIUR_BUILD_GATE_LEASE_PATH", "/parent/gate/slot-1.owner"},
          {"AIUR_BUILD_GATE_LEASE_TOKEN", "parent-lease"},
          {"OTHER_KEEP", "keep"}
        ]
      )

    assert output == "OTHER_KEEP=keep\n"
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
