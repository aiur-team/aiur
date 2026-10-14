defmodule Aiur.AgentGitHubGuard.ScriptTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  alias Aiur.AgentGitHubGuard.Script

  @hook_path Path.expand("../../../../.claude/hooks/issue-disposition.py", __DIR__)

  # SHA-256 of `src/priv/github_quota_guard.sh` and `src/priv/github_push_guard.sh`
  # at 8a4505b15da9, including main's recursion and queue markers. The split
  # moved bytes and changed none; drop this pin with the first deliberate guard
  # edit, and say so in that review.
  @pre_split [
    gh: "960a0be3fe1680f48a56ac6cd7636f587eeca6ba43448208aafed74770ddd76a",
    git: "4c460dc1f84cd172a5854cf6d6f4abaa2a4d7f1abab27ff87c421c6dbf1ff1c5"
  ]

  test "the assembled guards equal the pre-split scripts" do
    assembled = [gh: sha256(Script.gh()), git: sha256(Script.git())]

    assert assembled == @pre_split
  end

  # A fragment alone is not a valid script, so only the assembly is checked.
  test "the assembled guards parse as shell", %{tmp_dir: tmp_dir} do
    for {guard, source} <- [gh: Script.gh(), git: Script.git()] do
      path = Path.join(tmp_dir, "#{guard}.sh")
      File.write!(path, source)

      assert {"", 0} = System.cmd("sh", ["-n", path], stderr_to_stdout: true)
    end
  end

  test "the issue-disposition hook assembles the same gh guard" do
    load_and_print = """
    import importlib.util, sys
    spec = importlib.util.spec_from_file_location("hook", sys.argv[1])
    hook = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(hook)
    sys.stdout.write(hook.gh_guard_source())
    """

    assert {source, 0} = System.cmd("python3", ["-c", load_and_print, @hook_path])
    assert source == Script.gh()
  end

  defp sha256(source), do: :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)
end
