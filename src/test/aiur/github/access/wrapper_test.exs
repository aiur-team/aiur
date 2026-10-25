defmodule Aiur.GitHub.Access.WrapperTest do
  use ExUnit.Case, async: false

  alias Aiur.GitHub.HostCommand

  @moduletag :tmp_dir

  test "installer and host commands resolve the same configured wrapper", %{tmp_dir: root} do
    previous = Application.fetch_env(:aiur, :host_guard_bin_dir)
    on_exit(fn -> Aiur.TestSupport.restore_app_env([{:host_guard_bin_dir, previous}]) end)
    Application.put_env(:aiur, :host_guard_bin_dir, root)
    executable = Path.join(root, "gh")
    File.write!(executable, "#!/bin/sh\nexit 0\n")
    File.chmod!(executable, 0o755)

    assert Aiur.AgentGitHubGuard.host_bin_dir() == root
    assert HostCommand.find_executable() == executable
  end
end
