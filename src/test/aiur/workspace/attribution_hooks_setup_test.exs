defmodule Aiur.Workspace.AttributionHooksSetupTest do
  use ExUnit.Case, async: true

  @hooks_path Path.expand("../../../../.aiur/hooks", __DIR__)
  @installer_path Path.expand("../../../../scripts/install-attribution-hooks", __DIR__)

  test "after_create installs hooks that strip AI trailers and preserve human co-authors" do
    root = Aiur.TestSupport.tmp_root!("attribution-hooks-setup")
    workspace = Path.join(root, "workspace")
    origin = Path.join(root, "origin.git")
    seed = Path.join(root, "seed")
    File.mkdir_p!(workspace)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)

    File.mkdir_p!(origin)
    git!(origin, ["init", "--bare", "--quiet", "--initial-branch=main"])
    git!(root, ["clone", "--quiet", origin, seed])
    git!(seed, ["config", "user.name", "Test User"])
    git!(seed, ["config", "user.email", "test@example.com"])
    File.mkdir_p!(Path.join(seed, "scripts"))
    File.cp!(@installer_path, Path.join(seed, "scripts/install-attribution-hooks"))
    File.chmod!(Path.join(seed, "scripts/install-attribution-hooks"), 0o755)
    File.write!(Path.join(seed, "README.md"), "base\n")
    git!(seed, ["add", "README.md", "scripts/install-attribution-hooks"])
    git!(seed, ["commit", "--quiet", "-m", "base"])
    git!(seed, ["push", "--quiet", "origin", "main"])

    {:ok, hooks} = YamlElixir.read_from_file(@hooks_path)

    {output, 0} =
      System.cmd("sh", ["-c", hooks["after_create"]],
        cd: workspace,
        stderr_to_stdout: true,
        env: [
          {"PATH", "#{Path.dirname(System.get_env("AIUR_REAL_GIT") || System.find_executable("git"))}:/bin"},
          {"THIS_REPOSITORY_URL", origin},
          {"THIS_BASE_BRANCH", "main"},
          {"AIUR_TICKET_BRANCH", "aiur/test"},
          {"AIUR_REPO_STATE_PATH", Path.join(root, "state")}
        ]
      )

    assert output =~ "Cloning into"
    assert File.regular?(Path.join(workspace, ".git/hooks/commit-msg"))
    assert File.regular?(Path.join(workspace, ".git/hooks/pre-push"))

    git!(workspace, ["config", "user.name", "Test User"])
    git!(workspace, ["config", "user.email", "test@example.com"])
    File.write!(Path.join(workspace, "change"), "content\n")
    git!(workspace, ["add", "change"])

    git!(workspace, [
      "commit",
      "-m",
      "change\n\nCo-authored-by: Claude <noreply@anthropic.com>\nCo-authored-by: Human <human@example.com>\nGenerated with Claude Code\nhttps://claude.ai/code/session_abc"
    ])

    message = git!(workspace, ["show", "-s", "--format=%B", "HEAD"])
    refute message =~ "Claude"
    refute message =~ "Generated with"
    refute message =~ "claude.ai"
    assert message =~ "Co-authored-by: Human <human@example.com>"
  end

  test "installer chains existing hooks and preserves their input" do
    root = Aiur.TestSupport.tmp_root!("attribution-hooks-chain")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    git!(workspace, ["init", "--quiet", "-b", "main"])
    git!(workspace, ["config", "user.name", "Test User"])
    git!(workspace, ["config", "user.email", "test@example.com"])
    File.write!(Path.join(workspace, "initial"), "initial\n")
    git!(workspace, ["add", "initial"])
    git!(workspace, ["commit", "--quiet", "-m", "initial"])

    commit_hook = Path.join(workspace, ".git/hooks/commit-msg")
    pre_push_hook = Path.join(workspace, ".git/hooks/pre-push")
    File.write!(commit_hook, "#!/bin/sh\necho called > commit-hook-called\n")
    File.write!(pre_push_hook, "#!/bin/sh\ncat > pre-push-input\n")
    File.chmod!(commit_hook, 0o755)
    File.chmod!(pre_push_hook, 0o755)

    {output, 0} = System.cmd(@installer_path, [workspace], stderr_to_stdout: true)
    assert output == ""
    assert File.read!(commit_hook <> ".aiur-original") =~ "commit-hook-called"
    assert File.read!(pre_push_hook <> ".aiur-original") =~ "pre-push-input"

    message_path = Path.join(workspace, "message")
    File.write!(message_path, "subject\n\nCo-authored-by: Claude <noreply@anthropic.com>\nCo-authored-by: Human <human@example.com>\n")
    {output, 0} = System.cmd(commit_hook, [message_path], cd: workspace, stderr_to_stdout: true)
    assert output == ""
    refute File.read!(message_path) =~ "Claude"
    assert File.read!(message_path) =~ "Human <human@example.com>"
    assert File.exists?(Path.join(workspace, "commit-hook-called"))

    File.write!(Path.join(workspace, "safe"), "safe\n")
    git!(workspace, ["add", "safe"])
    git!(workspace, ["commit", "--quiet", "-m", "safe commit"])
    sha = String.trim(git!(workspace, ["rev-parse", "HEAD"]))
    push_input = "refs/heads/main #{sha} refs/heads/main 0000000000000000000000000000000000000000\n"
    {output, 0} = System.cmd("sh", ["-c", "cd \"$1\" && printf '%s' \"$2\" | .git/hooks/pre-push", "sh", workspace, push_input], stderr_to_stdout: true)
    assert output == ""
    assert File.read!(Path.join(workspace, "pre-push-input")) == push_input
  end

  defp git!(directory, args) do
    {output, 0} = System.cmd("git", ["-C", directory | args], stderr_to_stdout: true)
    output
  end
end
