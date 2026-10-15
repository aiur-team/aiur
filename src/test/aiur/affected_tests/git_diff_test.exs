defmodule Aiur.AffectedTests.GitDiffTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Aiur.AffectedTests

  test "merge checkout selection excludes base-only changes" do
    repo = Aiur.TestSupport.tmp_root!("affected-task-merge-base")
    test_file = "src/test/aiur/feature_test.exs"
    main_only_file = "src/test/aiur/main_only_test.exs"
    File.mkdir_p!(Path.join(repo, "src/test/aiur"))

    try do
      git!(repo, ["init", "-q"])
      git!(repo, ["config", "user.email", "test@example.com"])
      git!(repo, ["config", "user.name", "Test"])
      File.write!(Path.join(repo, test_file), "test\n")
      git!(repo, ["add", test_file])
      git!(repo, ["commit", "-qm", "base"])
      base = git!(repo, ["rev-parse", "HEAD"]) |> String.trim()

      File.write!(Path.join(repo, test_file), "feature test\n")
      git!(repo, ["add", test_file])
      feature_tree = git!(repo, ["write-tree"]) |> String.trim()
      feature = git!(repo, ["commit-tree", feature_tree, "-p", base, "-m", "feature-only"]) |> String.trim()

      git!(repo, ["read-tree", base])
      File.write!(Path.join(repo, main_only_file), "test\n")
      git!(repo, ["add", main_only_file])
      main_tree = git!(repo, ["write-tree"]) |> String.trim()
      main = git!(repo, ["commit-tree", main_tree, "-p", base, "-m", "main-only"]) |> String.trim()
      git!(repo, ["update-ref", "refs/heads/main", main])

      merge_tree = git!(repo, ["merge-tree", "--write-tree", feature, main]) |> String.split("\n") |> hd()
      merge = git!(repo, ["commit-tree", merge_tree, "-p", main, "-p", feature, "-m", "synthetic PR merge"]) |> String.trim()

      git!(repo, ["read-tree", merge])
      git!(repo, ["update-ref", "HEAD", merge])

      previous_event = System.get_env("GITHUB_EVENT_NAME")
      System.put_env("GITHUB_EVENT_NAME", "pull_request")

      try do
        assert {:ok, [command]} = AffectedTests.selection(repo, base)
        assert command == "cd src && mise exec -- mix test --max-cases 4 'test/aiur/feature_test.exs'"
      after
        restore_event(previous_event)
      end
    after
      File.rm_rf!(repo)
    end
  end

  test "local merge checkout still selects from merge-base" do
    repo = Aiur.TestSupport.tmp_root!("affected-task-local-merge")
    test_file = "src/test/aiur/feature_test.exs"
    main_only_file = "src/test/aiur/main_only_test.exs"
    File.mkdir_p!(Path.join(repo, "src/test/aiur"))

    try do
      git!(repo, ["init", "-q"])
      git!(repo, ["config", "user.email", "test@example.com"])
      git!(repo, ["config", "user.name", "Test"])
      File.write!(Path.join(repo, test_file), "test\n")
      git!(repo, ["add", test_file])
      git!(repo, ["commit", "-qm", "base"])
      base = git!(repo, ["rev-parse", "HEAD"]) |> String.trim()

      File.write!(Path.join(repo, test_file), "feature test\n")
      git!(repo, ["add", test_file])
      feature_tree = git!(repo, ["write-tree"]) |> String.trim()
      feature = git!(repo, ["commit-tree", feature_tree, "-p", base, "-m", "feature-only"]) |> String.trim()

      git!(repo, ["read-tree", base])
      File.write!(Path.join(repo, main_only_file), "test\n")
      git!(repo, ["add", main_only_file])
      main_tree = git!(repo, ["write-tree"]) |> String.trim()
      main = git!(repo, ["commit-tree", main_tree, "-p", base, "-m", "main-only"]) |> String.trim()

      merge_tree = git!(repo, ["merge-tree", "--write-tree", feature, main]) |> String.split("\n") |> hd()
      merge = git!(repo, ["commit-tree", merge_tree, "-p", feature, "-p", main, "-m", "local merge"]) |> String.trim()
      git!(repo, ["read-tree", merge])
      git!(repo, ["update-ref", "HEAD", merge])

      previous_event = System.get_env("GITHUB_EVENT_NAME")
      System.delete_env("GITHUB_EVENT_NAME")

      try do
        assert {:ok, [command]} = AffectedTests.selection(repo, main)
        assert command == "cd src && mise exec -- mix test --max-cases 4 'test/aiur/feature_test.exs'"
      after
        restore_event(previous_event)
      end
    after
      File.rm_rf!(repo)
    end
  end

  defp restore_event(nil), do: System.delete_env("GITHUB_EVENT_NAME")
  defp restore_event(value), do: System.put_env("GITHUB_EVENT_NAME", value)

  defp git!(repo, args) do
    {output, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
    output
  end
end
