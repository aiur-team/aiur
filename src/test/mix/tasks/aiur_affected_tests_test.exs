defmodule Mix.Tasks.Aiur.AffectedTestsTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Aiur.AffectedTests

  test "full fallback is runnable from the repository root" do
    assert AffectedTests.command({:full, "unsafe change"}) == [
             "# full suite recommended: unsafe change",
             "cd src && mise exec -- make ci"
           ]
  end

  test "scoped command is root-runnable and shell-quotes test paths" do
    assert AffectedTests.command({:scoped, ["src/test/aiur/a test's_test.exs"]}) == [
             "cd src && mise exec -- mix test --max-cases 4 'test/aiur/a test'\"'\"'s_test.exs'"
           ]
  end

  test "documentation-only selection does not claim code tests were found" do
    assert AffectedTests.command({:scoped, []}) == [
             "# no affected test files detected for the documentation-only change"
           ]
  end
end

# Env-mutation tests require async: false to avoid races on the process-global
# AIUR_BASE_BRANCH env var.
defmodule Mix.Tasks.Aiur.AffectedTests.DefaultOriginTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Aiur.AffectedTests

  test "default_origin uses AIUR_BASE_BRANCH when set" do
    System.put_env("AIUR_BASE_BRANCH", "develop")

    try do
      assert AffectedTests.default_origin() == "origin/develop"
    after
      System.delete_env("AIUR_BASE_BRANCH")
    end
  end

  test "default_origin falls back to origin/main when AIUR_BASE_BRANCH is unset" do
    System.delete_env("AIUR_BASE_BRANCH")

    try do
      assert AffectedTests.default_origin() == "origin/main"
    after
      System.delete_env("AIUR_BASE_BRANCH")
    end
  end
end
