defmodule Aiur.Workspace.RestackCredentialsBoundaryTest do
  use ExUnit.Case, async: false

  alias Aiur.Workspace.RestackGit

  def credential_path, do: "/registered/agent-token"

  test "git receives the registered credential path and clears inherited paths without a provider" do
    workspace = Aiur.TestSupport.tmp_root!("restack-credential-boundary")
    File.mkdir_p!(workspace)
    previous = Application.fetch_env(:aiur, :workspace_git_credential_file)
    inherited = System.get_env("AIUR_GITHUB_CREDENTIAL_FILE")

    on_exit(fn ->
      Aiur.TestCleanup.rm_rf!(workspace)

      case previous do
        {:ok, value} -> Application.put_env(:aiur, :workspace_git_credential_file, value)
        :error -> Application.delete_env(:aiur, :workspace_git_credential_file)
      end

      if inherited, do: System.put_env("AIUR_GITHUB_CREDENTIAL_FILE", inherited), else: System.delete_env("AIUR_GITHUB_CREDENTIAL_FILE")
    end)

    System.put_env("AIUR_GITHUB_CREDENTIAL_FILE", "/inherited/agent-token")
    Application.put_env(:aiur, :workspace_git_credential_file, {__MODULE__, :credential_path, []})
    args = ["-c", ~s(alias.credentialpath=!printf '%s' "${AIUR_GITHUB_CREDENTIAL_FILE-unset}"), "credentialpath"]
    assert {"/registered/agent-token", 0} = RestackGit.run(workspace, args)

    Application.delete_env(:aiur, :workspace_git_credential_file)
    assert {"unset", 0} = RestackGit.run(workspace, args)
  end
end
