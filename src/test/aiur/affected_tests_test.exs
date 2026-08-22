defmodule Aiur.AffectedTestsTest do
  use ExUnit.Case, async: true

  alias Aiur.AffectedTests

  defp all_exist, do: [exists?: fn _ -> true end]

  test "maps a changed lib module to its sibling test file" do
    assert AffectedTests.select(["src/lib/aiur/foo.ex"], all_exist()) ==
             {:scoped, ["src/test/aiur/foo_test.exs"]}
  end

  test "includes a directly-changed test file" do
    assert AffectedTests.select(["src/test/aiur/foo_test.exs"], all_exist()) ==
             {:scoped, ["src/test/aiur/foo_test.exs"]}
  end

  test "drops a mapped test file that does not exist" do
    exists? = fn p -> p == "src/test/aiur/foo_test.exs" end

    assert AffectedTests.select(["src/lib/aiur/foo.ex", "src/lib/aiur/bar.ex"], exists?: exists?) ==
             {:scoped, ["src/test/aiur/foo_test.exs"]}
  end

  test "dedupes when a lib file and its test both change" do
    assert AffectedTests.select(
             ["src/lib/aiur/foo.ex", "src/test/aiur/foo_test.exs"],
             all_exist()
           ) == {:scoped, ["src/test/aiur/foo_test.exs"]}
  end

  test "forces the full suite for gettext .po/.pot changes" do
    assert {:full, _} = AffectedTests.select(["priv/gettext/en/LC_MESSAGES/default.po"], all_exist())
    assert {:full, _} = AffectedTests.select(["priv/gettext/default.pot"], all_exist())
  end

  test "forces the full suite for mix and config changes" do
    assert {:full, _} = AffectedTests.select(["src/mix.exs"], all_exist())
    assert {:full, _} = AffectedTests.select(["src/mix.lock"], all_exist())
    assert {:full, _} = AffectedTests.select(["src/config/runtime.exs"], all_exist())
  end

  test "empty change set is scoped-empty" do
    assert AffectedTests.select([], all_exist()) == {:scoped, []}
  end

  test "non-source changes with no test mapping are scoped-empty" do
    assert AffectedTests.select(["docs/token-reduction/RESEARCH-SPIKE.md"], all_exist()) ==
             {:scoped, []}
  end

  test "forces the full suite for shared test support" do
    assert {:full, _} = AffectedTests.select(["src/test/test_helper.exs"], all_exist())
    assert {:full, _} = AffectedTests.select(["src/test/support/factory.ex"], all_exist())
  end

  test "maps xref-dependent sources when a changed module has no sibling test" do
    exists? = fn path -> path == "src/test/aiur/caller_test.exs" end

    assert AffectedTests.select(["src/lib/aiur/callee.ex"],
             exists?: exists?,
             dependent_sources: ["src/lib/aiur/caller.ex"]
           ) == {:scoped, ["src/test/aiur/caller_test.exs"]}
  end

  test "includes tests found by deleted-reference scanning" do
    assert AffectedTests.select(["src/lib/aiur/github/reply.ex"],
             exists?: fn _ -> true end,
             reference_tests: ["src/test/aiur/github_client_test.exs"]
           ) ==
             {:scoped, ["src/test/aiur/github/reply_test.exs", "src/test/aiur/github_client_test.exs"]}
  end

  test "extracts references deleted from individual diff hunks" do
    diff = """
    @@ -1 +1 @@
    -Keyword.get_lazy(opts, :bot_account, &GitHub.Config.bot_account/0)
    +Keyword.get_lazy(opts, :daemon_account, &GitHub.Config.daemon_account/0)
    @@ -8 +8 @@
    -URI.encode_query(%{"state" => "open", "head" => branch})
    +URI.encode_query(%{"state" => "open"})
    @@ -12 +12 @@
    -foo(value)
    +bar(value)
    @@ -16 +16 @@
    -def old_name, do: :state
    +def new_name, do: :status
    """

    terms = AffectedTests.deleted_reference_terms(diff)

    assert "bot_account" in terms
    assert "foo" in terms
    assert "head" in terms
    assert "old_name" in terms
    assert "state" in terms
    refute "bar" in terms
    refute "daemon_account" in terms
    refute "new_name" in terms
    refute "open" in terms
  end

  test "ignores diff headers without dropping changed lines that start with signs" do
    diff = """
    diff --git a/src/lib/old.ex b/src/lib/new.ex
    --- a/src/lib/old.ex
    +++ b/src/lib/new.ex
    @@ -1 +1 @@
    ----:bot_account in heredoc
    ++++:daemon_account in heredoc
    """

    terms = AffectedTests.deleted_reference_terms(diff)

    assert "bot_account" in terms
    refute "old" in terms
    refute "daemon_account" in terms
  end

  test "finds root-level tests containing deleted references" do
    root = Path.join(System.tmp_dir!(), "affected-reference-tests-#{System.unique_integer([:positive])}")
    root_test = Path.join(root, "src/test/aiur/github_client_test.exs")
    nested_test = Path.join(root, "src/test/aiur/github/reply_test.exs")
    File.mkdir_p!(Path.dirname(root_test))
    File.mkdir_p!(Path.dirname(nested_test))
    File.write!(root_test, "reply(opts: [bot_account: account])")
    File.write!(nested_test, "reply(opts: [daemon_account: account])")

    try do
      assert AffectedTests.reference_test_files(root, ["bot_account"]) == [
               "src/test/aiur/github_client_test.exs"
             ]
    after
      File.rm_rf!(root)
    end
  end

  test "reference matching does not confuse an identifier with a longer word" do
    root = Path.join(System.tmp_dir!(), "affected-reference-boundary-#{System.unique_integer([:positive])}")
    header_test = Path.join(root, "src/test/aiur/header_test.exs")
    head_test = Path.join(root, "src/test/aiur/github_client_test.exs")
    File.mkdir_p!(Path.dirname(header_test))
    File.write!(header_test, "assert response.headers != []")
    File.write!(head_test, ~s(assert url =~ "head=owner:branch"))

    try do
      assert AffectedTests.reference_test_files(root, ["head"]) == [
               "src/test/aiur/github_client_test.exs"
             ]
    after
      File.rm_rf!(root)
    end
  end

  test "fails closed when no direct or xref-dependent test exists" do
    assert {:full, reason} =
             AffectedTests.select(["src/lib/aiur/callee.ex"], exists?: fn _ -> false end)

    assert reason =~ "no direct or xref-dependent tests"
  end

  test "fails closed for unrecognized executable and build files" do
    for path <- ["scripts/aiurdev", ".claude/skills/aiur-run/scripts/poll.py", "src/assets/app.js"] do
      assert {:full, reason} = AffectedTests.select([path], all_exist())
      assert reason =~ path
    end
  end

  test ".aiur/ config paths are ignored and do not trigger full suite" do
    assert AffectedTests.select([".aiur/config"], all_exist()) == {:scoped, []}
  end

  test ".aiur/ config paths alongside real source changes do not block scoped run" do
    assert AffectedTests.select([".aiur/config", "src/lib/aiur/foo.ex"], all_exist()) ==
             {:scoped, ["src/test/aiur/foo_test.exs"]}
  end
end
