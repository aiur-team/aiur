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

  test "uses AIUR_BASE_BRANCH when set, stripping any leading origin/ prefix" do
    System.put_env("AIUR_BASE_BRANCH", "develop")

    try do
      assert AffectedTests.default_origin() == "origin/develop"
    after
      System.delete_env("AIUR_BASE_BRANCH")
    end
  end

  test "AIUR_BASE_BRANCH already prefixed with origin/ is not doubled" do
    System.put_env("AIUR_BASE_BRANCH", "origin/develop")

    try do
      assert AffectedTests.default_origin() == "origin/develop"
    after
      System.delete_env("AIUR_BASE_BRANCH")
    end
  end

  test "when AIUR_BASE_BRANCH is unset, reads tracker.base_branch from config" do
    System.delete_env("AIUR_BASE_BRANCH")

    try do
      assert AffectedTests.default_origin(fn -> "develop" end) == "origin/develop"
    after
      System.delete_env("AIUR_BASE_BRANCH")
    end
  end

  test "falls back to origin/main when neither AIUR_BASE_BRANCH nor config is set" do
    System.delete_env("AIUR_BASE_BRANCH")

    try do
      assert AffectedTests.default_origin(fn -> "main" end) == "origin/main"
    after
      System.delete_env("AIUR_BASE_BRANCH")
    end
  end
end

defmodule Mix.Tasks.Aiur.AffectedTests.XrefSinksTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Aiur.AffectedTests

  test "excludes paths that do not exist on disk from xref sinks" do
    dir = System.tmp_dir!()
    existing = "src/lib/aiur/existing.ex"
    deleted = "src/lib/aiur/deleted.ex"
    File.mkdir_p!(Path.join(dir, "src/lib/aiur"))
    File.write!(Path.join(dir, existing), "")

    try do
      sinks = AffectedTests.xref_sinks([existing, deleted], dir)
      assert "lib/aiur/existing.ex" in sinks
      refute "lib/aiur/deleted.ex" in sinks
    after
      File.rm(Path.join(dir, existing))
    end
  end

  test "excludes non-lib and non-.ex paths from xref sinks" do
    dir = System.tmp_dir!()
    assert AffectedTests.xref_sinks(["src/test/aiur/foo_test.exs", "README.md"], dir) == []
  end
end
