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
end
