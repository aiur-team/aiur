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

  test "outside src/lib a resolution overlapping base changes carries" do
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
