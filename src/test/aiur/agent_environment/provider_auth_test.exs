defmodule Aiur.AgentEnvironment.ProviderAuthTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentEnvironment.ProviderAuth

  test "stages only the provider secret in a private file and removes it from launch env" do
    workspace = Aiur.TestSupport.tmp_root!("aiur-provider-auth-file")
    File.mkdir_p!(workspace)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace) end)

    assert {:ok, [{"CODEX_HOME", "/state/codex"}], path} =
             ProviderAuth.stage(workspace, [
               {"CLAUDE_CODE_OAUTH_TOKEN", "subscription-secret"},
               {"CODEX_HOME", "/state/codex"}
             ])

    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    assert File.read!(path) =~ "subscription-secret"
    refute ProviderAuth.shell_prefix(path) =~ "subscription-secret"
    assert :ok = ProviderAuth.cleanup(path)
    refute File.exists?(path)
  end
end
