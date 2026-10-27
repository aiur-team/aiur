defmodule Aiur.AgentGitHubGuard.ScriptTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  alias Aiur.AgentGitHubGuard.Script

  @hook_path Path.expand("../../../../.claude/hooks/issue-disposition.py", __DIR__)

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
end
