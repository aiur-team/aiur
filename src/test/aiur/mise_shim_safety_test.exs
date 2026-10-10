defmodule Aiur.MiseShimSafetyTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../..", __DIR__)

  test "real mise reshim and doctor preserve host shim ownership" do
    {output, status} = System.cmd("python3", [Path.join(@repo_root, "src/test/support/mise_shim_safety_check.py"), @repo_root], stderr_to_stdout: true)
    assert status == 0, output
    assert output =~ "Ran 4 tests"
  end
end
