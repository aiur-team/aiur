defmodule Aiur.Codeowners.EditTest do
  use ExUnit.Case, async: true

  alias Aiur.Codeowners.Edit

  describe "normalize_login/1" do
    test "strips @ prefix and downcases" do
      assert Edit.normalize_login("@Foo") == "foo"
    end

    test "returns nil for blank string" do
      assert Edit.normalize_login("  ") == nil
    end

    test "returns nil for nil" do
      assert Edit.normalize_login(nil) == nil
    end
  end

  describe "has_login?/2" do
    test "returns true for exact login match" do
      assert Edit.has_login?("* @alice\n", "alice")
    end

    test "returns true for @-prefixed login (case-insensitive)" do
      assert Edit.has_login?("* @alice\n", "@ALICE")
    end

    test "returns false when login not present" do
      refute Edit.has_login?("* @alice\n", "bob")
    end
  end

  describe "content_with_login/2" do
    test "appends login before inline comment on wildcard rule" do
      content = "* @alice # owners\n"
      result = Edit.content_with_login(content, "bob")
      assert result =~ "@alice @bob #"
    end

    test "appends login after existing owners on wildcard rule without comment" do
      content = "* @alice\n"
      result = Edit.content_with_login(content, "bob")
      assert result =~ "@alice @bob"
    end

    test "appends new wildcard rule when no wildcard rule exists" do
      content = "# just a comment\n"
      result = Edit.content_with_login(content, "bob")
      assert result =~ "* @bob\n"
      # No leading blank line added when input ends with \n
      refute String.starts_with?(result, "\n")
    end
  end

  describe "add_login/2" do
    setup do
      dir = Aiur.TestSupport.tmp_root!("edit-test")
      File.mkdir_p!(dir)
      path = Path.join(dir, "CODEOWNERS")
      File.write!(path, "* @existing\n")
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, path: path}
    end

    test "returns {:updated, path} when login is new", %{path: path} do
      assert {:updated, ^path} = Edit.add_login(path, "newuser")
    end

    test "returns {:exists, path} on second call with same login", %{path: path} do
      Edit.add_login(path, "newuser")
      assert {:exists, ^path} = Edit.add_login(path, "newuser")
    end

    test "returns {:error, :missing_github_login} for blank login", %{path: path} do
      assert {:error, :missing_github_login} = Edit.add_login(path, "")
    end
  end
end
