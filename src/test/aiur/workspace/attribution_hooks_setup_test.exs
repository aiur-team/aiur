defmodule Aiur.Workspace.AttributionHooksSetupTest do
  use ExUnit.Case, async: true

  @hooks_path Path.expand("../../../.aiur/hooks", __DIR__)
  @installer_path Path.expand("../../../scripts/install-attribution-hooks", __DIR__)

  test "after_create installs hooks that strip AI trailers and preserve human co-authors" do
    root = Aiur.TestSupport.tmp_root!("attribution-hooks-setup")
    workspace = Path.join(root, "workspace")
    origin = Path.join(root, "origin.git")
    seed = Path.join(root, "seed")
    File.mkdir_p!(workspace)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)

    git!(origin, ["init", "--bare", "--quiet", "--initial-branch=main"])
    git!(root, ["clone", "--quiet", origin, seed])
    git!(seed, ["config", "user.name", "Test User"])
    git!(seed, ["config", "user.email", "test@example.com"])
    File.write!(Path.join(seed, "README.md"), "base\n")
    git!(seed, ["add", "README.md"])
    git!(seed, ["commit", "--quiet", "-m", "base"])
    git!(seed, ["push", "--quiet", "origin", "main"])

    {:ok, hooks} = YamlElixir.read_from_file(@hooks_path)

    {output, 0} =
      System.cmd("sh", ["-c", hooks["after_create"]],
        cd: workspace,
        stderr_to_stdout: true,
        env: [
          {"PATH", "#{Path.dirname(System.find_executable("git"))}:/bin"},
          {"THIS_REPOSITORY_URL", origin},
          {"THIS_BASE_BRANCH", "main"},
          {"AIUR_TICKET_BRANCH", "aiur/test"},
          {"AIUR_REPO_STATE_PATH", Path.join(root, "state")}
        ]
      )

    assert output == ""
    assert File.regular?(Path.join(workspace, ".git/hooks/commit-msg"))
    assert File.regular?(Path.join(workspace, ".git/hooks/pre-push"))

    git!(workspace, ["config", "user.name", "Test User"])
    git!(workspace, ["config", "user.email", "test@example.com"])
    File.write!(Path.join(workspace, "change"), "content\n")
    git!(workspace, ["add", "change"])

    git!(workspace, [
      "commit",
      "-m",
      "change\n\nCo-authored-by: Claude <noreply@anthropic.com>\nCo-authored-by: Human <human@example.com>\nGenerated with Claude Code\nhttps://claude.ai/code/session/123"
    ])

    message = git!(workspace, ["show", "-s", "--format=%B", "HEAD"])
    refute message =~ "Claude"
    refute message =~ "Generated with"
    refute message =~ "claude.ai"
    assert message =~ "Co-authored-by: Human <human@example.com>"
  end

  test "installer provides the same portable hook implementation for existing workspaces" do
    assert File.regular?(@installer_path)
    assert File.read!(@installer_path) =~ "aiur-attribution-pre-push"
  end

  defp git!(directory, args) do
    {output, 0} = System.cmd("git", ["-C", directory | args], stderr_to_stdout: true)
    output
  end
end
