defmodule Aiur.Config.RepoStatePathsTest do
  # async: false — swaps the global :repo_base_root app env.
  use ExUnit.Case, async: false

  alias Aiur.Config.Paths

  setup do
    previous = Application.get_env(:aiur, :repo_base_root)
    root = Path.join(System.tmp_dir!(), "repo-state-paths-#{System.unique_integer([:positive])}")
    Application.put_env(:aiur, :repo_base_root, root)
    on_exit(fn -> Application.put_env(:aiur, :repo_base_root, previous) end)
    %{root: root}
  end

  test "repo_state_path reduces https, ssh and local inputs to <root>/owner/name", %{root: root} do
    expected = Path.join(root, "owner/name")

    for input <- [
          "https://github.com/owner/name.git",
          "https://github.com/owner/name/",
          "git@github.com:owner/name.git",
          "ssh://git@github.com/owner/name",
          "/srv/checkouts/owner/name"
        ] do
      assert Paths.repo_state_path(input) == expected
      assert Paths.repo_state_relative_path(input) == ".aiur/repo/owner/name"
    end

    assert Paths.repo_state_root() == root

    assert Paths.repo_cache_sidecar_paths(expected) ==
             [expected <> "/.aiur-hex", expected <> "/.aiur-mix", expected <> "/.aiur-npm-cache"]
  end

  test "rejects a repo identity that would escape the state root" do
    assert_raise ArgumentError, ~r/must not escape the state root/, fn ->
      Paths.repo_state_path("https://github.com/../name")
    end
  end
end
