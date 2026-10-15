defmodule Mix.Tasks.Aiur.AffectedTestsTest do
  use ExUnit.Case, async: true

  alias Aiur.AffectedTests.Command
  alias Mix.Tasks.Aiur.AffectedTests

  test "full fallback is runnable from the repository root" do
    assert AffectedTests.command({:full, "unsafe change", ["src/test/support/helper.exs"]}) == [
             "# full suite recommended: unsafe change; changed paths: src/test/support/helper.exs",
             "cd src && mise exec -- make ci"
           ]
  end

  test "scoped command is root-runnable and shell-quotes test paths" do
    assert Command.build({:scoped, ["src/test/aiur/a test's_test.exs"]}) == [
             "cd src && mise exec -- mix test --max-cases 4 'test/aiur/a test'\"'\"'s_test.exs'"
           ]
  end

  test "documentation-only selection does not claim code tests were found" do
    assert Command.build({:scoped, []}) == [
             "# no affected test files detected for the documentation-only change"
           ]
  end

  test "JSON selection reports full fallback and scoped test files as data" do
    assert Jason.decode!(AffectedTests.selection_json({:full, "shared support changed"})) == %{
             "status" => "full",
             "reason" => "shared support changed"
           }

    assert Jason.decode!(AffectedTests.selection_json({:scoped, ["src/test/engine_test.exs"]})) == %{
             "status" => "scoped",
             "tests" => ["src/test/engine_test.exs"]
           }
  end
end

defmodule Mix.Tasks.Aiur.AffectedTests.ChangedPathsTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Aiur.AffectedTests

  test "uses the classifier's changed paths even when the checkout has extra base changes" do
    paths = ["src/test/aiur/one_test.exs"]
    System.put_env("AIUR_CI_CHANGED_PATHS_B64", Base.encode64(Jason.encode!(paths)))

    try do
      assert AffectedTests.changed_files("/not-a-repository", "stale-base-sha") == {:ok, paths}
    after
      System.delete_env("AIUR_CI_CHANGED_PATHS_B64")
    end
  end

  test "rejects malformed classifier changed paths" do
    System.put_env("AIUR_CI_CHANGED_PATHS_B64", Base.encode64("{}"))

    try do
      assert {:error, "AIUR_CI_CHANGED_PATHS_B64 must encode a JSON array of paths"} =
               AffectedTests.changed_files("/not-a-repository", "stale-base-sha")
    after
      System.delete_env("AIUR_CI_CHANGED_PATHS_B64")
    end
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

  test "default config_fn delegates to Aiur.Config.base_branch/0" do
    System.delete_env("AIUR_BASE_BRANCH")

    try do
      assert AffectedTests.default_origin() == "origin/" <> Aiur.Config.base_branch()
    after
      System.delete_env("AIUR_BASE_BRANCH")
    end
  end
end

defmodule Mix.Tasks.Aiur.AffectedTests.XrefSinksTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Aiur.AffectedTests

  test "excludes paths that do not exist on disk from xref sinks" do
    dir = Aiur.TestSupport.tmp_root!("affected-xref-sinks")
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

defmodule Mix.Tasks.Aiur.AffectedTests.DeletedReferencesTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Aiur.AffectedTests

  test "discovers root-level tests retaining deleted structural references" do
    repo = Aiur.TestSupport.tmp_root!("affected-task-references")
    source = Path.join(repo, "src/lib/aiur/github/reply.ex")
    root_test = Path.join(repo, "src/test/aiur/github_client_test.exs")
    File.mkdir_p!(Path.dirname(source))
    File.mkdir_p!(Path.dirname(root_test))

    File.write!(source, """
    def old_name, do: :ok
    def state(opts), do: Keyword.get(opts, :bot_account)
    """)

    File.write!(root_test, """
    assert old_name() == :ok
    assert state(bot_account: account)
    """)

    try do
      git!(repo, ["init", "-q"])
      git!(repo, ["config", "user.email", "test@example.com"])
      git!(repo, ["config", "user.name", "Test"])
      git!(repo, ["add", "."])
      git!(repo, ["commit", "-qm", "baseline"])

      File.write!(source, """
      def new_name, do: :ok
      def status(opts), do: Keyword.get(opts, :daemon_account)
      """)

      assert AffectedTests.deleted_reference_tests(repo, "HEAD") ==
               {:ok, ["src/test/aiur/github_client_test.exs"]}
    after
      File.rm_rf!(repo)
    end
  end

  defp git!(repo, args) do
    assert {_output, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
  end
end
