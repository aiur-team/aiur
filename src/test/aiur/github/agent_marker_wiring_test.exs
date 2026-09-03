defmodule Aiur.GitHub.AgentMarkerWiringTest do
  @moduledoc """
  The two places that actually turn stamping on for a real install (#2501).

  `AgentMarker.stamp/1` and the `gh` wrapper are each tested on their own, but
  both are inert unless something calls them: the daemon's comment writer must
  stamp, and the agent environment must export the marker so the wrapper sees
  it. Without these cases, single-account mode could ship stamping nothing at
  all and every other test would still pass — which is exactly what a mutation
  run showed before they existed.
  """
  use Aiur.TestSupport

  alias Aiur.AgentEnvironment
  alias Aiur.GitHub.{AgentMarker, Comments}
  alias Aiur.Workflow

  @bot "aiur-bot"
  @workspace "/work/aiur/440"
  @repo_url "https://github.com/owner/project.git"

  defp configure!(mode) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "aiur",
      tracker_bot_account: @bot,
      tracker_identity_mode: mode
    )
  end

  setup do
    prev_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    on_exit(fn ->
      configure!("separate_account")
      restore_env("GITHUB_TOKEN", prev_token)
    end)

    :ok
  end

  defp env_marker(env) do
    List.keyfind(env, String.to_charlist(AgentMarker.env_var()), 0)
  end

  defp workspace_env do
    AgentEnvironment.workspace_env(@workspace,
      base_branch: "main",
      repo_url: @repo_url,
      github_budget_identity: @bot
    )
  end

  defp export_prefix do
    AgentEnvironment.workspace_env_export_prefix(@workspace,
      base_branch: "main",
      repo_url: @repo_url,
      github_budget_identity: @bot
    )
  end

  describe "agent environment carries the marker to the gh wrapper" do
    test "single-account mode exports the marker under the name AgentMarker owns" do
      configure!("single_account")

      assert {_name, value} = env_marker(workspace_env())
      assert List.to_string(value) == AgentMarker.marker()

      assert export_prefix() =~ "export #{AgentMarker.env_var()}="
      assert export_prefix() =~ AgentMarker.marker()
    end

    test "separate-account mode unsets it, so the wrapper rewrites nothing" do
      configure!("separate_account")

      assert {_name, false} = env_marker(workspace_env())
      assert export_prefix() =~ "unset #{AgentMarker.env_var()}"
      refute export_prefix() =~ AgentMarker.marker()
    end

    test "the exported name is AgentMarker's, not a hardcoded copy that can drift" do
      configure!("single_account")

      assert {name, _value} = env_marker(workspace_env())
      assert List.to_string(name) == AgentMarker.env_var()
    end
  end

  describe "daemon-side comment writer stamps" do
    defp capture_posted_body(mode) do
      configure!(mode)
      test = self()

      request_fun = fn %{body: %{"body" => body}} ->
        send(test, {:posted, body})
        {:ok, %{status: 201, body: %{}}}
      end

      :ok = Comments.create_comment("42", "Rework applied.", request_fun: request_fun)
      assert_receive {:posted, body}, 500
      body
    end

    test "single-account mode posts a marked body" do
      body = capture_posted_body("single_account")

      assert AgentMarker.marked?(body)
      assert String.starts_with?(body, "Rework applied.")
    end

    test "separate-account mode posts the body unchanged" do
      assert capture_posted_body("separate_account") == "Rework applied."
    end
  end
end
