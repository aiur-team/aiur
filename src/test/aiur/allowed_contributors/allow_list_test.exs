defmodule Aiur.AllowedContributors.AllowListTest do
  use ExUnit.Case, async: true

  alias Aiur.AllowedContributors.AllowList

  test "parses user and org entries by numeric id; trailing login comments are ignored" do
    body = """
    # Trusted outside contributors
    user 583231   # octocat

    org 9919 github # the GitHub org
    """

    assert {:ok, %{users: users, orgs: orgs}} = AllowList.parse(body)
    assert users == MapSet.new([583_231])
    assert orgs == %{9919 => "github"}
  end

  test "an empty or comment-only file admits nobody" do
    assert {:ok, list} = AllowList.parse("# nothing here\n\n")
    assert list == AllowList.empty()
  end

  test "a bare login is never an identity" do
    assert {:error, {:line, 1, :unrecognized_entry}} = AllowList.parse("octocat\n")
    assert {:error, {:line, 1, :invalid_id}} = AllowList.parse("user octocat\n")
  end

  test "lookalike, signed, zero, leading-zero and overflowing ids are rejected" do
    for id <- ["１２３", "-5", "+5", "0", "0123", "12a", "99999999999999999999"] do
      assert {:error, {:line, 1, :invalid_id}} = AllowList.parse("user #{id}\n"), "accepted #{inspect(id)}"
    end
  end

  test "org lines need an ASCII login" do
    assert {:error, {:line, 1, :unrecognized_entry}} = AllowList.parse("org 9919\n")
    # Cyrillic "а" in place of the Latin "a".
    assert {:error, {:line, 1, :invalid_login}} = AllowList.parse("org 9919 аiur-team\n")
    assert {:error, {:line, 1, :invalid_login}} = AllowList.parse("org 9919 -leading\n")
    assert {:error, {:line, 1, :invalid_login}} = AllowList.parse("org 9919 acme/evil\n")
    # Legacy GitHub logins with doubled or trailing hyphens are real accounts.
    assert {:ok, %{orgs: %{9919 => "old--org-"}}} = AllowList.parse("org 9919 old--org-\n")
  end

  test "no transitive or team forms exist" do
    for line <- ["team 1 org/team", "include 1", "@aiur-team/core", "user 1 2", "org 1 a b"] do
      assert {:error, {:line, 1, :unrecognized_entry}} = AllowList.parse(line <> "\n"), "accepted #{inspect(line)}"
    end
  end

  test "one malformed line invalidates the whole file" do
    assert {:error, {:line, 3, _}} = AllowList.parse("user 1\nuser 2\nuser x\nuser 4\n")
  end

  test "the same org id may not name two logins" do
    assert {:error, {:line, 2, :conflicting_org}} = AllowList.parse("org 5 alpha\norg 5 beta\n")
  end

  test "oversized and non-UTF-8 bodies fail closed" do
    assert {:error, :too_large} = AllowList.parse(String.duplicate("# x\n", 20_000))
    assert {:error, :not_utf8} = AllowList.parse(<<0xFF, 0xFE>>)
  end

  test "this repository's own allow-list parses" do
    path = Path.expand("../../../../.github/ALLOWED-CONTRIBUTORS", __DIR__)
    assert {:ok, %{users: users}} = path |> File.read!() |> AllowList.parse()
    assert MapSet.size(users) > 0
  end

  test "diff names added and removed entries" do
    {:ok, old} = AllowList.parse("user 1\norg 9 acme\n")
    {:ok, new} = AllowList.parse("user 1\nuser 2\n")

    assert AllowList.diff(old, new) == %{added: ["user:2"], removed: ["org:9:acme"]}
  end
end
