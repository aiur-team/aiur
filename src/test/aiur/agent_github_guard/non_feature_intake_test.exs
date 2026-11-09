defmodule Aiur.AgentGitHubGuard.NonFeatureIntakeTest do
  use Aiur.AgentGitHubGuardCase, async: true

  test "non-feature todo and queued requests land parked with the instance prefix", context do
    args_file = Path.join(context.workspace, "intake-args")

    for {prefix, flags} <- [
          {"agent", ["--label", "agent:todo"]},
          {"agent", ["--label=bug,agent:queued"]},
          {"nuc", ["-l", "bug,nuc:todo"]},
          {"nuc", ["-lnuc:queued"]}
        ] do
      File.write!(args_file, "")

      assert {"ok\n", 0} =
               run_guard(context, ["issue", "create", "--title", "x"] ++ flags,
                 AIUR_GITHUB_LABEL_PREFIX: prefix,
                 FAKE_GH_ARGS: args_file
               )

      args = File.read!(args_file)
      assert args =~ "--label needs-triage --label #{prefix}:parked"
      refute args =~ "#{prefix}:todo"
      refute args =~ "#{prefix}:queued"
    end
  end

  # Existing exemptions are future-regression guards, not coverage of the old bug.
  test "feature, build and container dispositions retain todo", context do
    args_file = Path.join(context.workspace, "exempt-args")

    for exemption <- ~w(feature:x build-lane:x build-order epic main-fix) do
      File.write!(args_file, "")
      flags = ["--label", "agent:todo", "--label=#{exemption}"]
      assert {"ok\n", 0} = run_guard(context, ["issue", "create", "--title", "x"] ++ flags, FAKE_GH_ARGS: args_file)
      assert File.read!(args_file) == "issue create --title x --label agent:todo --label=#{exemption}\n"
    end
  end

  test "the configured fixer label is exempt while the default label is ordinary work", context do
    args_file = Path.join(context.workspace, "fixer-args")

    for {label, parked?} <- [{"repair-main", false}, {"main-fix", true}] do
      File.write!(args_file, "")

      assert {"ok\n", 0} =
               run_guard(context, ["issue", "create", "--title", "x", "--label", "#{label},agent:todo"],
                 AIUR_GITHUB_FIXER_LABEL: "repair-main",
                 FAKE_GH_ARGS: args_file
               )

      args = File.read!(args_file)
      assert String.contains?(args, "agent:parked") == parked?
      assert String.contains?(args, "agent:todo") == not parked?
      assert args =~ label
    end
  end
end
